import AppKit
import Darwin
import Foundation
import ServiceManagement
import Security

@main
final class LidStatsApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private let stats = MenuStats()
    private let clientQueue = DispatchQueue(label: "com.lidshift.client")
    private var status: Status? {
        didSet {
            if let status { lastKnownActive = status.isActive || status.recovering || status.recoveryRequired == true }
            if historyWindow?.isVisible == true, oldValue?.lidHistory != status?.lidHistory {
                updateHistory()
            }
        }
    }
    private var historyWindow: NSWindow?
    private var historyText: NSTextView?
    private var checking = false
    private var busy = false
    private var startOnLaunch = true
    private let launchStartDeadline = ContinuousClock.now.advanced(by: .seconds(30))
    private var lastKnownActive = UserDefaults.standard.object(forKey: "sessionMayBeActive") as? Bool
        ?? FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(label)") {
        didSet { UserDefaults.standard.set(lastKnownActive, forKey: "sessionMayBeActive") }
    }
    private var uncertainStartUntil: TimeInterval? = {
        let deadline = UserDefaults.standard.double(forKey: "unconfirmedStartDeadline")
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        return remaining > 0 && remaining <= 15 ? deadline : nil
    }() {
        didSet { UserDefaults.standard.set(uncertainStartUntil, forKey: "unconfirmedStartDeadline") }
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--probe-helper"] || arguments == ["--probe-helper", "--allow-recovery"] {
            do {
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                let status = try exchange(Request(action: .status), deadline: deadline)
                guard status.hasCurrentPowerHelper,
                      arguments.contains("--allow-recovery") || (status.recoveryRequired == false && !status.recovering) else {
                    throw LidStatsError("The helper is incompatible or requires recovery.")
                }
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = LidStatsApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        item.menu = menu
        menu.delegate = self
        stats.sample()
        updateIcon()
        refresh()
        let statsTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.stats.sample()
            self?.updateIcon()
        }
        RunLoop.main.add(statsTimer, forMode: .common)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "LidStats", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "LidStats", attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        ])
        menu.addItem(title)

        if busy {
            info("Updating session…")
        } else if let status {
            info(status.message)
            if let percentage = status.batteryPercentage {
                info(status.pluggedIn ? "Plugged in · Battery \(percentage)%" : "On battery · \(percentage)%")
            }
            if status.isActive {
                if let end = status.deadline {
                    info("Ends at \(end.formatted(date: .omitted, time: .shortened))")
                } else {
                    info("Keeping awake until ended")
                }
                info(status.lowPowerEnabled ? "Low Power Mode is on" : "Low Power Mode is off")
                menu.addItem(.separator())
                command("End Session", #selector(endSession))
            } else if status.recoveryRequired == true {
                command("Restore Normal Sleep…", #selector(repairSleep))
            } else if status.recovering {
                info("Restoring macOS power settings…")
            } else if !status.hasCurrentPowerHelper {
                info("Update the power helper to start a session")
            } else if status.lidClosed == nil {
                info("MacBook lid state unavailable")
            } else if status.lidClosed == true {
                info("Open the lid to start a session")
            } else if !status.pluggedIn && status.batteryPercentage == nil {
                info("Battery level unavailable")
            } else if !status.pluggedIn, let percentage = status.batteryPercentage,
                      let cutoff = status.batteryCutoff, percentage <= cutoff {
                info("Charge above \(cutoff)% to start a session")
            } else {
                menu.addItem(.separator())
                command("Keep Awake", #selector(startIndefinitely))
                let sessions = NSMenu()
                for hours in [1, 4, 8, 12] {
                    let duration = hours == 1 ? "1 Hour" : "\(hours) Hours"
                    let entry = NSMenuItem(title: duration, action: #selector(startSession(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.tag = hours
                    sessions.addItem(entry)
                }
                let entry = NSMenuItem(title: "Start With Timer", action: nil, keyEquivalent: "")
                entry.submenu = sessions
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            if !status.hasCurrentPowerHelper {
                command("Update Power Helper…", #selector(showSetup))
            }
            if let history = status.lidHistory {
                if let latest = history.first {
                    info(historySummary(latest, prefix: "Last lid close"))
                }
                command("Activity History…", #selector(showHistory))
            }
            if let cutoff = status.batteryCutoff {
                command("Battery Cutoff… (\(cutoff)%)", #selector(editBatteryCutoff))
            }
        } else {
            if lastKnownActive {
                info("Session status unknown · Mac may still be awake")
                command("End Session", #selector(endSession))
            } else {
                info(checking ? "Checking the power helper…" : "Power helper unavailable")
            }
            command("Power Helper Setup…", #selector(showSetup))
        }

        menu.addItem(.separator())
        command("Settings…", #selector(showSettings), shortcut: ",")
        command("Quit LidStats", #selector(quit), shortcut: "q")
    }

    private func info(_ text: String) {
        menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: ""))
    }

    private func command(_ text: String, _ action: Selector, shortcut: String = "") {
        let entry = NSMenuItem(title: text, action: action, keyEquivalent: shortcut)
        entry.target = self
        menu.addItem(entry)
    }

    private func updateIcon() {
        let active = status?.isActive == true
        if let button = item?.button {
            let uncertain = status == nil && lastKnownActive
            stats.render(chipWatts: status?.chipWatts, active: active, uncertain: uncertain, on: button)
            if uncertain {
                button.toolTip = "Session status unknown. Your Mac may still be kept awake."
                button.setAccessibilityLabel(button.toolTip)
            }
        }
    }

    private func refresh() {
        guard !busy, !checking else { return }
        checking = true
        send(Request(action: .status, wantsChipPower: !stats.hidden.contains(.chip))) { result in
            self.checking = false
            guard !self.busy else { return }
            let refreshed = try? result.get()
            if let until = self.uncertainStartUntil, refreshed?.isActive != true,
               ProcessInfo.processInfo.systemUptime < until {
                return
            }
            self.uncertainStartUntil = nil
            self.status = refreshed
            self.updateIcon()
            guard self.startOnLaunch else { return }
            guard ContinuousClock.now < self.launchStartDeadline,
                  UserDefaults.standard.object(forKey: "keepAwakeOnLaunch") as? Bool ?? true else {
                self.startOnLaunch = false
                return
            }
            guard let status = self.status, !status.recovering else { return }
            self.startOnLaunch = false
            guard status.hasCurrentPowerHelper,
                  status.sessionActive == false, status.recoveryRequired == false,
                  status.lidClosed == false,
                  status.pluggedIn || (status.batteryPercentage ?? 0) > (status.batteryCutoff ?? 100)
            else { return }
            self.startIndefinitely()
        }
    }

    private static func exchange(_ request: Request, deadline: TimeInterval? = nil) throws -> Status {
        let socket = try LocalSocket.open()
        defer { close(socket.descriptor) }
        if let deadline {
            try socket.connectToPowerHelper(deadline: deadline)
            try socket.send(request, deadline: deadline)
            return try socket.receive(Status.self, deadline: deadline)
        }
        try socket.connectToPowerHelper()
        try socket.send(request)
        return try socket.receive(Status.self, timeout: request.action == .status ? 3 : 15)
    }

    private func send(_ request: Request, completion: @escaping (Result<Status, Error>) -> Void) {
        clientQueue.async {
            let result = Result { try Self.exchange(request) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    @objc private func startSession(_ sender: NSMenuItem) {
        run(Request(action: .start, hours: sender.tag))
    }

    @objc private func startIndefinitely() { run(Request(action: .start)) }
    @objc private func endSession() { run(Request(action: .stop)) }

    private func historySummary(_ activity: LidActivity, prefix: String = "Lid close") -> String {
        if activity.isOpenInterval { return "Lid closed · Keep-awake session active" }
        guard let reopened = activity.reopenedAt else { return "\(prefix) · Session interrupted" }
        let elapsed = max(0, reopened.timeIntervalSince(activity.closedAt))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        let duration = formatter.string(from: elapsed) ?? "0s"
        var summary = "\(prefix) · \(duration)"
        if let start = activity.batteryAtClose, let end = activity.batteryAtReopen {
            summary += " · Battery \(start)% → \(end)%"
        }
        if activity.detectedSleep == true { summary += " · Sleep detected during observation" }
        return summary
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Activity History"
            window.minSize = NSSize(width: 360, height: 240)
            window.isReleasedWhenClosed = false
            let scroll = NSTextView.scrollableTextView()
            if let view = scroll.documentView as? NSTextView {
                view.isEditable = false
                view.textContainerInset = NSSize(width: 20, height: 16)
                view.setAccessibilityLabel("Lid activity history")
                historyText = view
            }
            window.contentView = scroll
            window.center()
            historyWindow = window
        }
        updateHistory()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func updateHistory() {
        guard let historyText else { return }
        let content = NSMutableAttributedString()
        func append(_ line: String, heading: Bool = false) {
            content.append(NSAttributedString(string: line + "\n", attributes: [
                .font: heading ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13),
                .foregroundColor: heading ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]))
        }
        func event(_ label: String, _ date: Date, battery: Int? = nil) {
            let time = date.formatted(date: .abbreviated, time: .standard)
            let charge = battery.map { " · Battery \($0)%" } ?? ""
            append("\(label)  \(time)\(charge)")
        }

        if let history = status?.lidHistory {
            if history.isEmpty {
                append("No lid activity recorded yet.", heading: true)
                append("Close the lid during a keep-awake session to record activity.")
            }
            for (index, activity) in history.enumerated() {
                if index > 0 { append("") }
                append(historySummary(activity), heading: true)
                event("Closed", activity.closedAt, battery: activity.batteryAtClose)
                if let reopened = activity.reopenedAt {
                    event("Reopened", reopened, battery: activity.batteryAtReopen)
                    if activity.detectedSleep == false { append("No system sleep detected between the recorded lid observations.") }
                }
                if activity.displaySleepFailed == true {
                    append("LidStats couldn’t put the display to sleep after three attempts.")
                }
                if let ended = activity.sessionEndedAt { event("Session ended", ended) }
                if let interruption = activity.interruption { append(interruption) }
            }
        } else {
            append("Activity history is unavailable.", heading: true)
        }
        historyText.textStorage?.setAttributedString(content)
    }

    @objc private func repairSleep() {
        let prompt = NSAlert()
        prompt.messageText = "Restore normal sleep?"
        prompt.informativeText = "LidStats can re-enable system sleep. The damaged journal cannot tell LidStats which energy mode to restore."
        prompt.addButton(withTitle: "Restore Sleep")
        prompt.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if prompt.runModal() == .alertFirstButtonReturn {
            run(Request(action: .repairSleep))
        }
    }

    @objc private func showSettings() {
        let appearance = item?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let loginItem = SMAppService.mainApp
        let loginStatus = loginItem.status
        let startsAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
        let settings = MenuStatsSettings(stats: stats, appearance: appearance)
        if let enabled = settings.run(startsAtLogin: startsAtLogin, needsLoginApproval: loginStatus == .requiresApproval),
           enabled != startsAtLogin {
            do {
                if enabled {
                    try loginItem.register()
                } else {
                    try loginItem.unregister()
                }
            } catch {
                if !enabled || loginItem.status != .requiresApproval {
                    alert("Couldn’t update Start at Login", detail: error.localizedDescription)
                }
            }
            if enabled && loginItem.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
        stats.sample()
        updateIcon()
        refresh()
    }

    @objc private func editBatteryCutoff() {
        guard let cutoff = status?.batteryCutoff else { return }
        let slider = BatteryCutoffSlider(cutoff: cutoff)
        let controls = NSStackView(views: [slider, slider.readout])
        controls.spacing = 8
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        slider.readout.widthAnchor.constraint(equalToConstant: 44).isActive = true
        controls.frame.size = controls.fittingSize
        let prompt = NSAlert()
        prompt.messageText = "Battery Cutoff"
        prompt.informativeText = "End the session when the Mac is on battery and reaches this percentage. Choose a cutoff from 5% to 100%."
        prompt.accessoryView = controls
        prompt.window.initialFirstResponder = slider
        prompt.addButton(withTitle: "Save")
        prompt.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if prompt.runModal() == .alertFirstButtonReturn {
            run(Request(action: .setBatteryCutoff, batteryCutoff: slider.percentage))
        }
    }

    private func confirmKeepAwake(hours: Int?) -> Bool {
        let prompt = NSAlert()
        prompt.alertStyle = .warning
        if let hours {
            prompt.messageText = hours == 1 ? "Keep this Mac awake for 1 hour?" : "Keep this Mac awake for \(hours) hours?"
        } else {
            prompt.messageText = "Keep this Mac awake until you end the session?"
        }
        prompt.informativeText = """
        Keeping a MacBook awake with the lid closed can make it easier to overheat. Leave the lid open when practical, keep the Mac ventilated, and end the session before putting it in a bag.

        LidStats attempts to enable Low Power Mode when the lid closes and restore normal sleep if macOS reports critical heat. These safeguards don’t guarantee cooling, sleep, shutdown, or protection from damage. Damage from use outside Apple’s operating guidelines may be excluded from warranty coverage. Use at your own risk.
        """
        prompt.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        prompt.addButton(withTitle: "Start Session").keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        return prompt.runModal() == .alertSecondButtonReturn
    }

    private func run(_ action: Request) {
        var request = action
        guard !busy else { return }
        busy = true
        if request.action == .start || request.action == .stop { startOnLaunch = false }
        if request.action == .start {
            guard confirmKeepAwake(hours: request.hours) else {
                busy = false
                refresh()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            request.startRequestedAtUptime = now
            request.startExpiresAtUptime = now + 15
            lastKnownActive = true
            uncertainStartUntil = request.startExpiresAtUptime
        }
        send(request) { result in
            self.busy = false
            do {
                var status = try result.get()
                status.chipWatts = self.status?.chipWatts
                if request.action == .start || request.action == .stop || status.isActive {
                    self.uncertainStartUntil = nil
                } else if let until = self.uncertainStartUntil, ProcessInfo.processInfo.systemUptime < until {
                    if let error = status.error { self.alert("LidStats", detail: error) }
                    return
                }
                self.status = status
                self.updateIcon()
                if let error = status.error { self.alert("LidStats", detail: error) }
            } catch {
                self.status = nil
                self.updateIcon()
                self.refresh()
                self.alert("Power helper unavailable", detail: error.localizedDescription)
            }
        }
    }

    @objc private func showSetup() {
        let project = Bundle.main.bundleURL.deletingLastPathComponent()
        let installer = project.appendingPathComponent("setup-helper.sh").path
        let upgrading = FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(label)")
        let operation = upgrading ? "upgrade" : "install"
        var code: SecCode?
        var staticCode: SecStaticCode?
        var signingInfo: CFDictionary?
        var installOptions = "--local-development"
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
           let team = (signingInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
           team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
            installOptions = "--team-id \(team)"
        }
        let help = "From the LidStats project folder, run ./setup-helper.sh \(operation) \(installOptions) in Terminal. macOS will ask for administrator authentication."
        guard FileManager.default.fileExists(atPath: installer) else {
            alert(upgrading ? "Update the power helper" : "Install the power helper",
                  detail: "Quit LidStats and run the LidStats installer package, then reopen the app.")
            return
        }
        let prompt = NSAlert()
        prompt.messageText = upgrading ? "Update the power helper" : "Install the power helper"
        prompt.informativeText = help
        prompt.addButton(withTitle: "Copy Terminal Command")
        prompt.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if prompt.runModal() == .alertFirstButtonReturn {
            let quotedPath = "'" + installer.replacingOccurrences(of: "'", with: "'\\''") + "'"
            NSPasteboard.general.clearContents()
            let command = "\(quotedPath) \(operation) \(installOptions)"
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    @objc private func quit() {
        guard !busy else { return }
        if lastKnownActive {
            let prompt = NSAlert()
            prompt.messageText = "Quit LidStats?"
            prompt.informativeText = "Your Mac may still be kept awake after you quit. Reopen LidStats to check the session or restore normal sleep."
            prompt.addButton(withTitle: "Quit")
            prompt.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard prompt.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private final class BatteryCutoffSlider: NSSlider {
    let readout = NSTextField(labelWithString: "")
    var percentage: Int { Int(doubleValue.rounded()) }

    init(cutoff: Int) {
        super.init(frame: .zero)
        minValue = 5
        maxValue = 100
        doubleValue = Double(max(5, cutoff))
        isContinuous = true
        setAccessibilityLabel("Battery cutoff percentage")
        target = self
        action = #selector(updateReadout)
        updateReadout()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    @objc private func updateReadout() {
        readout.stringValue = "\(percentage)%"
    }
}
