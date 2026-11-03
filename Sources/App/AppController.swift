import AppKit

/// Owns the app's lifecycle and the two loops that decide which note is on screen
/// and where. Menu construction lives in AppMenus.swift.
/// One note on screen: its window, the surface it belongs to, and the level it's pinned at.
private final class ShownNote {
    let window: NoteWindow
    let container: Container
    /// A reference cell, shared with the note's save closure — see LevelBox.
    let level: LevelBox

    init(window: NoteWindow, container: Container, level: LevelBox) {
        self.window = window
        self.container = container
        self.level = level
    }

    /// Where this note is stored right now. Computed, not kept: a pin change moves it.
    var key: String { container.key(at: level.value) }
}

/// Owns the app's lifecycle and the two loops that decide which notes are on screen
/// and where. Menu construction lives in AppMenus.swift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every floating note window built so far. Reused rather than thrown away, so flipping
    /// between surfaces doesn't build and tear down windows on every poll.
    private var pool: [NoteWindow] = []
    /// The notes on screen now, all belonging to `current`.
    private var shown: [ShownNote] = []
    private var statusItem: NSStatusItem?
    /// The Tack window — every note at once. Nil until it is first opened, so a session that
    /// never opens it never builds a window.
    private(set) var grid: NoteGrid?
    private var pollTimer: Timer?  // slow: which surface is focused (~0.4s)
    private var trackLink: CADisplayLink? {  // vsync glue: the shown notes follow their window
        didSet { oldValue?.invalidate() }  // an outlived link would keep firing
    }
    private var lastPersistenceError: String?

    var current: Container?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = makeStatusItem()
        installEditMenu()
        AXWindows.promptForPermission()  // needed to bind notes to non-Finder app windows

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollTarget()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        flushAll() && (grid?.flush() ?? true) ? .terminateNow : .terminateCancel
    }

    /// Every window's pending edit, written now. Every window is flushed even after one fails: a
    /// note that can't save must not cost the others theirs.
    @discardableResult func flushAll() -> Bool {
        pool.map { $0.flushPendingSave() }.allSatisfy { $0 }
    }

    // MARK: - Target resolution

    /// The surface the user is focused on right now (or `current` while we're editing our own
    /// note, which would otherwise resolve to Tack itself).
    func resolve() -> Container? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return current }
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return current }
        return Container.resolve(front: front)
    }

    // MARK: - Loops

    private func pollTarget() {
        guard let container = resolve() else {
            hideAll()
            current = nil
            return
        }
        // Container is a class, so compare its stable focus key rather than object identity.
        // Browser titles and Terminal titles may change without the actual tab changing.
        // an unchanged surface must cost nothing per poll, and must never hide a showing note.
        guard container.focusKey != current?.focusKey else { return }
        // Don't latch a surface we can't place the note on — leaving `current` nil means the
        // next poll retries, rather than stranding the note hidden until the user focuses away.
        guard let f = container.frame() else {
            hideAll()
            current = nil
            return
        }
        // ponytail: opt-in path logging for diagnosing identity. Enable with
        //   defaults write com.tack.app debugPaths -bool YES
        // then watch with: log stream --predicate 'process == "Tack"'
        if UserDefaults.standard.bool(forKey: "debugPaths") {
            NSLog("[tack] path=%@", container.path.joined(separator: " / "))
        }
        // Edits still in a debounce must reach disk before it's read, or coming back to a
        // surface within half a second would show what its notes said before the edit.
        flushAll()
        do {
            present(try container.loadAll(), frame: f, container: container)
            current = container
            lastPersistenceError = nil
        } catch {
            hideAll()
            reportPersistenceError(error)
        }
    }

    @objc private func trackTarget() {
        guard let f = current?.frame() else { return }
        shown.forEach { apply(f, to: $0.window) }
    }

    /// The one place a note follows its window. Containers that can't be covered report no
    /// occluders, so the same two lines serve Finder and app windows alike. Each note is tested
    /// on its own: a window covering one corner hides only the note sitting there.
    private func apply(_ f: Frame, to window: NoteWindow) {
        window.updateWindow(bounds: f.bounds)
        window.setOccluded(f.covering.contains { $0.intersects(window.screenRectTopLeft()) })
    }

    /// Glue the shown notes to their window, sampled in sync with the display's own refresh — the
    /// full rate on 120Hz ProMotion, where a fixed 60fps timer updates at half the window's rate
    /// and visibly stutters. Polling, not AX move events, is what keeps the notes locked during a
    /// live drag: the OS coalesces AXWindowMoved notifications, so an event-driven note trails.
    ///
    /// One link drives every note. It comes from the *screen* the notes are on, not from a note's
    /// window: a note covered by another window is ordered out, and a link tied to an ordered-out
    /// window can stop firing — which would freeze every other note in place mid-drag. Rebuilt
    /// whenever the set changes.
    private func startTracking() {
        guard let first = shown.first, let screen = first.window.screen ?? NSScreen.main
        else { return stopTracking() }
        let link = screen.displayLink(target: self, selector: #selector(trackTarget))
        link.add(to: .main, forMode: .common)
        trackLink = link
    }

    // MARK: - Show / hide

    /// Replace whatever is on screen with `notes`, all on `container`.
    private func present(_ notes: [(note: Note, level: Int)], frame f: Frame, container: Container) {
        hideAll()
        for hit in notes { show(hit.note, level: hit.level, frame: f, container: container) }
        startTracking()
    }

    /// Put one note on screen, in a free window from the pool or a new one. The caller restarts
    /// tracking. Nil only if the note couldn't be shown at all.
    @discardableResult
    func show(_ n: Note, level: Int, frame f: Frame, container: Container) -> NoteWindow? {
        let box = LevelBox(level)  // this note's own level cell — see LevelBox
        let save: (Note) -> Bool = { [weak self] edited in
            self?.persist { try container.write(edited, at: box.value) } ?? false
        }
        // A window still holding an edit it can't save refuses to show (its show() flushes
        // first); it keeps that edit, and the note goes to the next free window instead.
        let busy = Set(shown.map { ObjectIdentifier($0.window) })
        let window =
            pool.first { !busy.contains(ObjectIdentifier($0)) && $0.show(note: n, bounds: f.bounds, save: save) }
            ?? makeWindow(showing: n, bounds: f.bounds, save: save)
        guard let window else { return nil }

        shown.append(ShownNote(window: window, container: container, level: box))
        // Only an open dashboard cares, and only it knows this note by its storage key.
        window.onLiveEdit = { [weak self] edited in
            self?.grid?.update(key: container.key(at: box.value), note: edited)
        }
        window.onDelete = { [weak self, weak window] in
            guard let self, let window else { return }
            forget(window)
        }
        let choices = (container.minLevel...container.finestLevel).map {
            (level: $0, label: LevelName.label(level: $0, of: container.path.count))
        }
        window.setPinLevels(choices, current: level) { [weak self, weak window] newLevel in
            guard let self, let window else { return false }
            let moved = self.persist {
                // A note never typed in isn't on disk: there's nothing to move, only the level
                // its first save will land at.
                guard let id = window.noteID, let hit = try container.find(id: id) else { return }
                window.adoptID(try container.move(hit.note, from: hit.level, to: newLevel).id)
            }
            guard moved else { return false }
            box.value = newLevel  // redirect this note's later edits — same cell the save closure reads
            return true
        }
        apply(f, to: window)
        return window
    }

    private func makeWindow(showing n: Note, bounds: CGRect, save: @escaping (Note) -> Bool)
        -> NoteWindow?
    {
        let window = NoteWindow()
        pool.append(window)
        return window.show(note: n, bounds: bounds, save: save) ? window : nil
    }

    /// A note left the screen for good (deleted): stop tracking it, and rebuild the shared
    /// display link if it was the one the link came from.
    private func forget(_ window: NoteWindow) {
        shown.removeAll { $0.window === window }
        startTracking()
    }

    private func hideAll() {
        shown.forEach { $0.window.hide() }
        shown = []
        stopTracking()
    }

    /// A new, empty note on the focused surface, placed so it doesn't sit exactly on top of one
    /// that's already there. It reaches disk with its first keystroke, like any note.
    func addNewNote(on container: Container, frame f: Frame) -> NoteWindow? {
        if container.focusKey != current?.focusKey {  // bring its existing notes up alongside
            flushAll()
            do {
                present(try container.loadAll(), frame: f, container: container)
            } catch {
                reportPersistenceError(error)
                return nil
            }
            current = container
        }
        let size = NotePreferences.shared.defaultSize
        let spot = Coord.cascade(
            from: Coord.center(note: size, window: f.bounds.size),
            avoiding: shown.map(\.window.offset), note: size, window: f.bounds.size)
        let window = show(
            Note.new(dx: spot.dx, dy: spot.dy), level: container.finestLevel, frame: f,
            container: container)  // finest available, promote later
        startTracking()
        return window
    }

    @discardableResult
    func persist(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            lastPersistenceError = nil
            return true
        } catch {
            reportPersistenceError(error)
            return false
        }
    }

    /// Builds the Tack window the first time it is asked for, and shows it.
    func openGrid() {
        let window = grid ?? NoteGrid { [weak self] error in self?.reportPersistenceError(error) }
        window.onLiveEdit = { [weak self] key, edited in
            guard let self,
                let entry = shown.first(where: { $0.key == key && $0.window.noteID == edited.id })
            else { return }  // not on screen: nothing to keep in step
            if edited.isDeletion {
                entry.window.hideDiscardingPendingSave()
                forget(entry.window)
            } else {
                entry.window.applyLive(edited)
            }
        }
        grid = window
        window.open()
    }

    func reportPersistenceError(_ error: Error) {
        let message = error.localizedDescription
        guard message != lastPersistenceError else { return }
        lastPersistenceError = message
        NSLog("[tack] persistence error: %@", message)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Tack could not save your note"
        alert.informativeText = message
        alert.runModal()
    }

    private func stopTracking() {
        trackLink = nil  // didSet invalidates it on the way out
    }
}
