import Foundation
import os

final class Sessions {
    private struct Recovery: Codable {
        var mode: MacPower.Mode? = nil
        var restoreSleep = true
        var restoreMode = false
        var batteryMode: MacPower.Mode? = nil

        var isConsistent: Bool {
            restoreMode == (mode != nil) && (mode?.isValid ?? true) && (batteryMode?.isValid ?? true)
        }

        var needsRestoration: Bool { restoreSleep || restoreMode || batteryMode != nil }

        subscript(source: MacPower.Source) -> MacPower.Mode? {
            get { source == .adapter ? mode : batteryMode }
            set {
                if source == .adapter {
                    mode = newValue
                    restoreMode = newValue != nil
                } else {
                    batteryMode = newValue
                }
            }
        }
    }

    private let directory: URL
    private var file: URL { directory.appendingPathComponent("recovery.json") }
    private var cutoffSleepFile: URL { directory.appendingPathComponent("cutoff-sleep.json") }
    private var cutoffFile: URL { directory.appendingPathComponent("battery-cutoff") }
    private var historyFile: URL { directory.appendingPathComponent("lid-history.json") }
    private var lidHistory: [LidActivity] = []
    private var closedClocks: (continuous: ContinuousClock.Instant, suspending: SuspendingClock.Instant)?
    private let log = Logger(subsystem: label, category: "session")
    private var sessionActive = false
    private var lastStopUptime: TimeInterval?
    private var deadline: Date?
    private var expiresAt: ContinuousClock.Instant?
    private var recovery: Recovery?
    private var recoveryRequired = false
    private var recoveryWarning: String?
    private var trackedLid: Bool?
    private var trackedSource: MacPower.Source?
    private var revisitingProfiles: Set<MacPower.Source> = []
    private var profilesLeftAlone: Set<MacPower.Source> = []
    private var modeRetryAt: ContinuousClock.Instant?
    private var lidGrace = ReadingGrace()
    private var displayLidClosed = false
    private var displaySleepRetry: DisplaySleepRetry?
    private var displaySleepFailed = false
    let safety = PowerSafetyWatch()
    private var batteryCutoff = defaultBatteryCutoff
    private var cutoffSleepRetry: CutoffSleepRetry?
    private var nextSleepCheck: ContinuousClock.Instant?
    private var sleepCheckFailures = 0
    private var message = "Ready"

    init(directory: URL = URL(fileURLWithPath: "/var/db/\(label)", isDirectory: true)) throws {
        self.directory = directory
        if let value = try? String(contentsOf: cutoffFile, encoding: .utf8),
           let percentage = Int(value), (1...100).contains(percentage) {
            batteryCutoff = percentage
        }
        do {
            let history = try JSONDecoder().decode([LidActivity].self, from: Data(contentsOf: historyFile))
            lidHistory = Array(history.prefix(lidHistoryLimit))
            if lidHistory.first?.isOpenInterval == true {
                lidHistory[0].interruption = "Power helper restarted."
                saveHistory()
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            log.error("Could not read lid history: \(error.localizedDescription, privacy: .public)")
        }
        do {
            let retry = try JSONDecoder().decode(CutoffSleepRetry.self, from: Data(contentsOf: cutoffSleepFile))
            if retry.isCurrent(at: .now) {
                cutoffSleepRetry = retry
                message = "Resuming the immediate sleep request after battery cutoff."
            } else {
                updateCutoffSleep(nil)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            log.error("Could not read the pending cutoff sleep request.")
            updateCutoffSleep(nil)
        }
        do {
            let entry = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: file))
            guard entry.isConsistent else { throw LidStatsError("Recovery journal is inconsistent.") }
            recovery = entry
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            recoveryRequired = true
            message = "Recovery journal is invalid or unreadable. Normal sleep may still be disabled."
            log.error("Recovery journal rejected: \(error.localizedDescription, privacy: .public)")
        }
        if recovery != nil {
            finish("Restoring settings from the previous session.", deferEnergyRestore: cutoffSleepRetry != nil)
        }
    }

