import Darwin
import Foundation
import IOKit
import IOKit.ps

enum MacPower {
    static var lidClosed: Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    enum Source: String, Codable {
        case adapter = "AC Power"
        case battery = "Battery Power"

        var pmsetFlag: String { self == .adapter ? "-c" : "-b" }
    }

    struct Reading {
        var source: Source? = nil
        var batteryPercentage: Int? = nil
    }

    static var reading: Reading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info) else { return Reading() }
        var reading = Reading(source: Source(rawValue: source.takeUnretainedValue() as String))
        let powerSources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for powerSource in powerSources {
            guard let description = IOPSGetPowerSourceDescription(info, powerSource)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0, (0...maximum).contains(current) else { continue }
            reading.batteryPercentage = Int((100 * Double(current) / Double(maximum)).rounded())
            break
        }
        return reading
    }

    static var tooHot: Bool { ProcessInfo.processInfo.thermalState == .critical }

    struct Mode: Codable {
        let key: String
        let value: Int

        var isValid: Bool { ["lowpowermode", "powermode"].contains(key) && (0...2).contains(value) }

        func shouldRestore(over current: Mode?) throws -> Bool {
            guard let current, current.key == key else {
                throw LidStatsError("Couldn’t verify the current energy mode.")
            }
            return current.value == 1 && value != current.value
        }

        func apply(_ value: Int, to source: Source, cancelled: () -> Bool = { false }) throws {
            guard isValid, (0...2).contains(value) else {
                throw LidStatsError("The saved energy mode is invalid.")
            }
            try run([source.pmsetFlag, key, String(value)], cancelled: cancelled)
            guard let current = try mode(for: source, cancelled: cancelled),
                  current.key == key, current.value == value else {
                throw LidStatsError("macOS did not accept the requested energy mode.")
            }
        }
    }

    static func mode(for source: Source, cancelled: () -> Bool = { false }) throws -> Mode? {
        var inSourceSection = false
        for line in try run(["-g", "custom"], cancelled: cancelled).split(separator: "\n") {
            if line.hasSuffix(":") {
                inSourceSection = line == "\(source.rawValue):"
                continue
            }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if inSourceSection, parts.count == 2,
               ["lowpowermode", "powermode"].contains(String(parts[0])),
               let number = Int(parts[1]), (0...2).contains(number) {
                return Mode(key: String(parts[0]), value: number)
            }
        }
        return nil
    }

    static func sleepDisabled(cancelled: () -> Bool = { false }) throws -> Bool {
        try run(["-g"], cancelled: cancelled).split(separator: "\n").contains { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words == ["SleepDisabled", "1"]
        }
    }

    static func setSleepDisabled(_ disabled: Bool) throws {
        try run(["-a", "disablesleep", disabled ? "1" : "0"])
        guard try sleepDisabled() == disabled else {
            throw LidStatsError("macOS did not accept the sleep setting.")
        }
    }

    @discardableResult
    static func run(_ arguments: [String], cancelled: () -> Bool = { false }) throws -> String {
        try runPowerCommand(executable: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: arguments, cancelled: cancelled)
    }

    static func runPowerCommand(executable: URL, arguments: [String],
                                cancelled: () -> Bool = { false }) throws -> String {
        guard !cancelled() else { throw LidStatsError("Power command interrupted.") }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw LocalSocket.systemError("Reading power command output")
        }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + .milliseconds(100))
            }
        }
        try pipe.fileHandleForWriting.close()
        let deadline = DispatchTime.now() + .seconds(2)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        func drainOutput() throws {
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= 65_536 else { throw LidStatsError("Power command output exceeded its limit.") }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
        while true {
            try drainOutput()
            if exited.wait(timeout: min(deadline, .now() + .milliseconds(50))) == .success {
                try drainOutput()
                break
            }
            if cancelled() { throw LidStatsError("Power command interrupted.") }
            if DispatchTime.now() >= deadline { throw LidStatsError("\(executable.lastPathComponent) timed out.") }
        }
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw LidStatsError(output.isEmpty ? "pmset exited with status \(process.terminationStatus)." : output)
        }
        return output
    }
}
