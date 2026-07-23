import AppKit

@MainActor
final class PaneAutoResizePanelController: NSWindowController {
    var onChange: ((PaneAutoResizeConfiguration) -> Void)?

    private let enabledButton = NSButton(
        checkboxWithTitle: "Enable Focus Auto Resize", target: nil, action: nil)
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 196),
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

        horizontalSlider.target = self
        horizontalSlider.action = #selector(controlChanged(_:))
        verticalSlider.target = self
        verticalSlider.action = #selector(controlChanged(_:))

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        doneButton.bezelStyle = .rounded

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView(views: [
            enabledButton,
            sliderRow(
                title: "Horizontal", slider: horizontalSlider, valueLabel: horizontalValueLabel),
            sliderRow(title: "Vertical", slider: verticalSlider, valueLabel: verticalValueLabel),
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
    }

    private func sliderRow(title: String, slider: NSSlider, valueLabel: NSTextField) -> NSStackView
    {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let row = NSStackView(views: [titleLabel, slider, valueLabel])
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

        configuration = PaneAutoResizeConfiguration(
            isEnabled: enabledButton.state == .on,
            ratios: PaneFocusRatios(
                horizontal: CGFloat(horizontalSlider.doubleValue),
                vertical: CGFloat(verticalSlider.doubleValue)
            )
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
        horizontalSlider.doubleValue = Double(configuration.ratios.horizontal)
        verticalSlider.doubleValue = Double(configuration.ratios.vertical)
        horizontalValueLabel.stringValue = percentageString(for: configuration.ratios.horizontal)
        verticalValueLabel.stringValue = percentageString(for: configuration.ratios.vertical)
        horizontalSlider.isEnabled = configuration.isEnabled
        verticalSlider.isEnabled = configuration.isEnabled
        isUpdatingControls = false
    }

    private func percentageString(for ratio: CGFloat) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }
}
