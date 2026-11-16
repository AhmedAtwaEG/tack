import AppKit

/// The Tack window's settings page. For now just which Tack this is and where it comes from.
final class SettingsView: NSView {
    /// This build's home: the fork it is built from, not the original author's repo.
    private static let repo = "AhmedAtwaEG/tack"

    /// The version `bundle.sh` stamped into the app, from the latest git tag.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        autoresizingMask = [.width, .height]

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "Tack")
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        name.textColor = .labelColor

        let version = NSTextField(labelWithString: "Version \(Self.version)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true  // so a bug report can paste it

        let link = NSButton(title: "github.com/\(Self.repo)", target: self, action: #selector(openGitHub))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 12)
        link.setAccessibilityLabel("Open Tack on GitHub")

        let column = NSStackView(views: [icon, name, version, link])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.setCustomSpacing(12, after: icon)
        column.setCustomSpacing(12, after: version)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // The cursor says it's a link, like the text says.
    override func resetCursorRects() {
        for case let button as NSButton in subviews.flatMap({ $0.subviews }) {
            addCursorRect(convert(button.bounds, from: button), cursor: .pointingHand)
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/\(Self.repo)") { NSWorkspace.shared.open(url) }
    }
}
