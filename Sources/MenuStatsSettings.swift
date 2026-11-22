import AppKit

final class MenuStatsSettings: NSObject {
    private struct Row {
        let view: NSStackView
        let visible: NSButton
        let color: NSColorWell
        let initialColor: NSColor
        let up: NSButton
        let down: NSButton
    }

    private let stats: MenuStats
    private var order: [MenuStats.Metric]
    private var rows: [MenuStats.Metric: Row] = [:]
    private let controls = NSStackView()
    private let stackNetwork = NSButton(checkboxWithTitle: "Stack upload and download", target: nil, action: nil)

    init(stats: MenuStats, appearance: NSAppearance) {
        self.stats = stats
        order = stats.order
        super.init()
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        for metric in order {
            let visible = NSButton(checkboxWithTitle: "Show \(metric.title)", target: nil, action: nil)
            visible.state = stats.hidden.contains(metric) ? .off : .on
            visible.setAccessibilityLabel("Show \(metric.title)")
            visible.widthAnchor.constraint(equalToConstant: 132).isActive = true
            let initialColor = stats.color(for: metric, dark: dark)
            let color = NSColorWell(style: .minimal)
            color.color = initialColor
            color.setAccessibilityLabel("\(metric.title) color")
            let up = moveButton("up", metric: metric, action: #selector(moveUp(_:)))
            let down = moveButton("down", metric: metric, action: #selector(moveDown(_:)))
            let view = NSStackView(views: [visible, color, up, down])
            view.spacing = 10
            controls.addArrangedSubview(view)
            rows[metric] = Row(view: view, visible: visible, color: color, initialColor: initialColor,
                               up: up, down: down)
        }
        stackNetwork.state = stats.stackNetwork ? .on : .off
        controls.addArrangedSubview(stackNetwork)
        updateArrows()
    }

    func run(startsAtLogin: Bool, needsLoginApproval: Bool) -> Bool? {
        let login = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
        login.state = startsAtLogin ? .on : .off
        login.toolTip = "Open LidStats when you log in."
        controls.setCustomSpacing(16, after: stackNetwork)
        controls.addArrangedSubview(login)
        let autoKeepAwake = NSButton(checkboxWithTitle: "Ask to Keep Awake on Launch", target: nil, action: nil)
        autoKeepAwake.state = (UserDefaults.standard.object(forKey: "keepAwakeOnLaunch") as? Bool ?? true) ? .on : .off
        controls.addArrangedSubview(autoKeepAwake)
        if needsLoginApproval {
            controls.addArrangedSubview(NSTextField(labelWithString: "Allow LidStats in System Settings → Login Items."))
        }
        let prompt = NSAlert()
        prompt.messageText = "LidStats Settings"
        prompt.accessoryView = controls
        controls.frame.size = controls.fittingSize
        prompt.addButton(withTitle: "Save")
        prompt.addButton(withTitle: "Cancel")
        prompt.addButton(withTitle: "Restore Defaults")
        NSApp.activate(ignoringOtherApps: true)

        let colorPanel = NSColorPanel.shared
        let workedWhenModal = colorPanel.worksWhenModal
        colorPanel.worksWhenModal = true
        defer { colorPanel.worksWhenModal = workedWhenModal }
        let response = prompt.runModal()
        for row in rows.values { row.color.deactivate() }
        if response == .alertFirstButtonReturn {
            var hidden: Set<MenuStats.Metric> = []
            var colors: [MenuStats.Metric: NSColor] = [:]
            for (metric, row) in rows {
                if row.visible.state != .on { hidden.insert(metric) }
                colors[metric] = row.color.color == row.initialColor ? stats.customColor(for: metric) : row.color.color
            }
            stats.save(order: order, hidden: hidden, colors: colors, stackNetwork: stackNetwork.state == .on)
            UserDefaults.standard.set(autoKeepAwake.state == .on, forKey: "keepAwakeOnLaunch")
            return login.state == .on
        } else if response == .alertThirdButtonReturn {
            stats.save(order: MenuStats.Metric.allCases, hidden: [], colors: [:], stackNetwork: true)
        }
        return nil
    }

    private func moveButton(_ direction: String, metric: MenuStats.Metric, action: Selector) -> NSButton {
        let label = "Move \(metric.title) \(direction)"
        let image = NSImage(systemSymbolName: "chevron.\(direction)", accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(metric.rawValue)
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }

    @objc private func moveUp(_ sender: NSButton) { move(sender, by: -1) }

    @objc private func moveDown(_ sender: NSButton) { move(sender, by: 1) }

    private func move(_ sender: NSButton, by step: Int) {
        guard let identifier = sender.identifier, let metric = MenuStats.Metric(rawValue: identifier.rawValue),
              let index = order.firstIndex(of: metric), let row = rows[metric] else { return }
        let destination = index + step
        guard order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        controls.removeArrangedSubview(row.view)
        row.view.removeFromSuperview()
        controls.insertArrangedSubview(row.view, at: destination)
        updateArrows()
    }

    private func updateArrows() {
        for (index, metric) in order.enumerated() {
            rows[metric]?.up.isEnabled = index > 0
            rows[metric]?.down.isEnabled = index < order.count - 1
        }
    }
}