    func handle(_ request: Request) -> Status {
        enforceSafety()
        do {
            switch request.action {
            case .status: break
            case .start:
                if let hours = request.hours, ![1, 4, 8, 12].contains(hours) {
                    throw LidStatsError("Choose a 1, 4, 8, or 12 hour session.")
                }
                if let requested = request.startRequestedAtUptime, let lastStopUptime, requested <= lastStopUptime {
                    throw LidStatsError("The start request was canceled.")
                }
                try start(hours: request.hours, expiresAtUptime: request.startExpiresAtUptime)
            case .stop:
                lastStopUptime = ProcessInfo.processInfo.systemUptime
                guard !recoveryRequired else { throw LidStatsError(message) }
                finish("Session ended.")
            case .repairSleep:
                guard recoveryRequired else { throw LidStatsError("Manual sleep recovery isn’t needed.") }
                try MacPower.setSleepDisabled(false)
                let backup = directory.appendingPathComponent("recovery-damaged-\(UUID().uuidString).json")
                try FileManager.default.moveItem(at: file, to: backup)
                recoveryRequired = false
                message = "Normal sleep restored. Review your energy mode in System Settings."
            case .setBatteryCutoff:
                guard let percentage = request.batteryCutoff, (1...100).contains(percentage) else {
                    throw LidStatsError("Enter a battery percentage from 1 to 100.")
                }
                try Data(String(percentage).utf8).write(to: cutoffFile, options: .atomic)
                batteryCutoff = percentage
                if sessionActive {
                    safety.arm(cutoff: batteryCutoff)
                    _ = safety.poll()
                    enforceSafety()
                }
            }
        } catch {
            return status(error: error.localizedDescription)
        }
        return status()
    }

    func status(error: String? = nil) -> Status {
        let power = MacPower.reading
        let warnings = [recoveryWarning, displaySleepFailed ? "Couldn’t put the display to sleep." : nil]
        let details = ([message] + warnings.compactMap { $0 }).joined(separator: " ")
        return Status(pluggedIn: power.source == .adapter, deadline: deadline, lidClosed: MacPower.lidClosed,
                      lowPowerEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                      message: details,
                      recovering: !sessionActive && recovery != nil, batteryPercentage: power.batteryPercentage,
                      batteryCutoff: batteryCutoff, error: error, sessionActive: sessionActive, lidHistory: lidHistory, recoveryRequired: recoveryRequired, supportsSafetyWatch: true, helperProtocolRevision: powerHelperProtocolRevision)
    }

    private func start(hours: Int?, expiresAtUptime: TimeInterval?) throws {
        func checkExpiration() throws {
            if let expiresAtUptime, ProcessInfo.processInfo.systemUptime >= expiresAtUptime {
                throw LidStatsError("The start request expired.")
            }
        }
        try checkExpiration()
        guard recovery == nil, !recoveryRequired else { throw LidStatsError("End the current session or wait for settings recovery.") }
        if let reason = PowerSafetyWatch.batteryStopReason(MacPower.reading, cutoff: batteryCutoff) { throw LidStatsError(reason) }
        guard !MacPower.tooHot else { throw LidStatsError("macOS reports a critical thermal state.") }
        guard let closed = MacPower.lidClosed, !closed else { throw LidStatsError("Open the MacBook lid before starting.") }
        guard try !MacPower.sleepDisabled() else {
            throw LidStatsError("System sleep is already disabled. End any other keep-awake session first.")
        }

        if cutoffSleepRetry != nil { updateCutoffSleep(nil) }
        try save(Recovery())
        safety.arm(cutoff: batteryCutoff)
        do {
            try MacPower.setSleepDisabled(true)
            try checkExpiration()
            if let hours {
                deadline = Date().addingTimeInterval(Double(hours) * 3600)
                expiresAt = .now.advanced(by: .seconds(hours * 3600))
            }
            sessionActive = true
            nextSleepCheck = .now.advanced(by: .seconds(5))
            trackedLid = false
            message = "Session active"
            log.notice("Session started")
            _ = safety.poll()
            enforceSafety()
        } catch {
            finish("Could not start session.")
            throw error
        }
    }

    func enforceSafety() {
        guard sessionActive, let stop = safety.stop else { return }
        if stop.sleepAfterCutoff { updateCutoffSleep(CutoffSleepRetry(now: .now, cutoff: batteryCutoff)) }
        finish(stop.reason, deferEnergyRestore: true)
        requestSleepAfterCutoff()
    }

