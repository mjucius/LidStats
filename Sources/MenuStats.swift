import AppKit
import Darwin

final class MenuStats {
    private struct Traffic {
        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
    }

    private var previousCPU: [UInt32]?
    private var previousTraffic: (time: TimeInterval, interfaces: [UInt16: Traffic])?
    private(set) var cpu: Int?
    private var upload: Double?
    private var download: Double?
    private var activeRingImage: NSImage?
    private var activeRing: SessionRing?

    var canAnimateActiveRing: Bool {
        activeRing != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func updateActiveRing(on button: NSStatusBarButton, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let image = activeRingImage, let ring = activeRing else { return }
        let phase = canAnimateActiveRing ? uptime.truncatingRemainder(dividingBy: 10) / 10 : 0
        button.image = NSImage(size: image.size, flipped: false) { bounds in
            ring.draw(phase: CGFloat(phase))
            image.draw(in: bounds)
            return true
        }
    }

    enum Metric: String, CaseIterable {
        case cpu = "CPU"
        case chip = "Chip"
        case upload = "Upload"
        case download = "Download"
        case thermal = "Thermal"

        var title: String { self == .chip ? "Chip Power" : rawValue }
        var isNetwork: Bool { self == .upload || self == .download }
        var colorKey: String { "menu\(rawValue)Color" }
    }

    private(set) var order: [Metric] = {
        let saved = (UserDefaults.standard.stringArray(forKey: "menuStatOrder") ?? [])
            .compactMap(Metric.init(rawValue:))
        var seen = Set<Metric>()
        return (saved + Metric.allCases).filter { seen.insert($0).inserted }
    }()
    private(set) var hidden = Set((UserDefaults.standard.stringArray(forKey: "hiddenMenuStats") ?? [])
        .compactMap(Metric.init(rawValue:)))
    private(set) var stackNetwork = UserDefaults.standard.object(forKey: "stackMenuNetwork") as? Bool ?? true
    private var customColors: [Metric: NSColor] = {
        var colors: [Metric: NSColor] = [:]
        for metric in Metric.allCases {
            guard let data = UserDefaults.standard.data(forKey: metric.colorKey) else { continue }
            colors[metric] = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        }
        return colors
    }()

    func save(order: [Metric], hidden: Set<Metric>, colors: [Metric: NSColor], stackNetwork: Bool) {
        self.order = order
        self.hidden = hidden
        self.stackNetwork = stackNetwork
        UserDefaults.standard.set(stackNetwork, forKey: "stackMenuNetwork")
        self.customColors = colors.mapValues { $0.withAlphaComponent(1) }
        UserDefaults.standard.set(order.map(\.rawValue), forKey: "menuStatOrder")
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: "hiddenMenuStats")
        for metric in Metric.allCases {
            let data = customColors[metric].flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
            UserDefaults.standard.set(data, forKey: metric.colorKey)
        }
    }

    func color(for metric: Metric, dark: Bool) -> NSColor {
        if let color = customColors[metric] { return color }
        switch metric {
        case .cpu, .chip, .thermal: return dark ? .white : .black
        case .upload: return NSColor(srgbRed: dark ? 1 : 0.65, green: dark ? 0.69 : 0.27, blue: 0.16, alpha: 1)
        case .download: return NSColor(srgbRed: dark ? 0.42 : 0, green: dark ? 0.78 : 0.33, blue: dark ? 1 : 0.66, alpha: 1)
        }
    }

    func customColor(for metric: Metric) -> NSColor? { customColors[metric] }

