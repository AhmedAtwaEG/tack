import AppKit

/// The Tack window: every note (`NoteGrid`) or the settings page, in an ordinary titled window
/// of its own. A note is only ever a note — nothing here borrows a floating note's window.
///
/// Tack stays a menu-bar agent (`LSUIElement`) while this is up: no Dock icon, no ⌘Tab. Turning
/// it into a regular app for the window's sake broke the 📌 menu in full-screen Spaces — a
/// click on a regular app's menu-bar item there takes you to the app's own desktop instead of
/// opening the menu. The 📌's "Open Tack" brings the window back from behind other windows.
final class DashboardWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let grid: NoteGrid
    private let window: NSWindow
    /// A soft wash of the notes' own colours behind the grid. The cards are glass that frosts
    /// what is behind it *within* this window, so the window has to give them something to frost.
    private let backdrop = GradientView(frame: .zero)
    private let page = NSView()
    private lazy var settings = SettingsView()
    private var showingSettings = false

    private let searchItem = NSSearchToolbarItem(itemIdentifier: Item.search)
    private let settingsItem = NSToolbarItem(itemIdentifier: Item.settings)

    /// The window closed; anything pending in its cards has been written.
    var onClose: (() -> Void)?

    private enum Item {
        static let search = NSToolbarItem.Identifier("tack.search")
        static let settings = NSToolbarItem.Identifier("tack.settings")
    }

    init(grid: NoteGrid) {
        self.grid = grid
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Tack"
        window.minSize = NSSize(width: 360, height: 260)
        window.isReleasedWhenClosed = false
        // Comes to the desktop you are on, rather than taking you to the one it was last on —
        // including a full-screen app's, the way the floating notes do.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // The cards are always drawn light; a dark frame around them would fight them.
        window.appearance = NSAppearance(named: .aqua)
        window.center()  // first run only: the autosaved frame wins from then on
        window.setFrameAutosaveName("tackDashboard")

        let content = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Self.paneColor.cgColor
        backdrop.frame = content.bounds
        content.addSubview(backdrop)
        page.frame = content.bounds
        page.autoresizingMask = [.width, .height]
        content.addSubview(page)
        window.contentView = content
        super.init()

        searchItem.searchField.placeholderString = "Search notes"
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(searchChanged)
        settingsItem.label = "Settings"
        settingsItem.target = self
        settingsItem.action = #selector(toggleSettings)
        settingsItem.isBordered = true
        showSettingsButton()

        let toolbar = NSToolbar(identifier: "tack.dashboard")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.delegate = self

        mount(grid.view)
        grid.onChange = { [weak self] in
            guard let self else { return }
            backdrop.show(self.grid.colors)
        }
    }

    /// The pane under the wash, solid. Read in the light appearance the cards are drawn in.
    private static var paneColor: NSColor {
        var color = NSColor.windowBackgroundColor
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            color = color.usingColorSpace(.sRGB) ?? color
        }
        return color
    }

    /// Opened and not closed since — minimised included, which `isVisible` would call closed,
    /// and a minimised grid still has to keep pace with the notes it holds.
    private(set) var isOpen = false

    /// Read every note from disk and bring the window up on them — or, already up, just
    /// forward. The caller flushes the floating notes first: the grid is about to read disk.
    func open() {
        if !isOpen {
            isOpen = true
            searchItem.searchField.stringValue = ""  // every opening starts on every note
            grid.search("")
            if showingSettings { toggleSettings() }
            grid.reload()
            backdrop.show(grid.colors)
            // On the display you opened it from: the menu bar or the note you clicked.
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
                window.setFrame(Self.placed(window.frame, on: screen.visibleFrame), display: false)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Where the window opens within `area` (a display's visible frame): where it was left, when
    /// that is on this display; otherwise the same size, shrunk to fit, centred on it. Pure.
    static func placed(_ frame: NSRect, on area: NSRect) -> NSRect {
        if area.contains(NSPoint(x: frame.midX, y: frame.midY)) { return frame }
        let size = NSSize(width: min(frame.width, area.width - 40), height: min(frame.height, area.height - 40))
        return NSRect(
            x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: - Pages

    private func mount(_ view: NSView) {
        page.subviews.forEach { $0.removeFromSuperview() }
        view.frame = page.bounds
        view.autoresizingMask = [.width, .height]
        page.addSubview(view)
    }

    @objc private func toggleSettings() {
        showingSettings.toggle()
        grid.unfocus()
        mount(showingSettings ? settings : grid.view)
        searchItem.searchField.isEnabled = !showingSettings
        showSettingsButton()
    }

    /// The button always leads to the *other* page.
    private func showSettingsButton() {
        let (symbol, name) = showingSettings ? ("rectangle.stack", "All notes") : ("gearshape", "Settings")
        settingsItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        settingsItem.toolTip = name
        settingsItem.paletteLabel = name
    }

    @objc private func searchChanged() { grid.search(searchItem.searchField.stringValue) }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Item.search, Item.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case Item.search: return searchItem
        case Item.settings: return settingsItem
        default: return nil
        }
    }

    // MARK: - NSWindowDelegate

    /// A card whose save failed still holds its edit, and a closed grid is reconciled with
    /// nothing: kept, that edit would land later — on reopen or quit — over whatever the note
    /// became meanwhile, or bring back a note deleted since. So it lands now, or the user drops it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !grid.flush() else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some edits could not be saved"
        alert.informativeText = "Closing the window now loses them."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        grid.discardPending()
        return true
    }

    /// Closing is not quitting: pending edits still have to reach disk.
    func windowWillClose(_ notification: Notification) {
        isOpen = false
        grid.unfocus()
        grid.flush()
        onClose?()
    }
}

/// The Tack window's background: a soft diagonal gradient through the colours of its notes.
/// Layer-hosting (the layer is set before `wantsLayer`), so colour changes animate on their own.
private final class GradientView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0, y: 1)  // top-left to bottom-right
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer = gradient
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Washed over the pane rather than painted solid, so it reads as a tint of the notes, and
    /// the notes' own glass stays the strongest colour on screen.
    func show(_ hexes: [String]) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        gradient.colors = hexes.map { Swatch.color(fromHex: $0).withAlphaComponent(0.45).cgColor }
        CATransaction.commit()
    }
}
