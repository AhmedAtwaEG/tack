import AppKit

/// A line of text that floats near the top of the screen for a few seconds and fades — for
/// telling the user something Tack couldn't do for them, without a dialog to dismiss.
enum Hint {
    private static var panel: NSPanel?
    private static var generation = 0

    static func show(_ text: String, for seconds: TimeInterval = 4) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.sizeToFit()
        let pad = NSSize(width: 16, height: 10)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(label.frame.width + pad.width * 2, area.width - 40)
        let size = NSSize(width: width, height: label.frame.height + pad.height * 2)

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .hudWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = size.height / 2
        glass.layer?.masksToBounds = true
        label.frame = NSRect(
            x: pad.width, y: pad.height, width: size.width - pad.width * 2, height: label.frame.height)
        glass.addSubview(label)

        // Non-activating, so the app it is about stays in front.
        let p = panel ?? NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = glass
        p.setFrame(
            NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 24,
                   width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p

        generation += 1
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard shown == generation else { return }  // a newer hint replaced this one
            NSAnimationContext.runAnimationGroup(
                { $0.duration = 0.3; p.animator().alphaValue = 0 },
                completionHandler: { if shown == generation { p.orderOut(nil) } })
        }
    }
}