    func tick() {
        enforceSafety()
        guard sessionActive else {
            if recovery != nil { recover(deferEnergyRestore: cutoffSleepRetry != nil) }
            requestSleepAfterCutoff()
            return
        }
        if let nextSleepCheck, ContinuousClock.now >= nextSleepCheck {
            do {
                guard try MacPower.sleepDisabled(cancelled: { self.safety.stop != nil }) else {
                    if safety.stop != nil {
                        enforceSafety()
                    } else {
                        finish("Session interrupted because system sleep was re-enabled.")
                    }
                    return
                }
                sleepCheckFailures = 0
                self.nextSleepCheck = .now.advanced(by: .seconds(5))
            } catch {
                if safety.stop != nil {
                    enforceSafety()
                    return
                }
                sleepCheckFailures += 1
                if sleepCheckFailures >= 3 {
                    finish("Session ended because LidStats couldn’t verify the system sleep setting after three attempts.")
                    return
                }
                self.nextSleepCheck = .now.advanced(by: .seconds(1))
            }
        }
        let now = ContinuousClock.now
        if let expiresAt, now >= expiresAt {
            finish("Session timer expired.")
            return
        }
        let lidClosed = MacPower.lidClosed
        if lidGrace.expired(available: lidClosed != nil, now: now) {
            finish("Session ended because LidStats couldn’t read the lid state.")
            return
        }
        guard let closed = lidClosed else { return }
        let power = MacPower.reading
        if closed != displayLidClosed {
            recordLidTransition(closed, battery: power.batteryPercentage)
        }
        updateDisplaySleep(lidClosed: closed, now: now)
        if safety.stop != nil {
            enforceSafety()
            return
        }
        guard let source = power.source else { return }
        if closed != trackedLid || (closed && source != trackedSource) ||
            (modeRetryAt.map { ContinuousClock.now >= $0 } ?? false) {
            updateForLid(closed, source: source)
        }
    }

    private func updateDisplaySleep(lidClosed: Bool, now: ContinuousClock.Instant) {
        if lidClosed != displayLidClosed {
            displayLidClosed = lidClosed
            displaySleepRetry = lidClosed ? DisplaySleepRetry() : nil
            if lidClosed { displaySleepFailed = false }
        }
        guard var retry = displaySleepRetry, safety.stop == nil else { return }
        switch retry.attempt(now: now, requestSleep: {
            try MacPower.run(["displaysleepnow"], cancelled: { self.safety.stop != nil })
        }) {
        case .pending: displaySleepRetry = retry
        case .succeeded: displaySleepRetry = nil
        case .failed:
            displaySleepRetry = nil
            displaySleepFailed = true
            if lidHistory.first?.isOpenInterval == true {
                lidHistory[0].displaySleepFailed = true
                saveHistory()
            }
            log.error("Display sleep failed after three attempts.")
        }
    }

    private func recordLidTransition(_ closed: Bool, battery: Int?) {
        if closed {
            lidHistory.insert(LidActivity(closedAt: .now, batteryAtClose: battery), at: 0)
            if lidHistory.count > lidHistoryLimit { lidHistory.removeLast() }
            closedClocks = (.now, .now)
        } else {
            guard lidHistory.first?.isOpenInterval == true else { return }
            lidHistory[0].reopenedAt = .now
            lidHistory[0].batteryAtReopen = battery
            if let closedClocks {
                let elapsed = closedClocks.continuous.duration(to: .now)
                let awake = closedClocks.suspending.duration(to: .now)
                lidHistory[0].detectedSleep = elapsed - awake > .seconds(2)
            }
            closedClocks = nil
        }
        saveHistory()
    }

