import AppKit

@MainActor
final class PaneAutoResizePanelController: NSWindowController {
    var onChange: ((PaneAutoResizeConfiguration) -> Void)?

    private let enabledButton = NSButton(
        checkboxWithTitle: "Enable Auto Resize", target: nil, action: nil)
    private let triggerControl = NSSegmentedControl(
        labels: ["Focus", "Unfocused"], trackingMode: .selectOne, target: nil, action: nil)
    private let horizontalEnabledButton = NSButton(
        checkboxWithTitle: "Horizontal", target: nil, action: nil)
    private let verticalEnabledButton = NSButton(
        checkboxWithTitle: "Vertical", target: nil, action: nil)
    private let horizontalSlider = NSSlider(
        value: 0.7, minValue: 0.25, maxValue: 0.95, target: nil, action: nil)
    private let verticalSlider = NSSlider(
        value: 0.7, minValue: 0.25, maxValue: 0.95, target: nil, action: nil)
    private let horizontalValueLabel = NSTextField(labelWithString: "70%")
    private let verticalValueLabel = NSTextField(labelWithString: "70%")

    private var configuration = WorkspaceFocusZoomConfiguration.defaultAutoResizeConfiguration
    private var isUpdatingControls = false

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 234),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Auto Resize"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        installContent()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func show(configuration: PaneAutoResizeConfiguration, relativeTo parentWindow: NSWindow) {
        self.configuration = configuration
        updateControls()

        guard let panel = window as? NSPanel else {
            return
        }

        if let sheetParent = panel.sheetParent {
            sheetParent.endSheet(panel)
        }

        parentWindow.beginSheet(panel)
    }

    private func installContent() {
        enabledButton.target = self
        enabledButton.action = #selector(controlChanged(_:))
        triggerControl.target = self
        triggerControl.action = #selector(controlChanged(_:))
        triggerControl.setAccessibilityLabel("Trigger")
        for button in [horizontalEnabledButton, verticalEnabledButton] {
            button.target = self
            button.action = #selector(controlChanged(_:))
        }
        horizontalEnabledButton.setAccessibilityLabel("Enable Horizontal Resize")
        verticalEnabledButton.setAccessibilityLabel("Enable Vertical Resize")

        horizontalSlider.target = self
        horizontalSlider.action = #selector(controlChanged(_:))
        horizontalSlider.setAccessibilityLabel("Horizontal")
        verticalSlider.target = self
        verticalSlider.action = #selector(controlChanged(_:))
        verticalSlider.setAccessibilityLabel("Vertical")

        let triggerLabel = NSTextField(labelWithString: "Trigger")
        triggerLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let triggerRow = NSStackView(views: [triggerLabel, triggerControl])
        triggerRow.alignment = .centerY
        triggerRow.spacing = 10

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        doneButton.bezelStyle = .rounded

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView(views: [
            enabledButton,
            triggerRow,
            sliderRow(
                enabledButton: horizontalEnabledButton, slider: horizontalSlider, valueLabel: horizontalValueLabel),
            sliderRow(enabledButton: verticalEnabledButton, slider: verticalSlider, valueLabel: verticalValueLabel),
            buttonRow(doneButton),
        ])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stackView)
        window?.contentView = contentView

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
        updateControls()
    }

    private func sliderRow(enabledButton: NSButton, slider: NSSlider, valueLabel: NSTextField) -> NSStackView
    {
        enabledButton.widthAnchor.constraint(equalToConstant: 100).isActive = true
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 166).isActive = true

        let row = NSStackView(views: [enabledButton, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func buttonRow(_ doneButton: NSButton) -> NSStackView {
        let spacer = NSView()
        let row = NSStackView(views: [spacer, doneButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return row
    }

    @objc private func controlChanged(_: Any?) {
        guard !isUpdatingControls else {
            return
        }

        let trigger: PaneAutoResizeConfiguration.Trigger =
            triggerControl.selectedSegment == 1 ? .unfocused : .focus
        let range = trigger.ratioRange
        configuration = PaneAutoResizeConfiguration(
            isEnabled: enabledButton.state == .on,
            ratios: PaneFocusRatios(
                horizontal: CGFloat(min(max(horizontalSlider.doubleValue, range.lowerBound), range.upperBound)),
                vertical: CGFloat(min(max(verticalSlider.doubleValue, range.lowerBound), range.upperBound))
            ),
            trigger: trigger,
            isHorizontalEnabled: horizontalEnabledButton.state == .on,
            isVerticalEnabled: verticalEnabledButton.state == .on
        )
        updateControls()
        onChange?(configuration)
    }

    @objc private func done(_: Any?) {
        guard let panel = window else {
            return
        }

        if let sheetParent = panel.sheetParent {
            sheetParent.endSheet(panel)
        } else {
            panel.close()
        }
    }

    private func updateControls() {
        isUpdatingControls = true
        enabledButton.state = configuration.isEnabled ? .on : .off
        triggerControl.selectedSegment = configuration.trigger == .focus ? 0 : 1
        triggerControl.isEnabled = configuration.isEnabled
        horizontalEnabledButton.state = configuration.isHorizontalEnabled ? .on : .off
        verticalEnabledButton.state = configuration.isVerticalEnabled ? .on : .off
        horizontalEnabledButton.isEnabled = configuration.isEnabled
        verticalEnabledButton.isEnabled = configuration.isEnabled
        for slider in [horizontalSlider, verticalSlider] {
            slider.minValue = configuration.trigger.ratioRange.lowerBound
            slider.maxValue = configuration.trigger.ratioRange.upperBound
        }
        horizontalSlider.doubleValue = Double(configuration.ratios.horizontal)
        verticalSlider.doubleValue = Double(configuration.ratios.vertical)
        horizontalValueLabel.stringValue = percentageString(for: configuration.ratios.horizontal)
        verticalValueLabel.stringValue = percentageString(for: configuration.ratios.vertical)
        horizontalSlider.isEnabled = configuration.isEnabled && configuration.isHorizontalEnabled
        verticalSlider.isEnabled = configuration.isEnabled && configuration.isVerticalEnabled
        isUpdatingControls = false
    }

    private func percentageString(for ratio: CGFloat) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }
}