    func sample() {
        cpu = nil
        if !hidden.contains(.cpu), let ticks = cpuTicks() {
            if let previousCPU {
                let changes = zip(ticks, previousCPU).map { Double($0 &- $1) }
                let total = changes.reduce(0, +)
                if total > 0 {
                    cpu = Int((100 * (1 - changes[Int(CPU_STATE_IDLE)] / total)).rounded())
                }
            }
            previousCPU = ticks
        } else {
            previousCPU = nil
        }

        upload = nil
        download = nil
        let now = ProcessInfo.processInfo.systemUptime
        if !(hidden.contains(.upload) && hidden.contains(.download)), let interfaces = networkCounters() {
            if let previousTraffic {
                let elapsed = now - previousTraffic.time
                if elapsed > 0 {
                    var delta = Traffic()
                    for (index, current) in interfaces {
                        guard let previous = previousTraffic.interfaces[index],
                              current.inbound >= previous.inbound,
                              current.outbound >= previous.outbound else { continue }
                        delta.inbound += current.inbound - previous.inbound
                        delta.outbound += current.outbound - previous.outbound
                    }
                    upload = Double(delta.outbound) / elapsed
                    download = Double(delta.inbound) / elapsed
                }
            }
            previousTraffic = (now, interfaces)
        } else {
            previousTraffic = nil
        }
    }