    private func saveHistory() {
        do {
            try JSONEncoder().encode(lidHistory).write(to: historyFile, options: .atomic)
        } catch {
            log.error("Could not save lid history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestSleepAfterCutoff() {
        guard var retry = cutoffSleepRetry, !recoveryRequired else { return }
        if recovery?.restoreSleep == true {
            if !retry.isCurrent(at: .now) { reportFailedCutoffSleep() }
            return
        }
        let result = retry.attempt(now: .now, lidClosed: MacPower.lidClosed,
                                   power: MacPower.reading, currentCutoff: batteryCutoff,
                                   prepareRequest: updateCutoffSleep) {
            try MacPower.run(["sleepnow"])
        }
        switch result {
        case .pending: updateCutoffSleep(retry)
        case .finished: updateCutoffSleep(nil)
        case .failed: reportFailedCutoffSleep()
        }
    }

    private func persistCutoffSleep(_ retry: CutoffSleepRetry?) throws {
        if let retry {
            try JSONEncoder().encode(retry).write(to: cutoffSleepFile, options: .atomic)
        } else {
            try removeJournal(at: cutoffSleepFile)
        }
    }

    private func updateCutoffSleep(_ retry: CutoffSleepRetry?) {
        cutoffSleepRetry = retry
        do {
            try persistCutoffSleep(retry)
        } catch {
            log.error("Could not update the cutoff sleep record: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reportFailedCutoffSleep() {
        updateCutoffSleep(nil)
        message += " Immediate sleep could not be confirmed."
        log.error("Immediate sleep after the battery cutoff failed.")
    }

    private func updateForLid(_ closed: Bool, source: MacPower.Source) {
        let sourceChanged = trackedLid == true && trackedSource != source
        trackedLid = closed
        trackedSource = source
        guard var entry = recovery else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let cancelled = { self.safety.stop != nil || ContinuousClock.now >= deadline }
        modeRetryAt = nil

        do {
            if closed {
                let savedMode = entry[source]
                if profilesLeftAlone.contains(source) {
                    message = "Session active. Keeping your chosen energy mode."
                    return
                }
                if let mode = savedMode {
                    if sourceChanged { revisitingProfiles.insert(source) }
                    guard let current = try MacPower.mode(for: source, cancelled: cancelled),
                          current.key == mode.key else {
                        throw LidStatsError("Couldn’t verify the current energy mode.")
                    }
                    let revisiting = revisitingProfiles.remove(source) != nil
                    if current.value != 1 && (revisiting || current.value != mode.value) {
                        profilesLeftAlone.insert(source)
                        entry[source] = nil
                        recovery = entry
                        try save(entry)
                        message = "Session active. Keeping your chosen energy mode."
                        return
                    }
                    if current.value != 1 { try mode.apply(1, to: source, cancelled: cancelled) }
                } else if let mode = try MacPower.mode(for: source, cancelled: cancelled) {
                    if mode.value != 1 {
                        entry[source] = mode
                        try save(entry)
                        try mode.apply(1, to: source, cancelled: cancelled)
                    }
                } else if !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    throw LidStatsError("macOS did not report the active energy profile.")
                }
                log.notice("Low Power Mode requested for \(source.rawValue, privacy: .public).")
            } else {
                let errors = restoreModes(&entry, cancelled: cancelled)
                recovery = entry
                try save(entry)
                if let error = errors.first { throw LidStatsError(error) }
                log.notice("Lid opened. Power modes restored.")
            }
            message = "Session active"
        } catch {
            modeRetryAt = .now.advanced(by: .seconds(5))
            message = closed ? "Session active. Couldn’t enable Low Power Mode."
                : "Session active. Power mode restore pending."
            log.error("\(error.localizedDescription, privacy: .public)")
        }
    }

    func finish(_ reason: String, deferEnergyRestore: Bool = false) {
        safety.arm(cutoff: nil)
        modeRetryAt = nil
        nextSleepCheck = nil
        sleepCheckFailures = 0
        lidGrace = ReadingGrace()
        displayLidClosed = false
        displaySleepRetry = nil
        displaySleepFailed = false
        if lidHistory.first?.isOpenInterval == true {
            lidHistory[0].sessionEndedAt = .now
            lidHistory[0].interruption = reason
            saveHistory()
        }
        closedClocks = nil
        sessionActive = false
        deadline = nil
        expiresAt = nil
        trackedLid = nil
        trackedSource = nil
        profilesLeftAlone.removeAll()
        revisitingProfiles.removeAll()
        message = reason
        log.notice("\(reason, privacy: .public)")
        recover(deferEnergyRestore: deferEnergyRestore)
    }

    private func recover(deferEnergyRestore: Bool = false) {
        guard var entry = recovery else { return }
        var errors: [String] = []
        if entry.restoreSleep {
            do {
                try MacPower.setSleepDisabled(false)
                entry.restoreSleep = false
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        // Retain completed work in memory even when writing or removing the journal fails.
        recovery = entry
        if !entry.restoreSleep && !deferEnergyRestore {
            errors += restoreModes(&entry)
            recovery = entry
        }
        do {
            if !entry.needsRestoration {
                try removeJournal(at: file)
                recovery = nil
            } else {
                try save(entry)
            }
            recoveryWarning = nil
        } catch {
            recoveryWarning = "Couldn’t update the recovery record. LidStats will retry."
            errors.append(error.localizedDescription)
        }
        if !errors.isEmpty {
            log.error("Settings recovery pending: \(errors.joined(separator: "; "), privacy: .public)")
        }
    }

    private func restoreModes(_ entry: inout Recovery, cancelled: () -> Bool = { false }) -> [String] {
        var errors: [String] = []
        for source in [MacPower.Source.adapter, .battery] {
            guard let mode = entry[source] else { continue }
            do {
                try restoreMode(mode, for: source, cancelled: cancelled)
                entry[source] = nil
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return errors
    }

    private func restoreMode(_ saved: MacPower.Mode, for source: MacPower.Source, cancelled: () -> Bool) throws {
        let current = try MacPower.mode(for: source, cancelled: cancelled)
        if try saved.shouldRestore(over: current) {
            try saved.apply(saved.value, to: source, cancelled: cancelled)
        }
    }

    private func removeJournal(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    private func save(_ value: Recovery) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        recovery = value
    }
}
