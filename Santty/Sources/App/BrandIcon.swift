import AppKit

enum BrandIcon: String, CaseIterable, Sendable {
    case herdr = "BrandHerdr"
    case codex = "BrandCodex"
    case claudeCode = "BrandClaudeCode"
    case pi = "BrandPi"
    case opencode = "BrandOpenCode"
    case copilot = "BrandGitHubCopilot"

    @MainActor
    func image(size: CGFloat = 18) -> NSImage? {
        guard let image = NSImage(named: rawValue)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
    }
}