    private func cpuTicks() -> [UInt32]? {
        var ticks = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &ticks) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [ticks.cpu_ticks.0, ticks.cpu_ticks.1, ticks.cpu_ticks.2, ticks.cpu_ticks.3]
    }

    private func networkCounters() -> [UInt16: Traffic]? {
        var path = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&path, u_int(path.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = Data(count: size)
        let result = bytes.withUnsafeMutableBytes {
            sysctl(&path, u_int(path.count), $0.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }

        return bytes.withUnsafeBytes { buffer in
            var interfaces: [UInt16: Traffic] = [:]
            var offset = 0
            while offset + 4 <= size {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= size - offset else { return nil }
                if buffer[offset + 3] == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    // Darwin uses the en prefix for Ethernet and Wi-Fi. Exclude tunnels and virtual bridges.
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if message.ifm_flags & IFF_UP != 0,
                       if_indextoname(UInt32(message.ifm_index), &name) != nil,
                       String(cString: name).hasPrefix("en") {
                        interfaces[message.ifm_index] = Traffic(inbound: message.ifm_data.ifi_ibytes,
                                                               outbound: message.ifm_data.ifi_obytes)
                    }
                }
                offset += length
            }
            return interfaces
        }
    }

    private func rate(_ bytes: Double?) -> String {
        guard let bytes else { return "—" }
        if bytes < 1_000 { return "\(min(999, Int(bytes.rounded()))) B/s" }
        let value: Double
        let unit: String
        switch bytes {
        case ..<1_000_000: (value, unit) = (bytes / 1_000, "KB/s")
        case ..<1_000_000_000: (value, unit) = (bytes / 1_000_000, "MB/s")
        default: (value, unit) = (bytes / 1_000_000_000, "GB/s")
        }
        if value < 99.95 { return String(format: "%.1f %@", value, unit) }
        return String(format: "%.0f %@", unit == "GB/s" ? value : min(999, value.rounded()), unit)
    }

    func render(chipWatts: Double?, active: Bool, uncertain: Bool = false,
                thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
                on button: NSStatusBarButton) {
        let thermal: (display: String, full: String)
        switch thermalState {
        case .nominal: thermal = ("OK", "Nominal")
        case .fair: thermal = ("Fair", "Fair")
        case .serious: thermal = ("High", "Serious")
        case .critical: thermal = ("Crit", "Critical")
        @unknown default: thermal = ("—", "Unknown")
        }
        let cpuValue = cpu.map { "\($0)%" } ?? "—"
        let power = chipWatts.map { String(format: $0 < 99.95 ? "%.1f W" : "%.0f W", $0) } ?? "N/A"
        let up = rate(upload)
        let down = rate(download)

        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        let symbol = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [ink]))
        let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        let fraction = CGFloat(cpu ?? 0) / 100
        let pixel = 1 / (button.window?.backingScaleFactor ?? 1)
        var groups: [[Metric]] = []
        for metric in order where !hidden.contains(metric) {
            if stackNetwork, metric.isNetwork, groups.last?.first?.isNetwork == true {
                groups[groups.count - 1].append(metric)
            } else {
                groups.append([metric])
            }
        }
        func styled(_ text: String, size: CGFloat, color: NSColor,
                    boldValue: Substring? = nil) -> NSAttributedString {
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
                .foregroundColor: color
            ])
            if let boldValue {
                let range = (text as NSString).range(of: String(boldValue))
                if range.location != NSNotFound {
                    attributed.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
                                            range: range)
                }
            }
            return attributed
        }
        let padding: CGFloat = 4
        let gap: CGFloat = 5
        let cpuTextInset: CGFloat = 8
        let columns = groups.map { group in
            var reservedWidth: CGFloat = 0
            var lines: [(text: NSAttributedString, x: CGFloat, y: CGFloat)] = []
            var barColor: NSColor?
            for (row, metric) in group.enumerated() {
                let color = color(for: metric, dark: dark)
                switch metric {
                case .cpu:
                    barColor = color
                    reservedWidth = max(reservedWidth, cpuTextInset + styled("100%", size: 9, color: color).size().width)
                    lines.append((styled("CPU", size: 8, color: color), cpuTextInset, 11))
                    lines.append((styled(cpuValue, size: 9, color: color), cpuTextInset, 1))
                case .chip:
                    reservedWidth = max(reservedWidth, styled("99.9 W", size: 9, color: color).size().width)
                    lines.append((styled("CHIP", size: 8, color: color), 0, 11))
                    lines.append((styled(power, size: 9, color: color), 0, 1))
                case .thermal:
                    lines.append((styled("HEAT", size: 8, color: color), 0, 11))
                    lines.append((styled(thermal.display, size: 9, color: color), 0, 1))
                    for stage in ["OK", "Fair", "High", "Crit"] {
                        reservedWidth = max(reservedWidth, styled(stage, size: 9, color: color).size().width)
                    }
                case .upload, .download:
                    let rate = metric == .upload ? up : down
                    let arrow = metric == .upload ? "↑" : "↓"
                    let y: CGFloat = group.count == 1 ? 6 : (row == 0 ? 11 : 1)
                    for unit in ["KB/s", "MB/s", "GB/s"] {
                        let sample = styled("\(arrow) 99.9 \(unit)", size: 8, color: color, boldValue: "99.9")
                        reservedWidth = max(reservedWidth, sample.size().width)
                    }
                    let text = styled("\(arrow) \(rate)", size: 8, color: color,
                                      boldValue: rate.split(separator: " ", maxSplits: 1).first)
                    lines.append((text, 0, y))
                }
            }
            let width = ceil(max(reservedWidth, lines.map { $0.x + $0.text.size().width }.max() ?? 0))
            return (lines: lines, barColor: barColor, width: width)
        }
        let imageWidth = columns.isEmpty ? 16 : 2 * padding + columns.reduce(0) { $0 + $1.width }
            + CGFloat(columns.count - 1) * gap
        let image = NSImage(size: NSSize(width: imageWidth, height: 22), flipped: false) { _ in
            if columns.isEmpty {
                let iconRect = NSRect(x: 0, y: 3, width: 16, height: 16)
                if active, let bolt {
                    ink.setFill()
                    NSBezierPath(ovalIn: iconRect).fill()
                    bolt.draw(in: iconRect.insetBy(dx: 4.5, dy: 3), from: .zero,
                              operation: .destinationOut, fraction: 1)
                } else {
                    symbol?.draw(in: iconRect)
                }
            } else if uncertain {
                ink.setStroke()
                let bounds = NSRect(x: 0, y: 0, width: imageWidth, height: 22)
                let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                outline.lineWidth = 1
                outline.setLineDash([2, 2], count: 2, phase: 0)
                outline.stroke()
            }
            var x = padding
            for column in columns {
                if let color = column.barColor {
                    let track = NSRect(x: x, y: 2, width: 5, height: 18)
                    color.withAlphaComponent(0.24).setFill()
                    NSBezierPath(rect: track).fill()
                    if fraction > 0 {
                        color.setFill()
                        NSBezierPath(rect: NSRect(x: x, y: track.minY, width: track.width,
                                                  height: track.height * fraction)).fill()
                    }
                    ink.setStroke()
                    let border = NSBezierPath(rect: track.insetBy(dx: pixel / 2, dy: pixel / 2))
                    border.lineWidth = pixel
                    border.stroke()
                }
                for line in column.lines {
                    line.text.draw(at: NSPoint(x: x + line.x, y: line.y))
                }
                x += column.width + gap
            }
            return true
        }
        if active && !uncertain && !columns.isEmpty {
            activeRingImage = image
            if activeRing?.size != image.size || activeRing?.dark != dark {
                activeRing = SessionRing(size: image.size, dark: dark)
            }
            updateActiveRing(on: button)
        } else {
            activeRingImage = nil
            activeRing = nil
            button.image = image
        }
        var labels = [active ? "Keep-awake session active" : "LidStats"]
        for metric in order where !hidden.contains(metric) {
            switch metric {
            case .cpu: labels.append("CPU \(cpuValue)")
            case .chip: labels.append("Chip power \(chipWatts == nil ? "unavailable" : power)")
            case .upload: labels.append("Upload \(up)")
            case .download: labels.append("Download \(down)")
            case .thermal: labels.append("Thermal pressure \(thermal.full)")
            }
        }
        let label = labels.joined(separator: ", ")
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }
}


