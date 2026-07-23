import AppKit

@MainActor
final class FontPanelTarget: NSObject {
    private var currentFont: NSFont = .monospacedSystemFont(
        ofSize: TerminalSettings.defaultFontSize,
        weight: .regular
    )
    private var onChange: ((NSFont) -> Void)?

    func showFontPanel(
        family: String,
        size: CGFloat,
        onChange: @escaping (NSFont) -> Void
    ) {
        currentFont = NSFont(name: family, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        self.onChange = onChange

        let fontManager = NSFontManager.shared
        fontManager.target = self
        fontManager.action = #selector(changeFont(_:))
        fontManager.setSelectedFont(currentFont, isMultiple: false)
        fontManager.orderFrontFontPanel(nil)
    }

    @objc private func changeFont(_ sender: NSFontManager) {
        currentFont = sender.convert(currentFont)
        onChange?(currentFont)
    }
}
