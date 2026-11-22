import Foundation

// Driven by status requests from the menu bar app. Process I/O never runs on the session timer queue.
final class ChipPower {
    private let queue = DispatchQueue(label: "com.lidshift.chip-power", qos: .utility)
    private var sampling = false
    private var sample: (watts: Double, time: ContinuousClock.Instant)?

    func latestAndRefresh() -> Double? {
        dispatchPrecondition(condition: .onQueue(.main))
        if !sampling {
            sampling = true
            queue.async {
                let watts = Self.measure()
                DispatchQueue.main.async {
                    self.sample = watts.map { ($0, .now) }
                    self.sampling = false
                }
            }
        }
        guard let sample, sample.time.duration(to: .now) < .seconds(8) else { return nil }
        return sample.watts
    }

    private static func measure() -> Double? {
        let executable = URL(fileURLWithPath: "/usr/bin/powermetrics")
        let arguments = ["--samplers", "cpu_power,gpu_power,ane_power", "-i", "500", "-n", "1"]
        guard let output = try? MacPower.runPowerCommand(executable: executable, arguments: arguments) else { return nil }
        return parse(output)
    }

    static func parse(_ output: String) -> Double? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces)
                .hasPrefix("Combined Power") else { continue }
            let reading = fields[1].split(whereSeparator: \.isWhitespace)
            guard reading.count >= 2, let value = Double(reading[0]), value.isFinite, value >= 0 else { continue }
            switch reading[1] {
            case "mW": return value / 1_000
            case "W": return value
            default: continue
            }
        }
        return nil
    }
}
