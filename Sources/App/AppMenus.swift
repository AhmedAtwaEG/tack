import AppKit

/// Everything the app puts in a menu: the status-bar menu and the invisible
/// Edit menu. No tracking state lives here — the stored properties it touches
/// stay on `AppDelegate`.
extension AppDelegate {
    /// The status-bar item. Retained by the caller; the bar only keeps a weak hold.
    func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image()

        let menu = NSMenu()
        menu.addItem(
            makeItem("Add note here", #selector(addNote), symbol: "note.text", key: "n"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Open Tack", #selector(openTack), symbol: "macwindow", key: "o"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Tack", #selector(quit), symbol: "power", key: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        return item
    }

    /// Creates a status-bar menu item with its action, keyboard shortcut, and SF Symbol.
    private func makeItem(_ title: String, _ action: Selector, symbol: String, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        img?.isTemplate = true  // menus recolour template images to match highlight/light-dark
        i.image = img
        return i
    }

    /// Adds another note to the focused surface — a window can hold as many as you like — and
    /// puts the caret in it.
    @objc func addNote() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
        guard let container = resolve() else {
            DebugLog.note("addNote: front=\(front): no surface identified")
            // Finder works without the grant; everything else needs it. Say so rather than do
            // nothing — a rebuilt, re-signed Tack silently loses it while Settings still shows it on.
            if front != FinderContainer.bundleID, !AXIsProcessTrusted() { explainMissingAccessibility() }
            return
        }
        guard let f = container.frame() else {
            return DebugLog.note("addNote: front=\(front): \(container.path) has no on-screen window")
        }
        guard let window = addNewNote(on: container, frame: f) else {
            return DebugLog.note("addNote: front=\(front): the note could not be shown")
        }
        DebugLog.note("addNote: added to \(container.path) in \(f.bounds)")
        NSApp.activate(ignoringOtherApps: true)
        window.focusForEditing()
    }

    /// Why "Add note here" can't work, and the one place to fix it. Settings can show Tack as
    /// allowed while the grant belongs to an earlier build, so the advice is to remove and re-add.
    private func explainMissingAccessibility() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Tack needs Accessibility access"
        alert.informativeText = """
            To pin notes to app windows, allow Tack in System Settings ▸ Privacy & Security ▸ \
            Accessibility. If Tack is already listed and switched on, remove it with “−”, add it \
            again with “+”, then quit and reopen Tack. Finder folders work without it.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the Tack window on every note. The floating notes are flushed first: each can be up
    /// to a debounce behind the disk the grid is about to read.
    @objc func openTack() { openDashboard(from: nil) }

    /// Terminates Tack through AppKit, which first asks the app delegate to flush pending saves.
    @objc func quit() { NSApp.terminate(nil) }
}