private struct SessionRing {
    let size: NSSize
    let dark: Bool
    private let segments: [(path: NSBezierPath, offset: CGFloat)]

    init(size: NSSize, dark: Bool) {
        self.size = size
        self.dark = dark
        let bounds = NSRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
        let outline = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).flattened
        var start = NSPoint.zero
        var last = NSPoint.zero
        var point = NSPoint.zero
        var length: CGFloat = 0
        var paths: [(path: NSBezierPath, distance: CGFloat)] = []
        for index in 0..<outline.elementCount {
            switch outline.element(at: index, associatedPoints: &point) {
            case .moveTo:
                start = point
                last = point
                continue
            case .closePath:
                point = start
            case .lineTo:
                break
            default:
                continue
            }

            let dx = point.x - last.x
            let dy = point.y - last.y
            let distance = hypot(dx, dy)
            if distance > 0 {
                let count = Int(ceil(distance / 2.5))
                for part in 0..<count {
                    let from = CGFloat(part) / CGFloat(count)
                    let to = CGFloat(part + 1) / CGFloat(count)
                    let path = NSBezierPath()
                    path.lineCapStyle = .round
                    path.move(to: NSPoint(x: last.x + dx * from, y: last.y + dy * from))
                    path.line(to: NSPoint(x: last.x + dx * to, y: last.y + dy * to))
                    paths.append((path, length + distance * (from + to) / 2))
                }
                length += distance
            }
            last = point
        }
        segments = paths.map { ($0.path, $0.distance / length) }
    }

    func draw(phase: CGFloat) {
        for (path, offset) in segments {
            let position = offset - phase + (offset < phase ? 1 : 0)
            let highlight = pow((1 + cos((position - 0.16) * 2 * .pi)) / 2, 6)
            let color = NSColor(calibratedHue: position, saturation: dark ? 0.68 : 0.89,
                                brightness: (dark ? 0.86 : 0.58) + 0.14 * highlight, alpha: 1)
            if highlight > 0.05 {
                color.withAlphaComponent(0.22 * highlight).setStroke()
                path.lineWidth = 3
                path.stroke()
            }
            color.setStroke()
            path.lineWidth = 0.9 + 1.2 * highlight
            path.stroke()
        }
    }
}
