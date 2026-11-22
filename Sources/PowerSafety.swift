import Foundation

struct ReadingGrace {
    private var missingSince: ContinuousClock.Instant?

    mutating func expired(available: Bool, now: ContinuousClock.Instant) -> Bool {
        if available {
            missingSince = nil
            return false
        }
        if let missingSince { return missingSince.duration(to: now) >= .seconds(3) }
        missingSince = now
        return false
    }
}

struct DisplaySleepRetry {
    enum Outcome {
        case pending, succeeded, failed
    }

    private var attemptsRemaining = 3
    private var nextAttempt: ContinuousClock.Instant?

    mutating func attempt(now: ContinuousClock.Instant, requestSleep: () throws -> Void) -> Outcome {
        if let nextAttempt, now < nextAttempt { return .pending }
        attemptsRemaining -= 1
        do {
            try requestSleep()
            return .succeeded
        } catch {
            guard attemptsRemaining > 0 else { return .failed }
            nextAttempt = now.advanced(by: .seconds(2))
            return .pending
        }
    }
}

// The watchdog only reads power state. System setting writes stay on the session queue.
final class PowerSafetyWatch {
    struct Stop {
        let reason: String
        let sleepAfterCutoff: Bool
    }

    private let lock = NSLock()
    private var generation = 0
    private var cutoff: Int?
    private var pending: Stop?
    private var powerGrace = ReadingGrace()

    func arm(cutoff: Int?) {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        self.cutoff = cutoff
        pending = nil
        powerGrace = ReadingGrace()
    }

    var stop: Stop? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    func poll(readPower: () -> MacPower.Reading = { MacPower.reading },
              tooHot: () -> Bool = { MacPower.tooHot }, now: ContinuousClock.Instant = .now) -> Bool {
        lock.lock()
        let sampleGeneration = generation
        let cutoff = self.cutoff
        lock.unlock()
        guard let cutoff else { return false }

        let critical = tooHot()
        let power = critical ? nil : readPower()
        lock.lock()
        defer { lock.unlock() }
        guard generation == sampleGeneration, pending == nil else { return false }
        if critical {
            pending = Stop(reason: "Session ended because macOS reported critical heat.", sleepAfterCutoff: false)
        } else if let power {
            let hasReading = power.source == .adapter || (power.source == .battery && power.batteryPercentage != nil)
            let expired = powerGrace.expired(available: hasReading, now: now)
            if hasReading, let reason = Self.batteryStopReason(power, cutoff: cutoff) {
                pending = Stop(reason: reason, sleepAfterCutoff: true)
            } else if expired {
                let missing = power.source == nil ? "the power source" : "the battery level"
                pending = Stop(reason: "Session ended because LidStats couldn’t read \(missing).", sleepAfterCutoff: false)
            }
        }
        return pending != nil
    }

    static func batteryStopReason(_ power: MacPower.Reading, cutoff: Int) -> String? {
        if power.source == .adapter { return nil }
        guard power.source == .battery, let percentage = power.batteryPercentage else {
            return "Battery level couldn’t be read."
        }
        if percentage <= cutoff { return "Battery reached the \(cutoff)% cutoff." }
        return nil
    }
}

struct CutoffSleepRetry: Codable {
    enum Outcome {
        case pending, finished, failed
    }

    let createdAt: Date
    let cutoff: Int
    private var attemptsRemaining = 3
    private var retryAt: Date?

    init(now: Date, cutoff: Int) {
        createdAt = now
        self.cutoff = cutoff
    }

    func isCurrent(at now: Date) -> Bool {
        (0..<20).contains(now.timeIntervalSince(createdAt)) &&
            (1...100).contains(cutoff) && (1...3).contains(attemptsRemaining)
    }

    mutating func attempt(now: Date, lidClosed: Bool?, power: MacPower.Reading, currentCutoff: Int,
                          prepareRequest: (Self) -> Void, requestSleep: () throws -> Void) -> Outcome {
        if lidClosed == false || power.source == .adapter { return .finished }
        if let percentage = power.batteryPercentage, percentage > min(cutoff, currentCutoff) { return .finished }
        guard isCurrent(at: now) else { return .failed }
        if let retryAt, now < retryAt { return .pending }
        attemptsRemaining -= 1
        retryAt = now.addingTimeInterval(2)
        if lidClosed == true, power.source == .battery, power.batteryPercentage != nil {
            prepareRequest(self)
            do {
                try requestSleep()
                return .finished
            } catch {
                // Retry a transient power-service error.
            }
        }
        return attemptsRemaining > 0 ? .pending : .failed
    }
}
