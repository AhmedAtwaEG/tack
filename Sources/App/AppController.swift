import AppKit

/// One note on screen: its window, where it is stored, and what Tack last knew of it.
final class ShownNote {
    let window: NoteWindow
    /// The surface it was shown on. Its own, not its place's: the place swaps in a fresh
    /// container when a tab's title changes, and a key built from the new title would lose a note
    /// stored under the old one. The save closure writes through this same container.
    let container: Container
    let level: LevelBox  // see LevelBox
    /// The note as Tack last read or wrote it — what a save compares the file against, so it
    /// never writes over a newer one (see Note.merge).
    var seen: Note?

    init(window: NoteWindow, container: Container, level: LevelBox, seen: Note?) {
        self.window = window
        self.container = container
        self.level = level
        self.seen = seen
    }

    /// Where the note is stored right now. Computed, not kept: a pin change moves it.
    var key: String { container.key(at: level.value) }
}

/// One app's place on screen: the surface its notes are glued to, and every note pinned there.
/// Each app gets its own, so the notes on an app you have clicked away from stay where they are.
final class ShownPlace {
    /// The surface the notes follow. Replaced by a fresh one with the same focus key when the
    /// same folder or document comes back in a second window — it carries the window to follow.
    var container: Container
    var notes: [ShownNote] = []
    var lastBounds: CGRect?  // where the tracked window was at the last sample
    var stillFrames = 0  // samples since it last moved — see samples(stillFrames:)
    var missing = 0  // samples in a row its window was nowhere on a desktop in view — see trackNotes

    init(container: Container) { self.container = container }
}

/// Owns the app's lifecycle and the two loops that decide which notes are on screen
/// and where. Menu construction lives in AppMenus.swift.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Every floating note window built so far. Reused rather than thrown away, so flipping
    /// between surfaces doesn't build and tear down windows on every poll.
    private var pool: [NoteWindow] = []
    /// The places with notes on screen, one per app, keyed by `Container.app`.
    private var places: [String: ShownPlace] = [:]
    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?  // slow: which surface is focused (~0.4s)
    private var trackLink: CADisplayLink? {  // vsync glue: each shown note follows its window
        didSet { oldValue?.invalidate() }  // an outlived link would keep firing
    }
    private var lastPersistenceError: String?
    private var pollWhenSettled = false  // a poll is already waiting for the screen to settle — see pollTarget

    /// The focused surface, as of the last poll.
    var current: Container? {
        didSet { if current?.focusKey != oldValue?.focusKey { refreshElsewhere() } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = makeStatusItem()
        statusItem?.menu?.delegate = self
        installEditMenu()
        AXWindows.promptForPermission()  // needed to bind notes to non-Finder app windows
        AXWindows.limitWaiting()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollTarget()
            self?.syncFromDisk()
        }
        pollTimer?.tolerance = 0.1  // lets macOS line this wake-up up with others
        // No updater in this build: installing anyone's release over it would drop its own
        // features and its signing (and with it the Accessibility grant). bundle.sh updates it.

        // A note outlives its app's focus now, so nothing else would ever take it down when the
        // app quits: its window just vanishes from the list and the note would wait for it forever.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier { self?.hidePlace(app: id) }
        }

        // The tracking link belongs to one screen. Unplug that screen and it may never fire again, and nothing else would start a new one: `startTracking` only does when there is none.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, trackLink != nil else { return }
            trackLink = nil
            startTracking()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Everything is flushed before anything is judged: `&&` would skip the rest after a failure.
        let notesSaved = flushAll()
        let gridSaved = grid.flush()
        if notesSaved && gridSaved { return .terminateNow }
        // Refusing outright made Quit a dead button for as long as the save kept failing.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some edits could not be saved"
        alert.informativeText = "Quitting now loses them."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
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

    /// Decides what the *focused* app shows. Only that app's notes are ever changed here: the
    /// notes of every other app stay up, following their own windows.
    private func pollTarget() {
        // A surface resolved mid-switch between desktops would be placed where the slide has its window. Looked at again every tenth of a second until the screen has settled, so a note that needs this poll to come up doesn't also wait out the 0.4s timer.
        if WindowServer.isRearranging() {
            guard !pollWhenSettled else { return }
            pollWhenSettled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.pollWhenSettled = false
                self?.pollTarget()
            }
            return
        }
        guard let container = resolve() else {
            // Nothing to pin to in front (no window, no folder): that app's notes go.
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                hidePlace(app: front)
            }
            current = nil
            return
        }
        // Back on a surface whose notes never left the screen: nothing to load or re-show. The
        // fresh container replaces the old one, though — it carries the window to follow, which
        // differs when the same folder or document is open in a second window.
        if let place = places[container.app], place.container.focusKey == container.focusKey {
            place.container = container
            current = container
            return
        }
        // Container is a class, so compare its stable focus key rather than object identity.
        // Browser titles and Terminal titles may change without the actual tab changing.
        // an unchanged surface must cost nothing per poll, and must never hide a showing note.
        guard container.focusKey != current?.focusKey else { return }
        // Don't latch a surface we can't place the note on — leaving `current` nil means the
        // next poll retries, rather than stranding the note hidden until the user focuses away.
        guard let f = container.frame() else {
            DebugLog.note("poll: \(container.path.first ?? "?") has no on-screen window to pin to")
            hidePlace(app: container.app)
            current = nil
            return
        }
        DebugLog.note("poll: path=\(container.path.joined(separator: " / ")) frame=\(f.bounds)")
        // Edits still in a debounce must reach disk before it's read, or coming back to a
        // surface within half a second would show what its notes said before the edit.
        flushAll()
        do {
            present(try container.loadAll(), frame: f, container: container)
            current = container
            lastPersistenceError = nil
        } catch {
            hidePlace(app: container.app)
            reportPersistenceError(error)
        }
    }

    @objc private func trackNotes() {
        var showing = false
        // One read of the window list for the whole frame — see WindowServer.sharingOneRead.
        WindowServer.sharingOneRead {
            for place in places.values where !place.notes.isEmpty {
                showing = true
                place.stillFrames += 1
                guard Self.samples(stillFrames: place.stillFrames) else { continue }
                // Mid-switch between desktops, or in Mission Control, every window is reported where the animation has it. The notes are left alone then, riding their own desktop, which is all they have to do — see WindowServer.isRearranging.
                if WindowServer.isRearranging() { continue }
                // No window to follow — minimised, hidden, on another Space. The notes wait out of
                // sight and come back with the window; only a new focus or a quit takes them down.
                guard let f = place.container.frame() else {
                    // On another desktop there is nothing to do: the notes are out of sight there already, and left up they ride back in with their window instead of popping in once the switch is over. Only on a desktop in view are they taken down, and only at the second sample in a row: AppKit learns of a desktop switch a moment after the window list shows it.
                    let inView = place.notes.contains { $0.window.isOnActiveSpace }
                    place.missing = inView ? place.missing + 1 : 0
                    if place.missing >= 2 { place.notes.forEach { $0.window.setOccluded(true) } }
                    continue
                }
                place.missing = 0
                if f.bounds != place.lastBounds {
                    place.lastBounds = f.bounds
                    place.stillFrames = 0
                }
                place.notes.forEach { apply(f, to: $0.window) }
            }
        }
        if !showing { trackLink = nil }  // nothing left to follow; show starts it again
    }

    /// Whether this frame reads the window list. Every frame while the window is moving; once it
    /// has sat still for 30, one frame in six — the read walks every window on screen, and a
    /// window at rest was paying for it at the full refresh rate.
    /// shortcut: the first frame of a new drag can be up to five frames late (~40ms at 120Hz);
    /// wake on AXWindowMoved instead if that ever shows.
    static func samples(stillFrames: Int) -> Bool { stillFrames < 30 || stillFrames % 6 == 0 }

    /// The one place a note follows its window, and hides while another window covers its spot
    /// — which is what keeps the notes of an app in the background from floating over the app
    /// in front of it. Each note is tested on its own: a window covering one corner hides only
    /// the note sitting there.
    private func apply(_ f: Frame, to note: NoteWindow) {
        note.joinActiveSpace()
        note.updateWindow(bounds: f.bounds)
        let spot = note.screenRectTopLeft()
        note.setOccluded(f.covering.contains { $0.intersects(spot) })
    }

    /// Glue the shown notes to their windows, sampled in sync with the display's own refresh — a
    /// fixed 60fps timer updates at half a 120Hz window's rate and visibly stutters. Polling, not
    /// AX move events, is what keeps a note locked during a live drag: the OS coalesces
    /// AXWindowMoved notifications, so an event-driven note trails.
    ///
    /// The link comes from the screen, not from a note's window: a window's link pauses while
    /// the window is off screen, and a hidden note is exactly the one waiting to be told its
    /// window is back.
    /// shortcut: every note ticks at the main screen's rate, whatever display it is on; give each
    /// note its own screen's link if a mixed-refresh setup shows a stutter.
    private func startTracking() {
        guard trackLink == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(trackNotes))
        link.add(to: .main, forMode: .common)
        trackLink = link
    }

    // MARK: - Show / hide

    /// Replace whatever `container`'s app shows with `notes`, all on `container`.
    private func present(_ notes: [(note: Note, level: Int)], frame f: Frame, container: Container) {
        hidePlace(app: container.app)
        DebugLog.note("present: \(notes.count) note(s) on \(container.focusKey)")
        guard !notes.isEmpty else { return }
        let place = ShownPlace(container: container)
        places[container.app] = place
        for hit in notes { show(hit.note, level: hit.level, in: place, frame: f) }
        startTracking()
    }

    /// Windows that can't be handed a new note: the ones showing a note.
    private var busyWindows: Set<ObjectIdentifier> {
        Set(places.values.flatMap(\.notes).map { ObjectIdentifier($0.window) })
    }

    /// Put one note on screen in `place`, in a free window from the pool or a new one. The
    /// caller starts tracking.
    @discardableResult
    private func show(_ n: Note, level: Int, in place: ShownPlace, frame f: Frame) -> NoteWindow {
        let container = place.container
        let box = LevelBox(level)  // this note's own level cell — see LevelBox
        let busy = busyWindows
        // A free window still holding an edit is one whose save failed (every other was flushed
        // before the poll got here). It keeps that edit for a later flush — on quit at the latest
        // — rather than have it dropped by the next note it shows.
        let window = pool.first { !busy.contains(ObjectIdentifier($0)) && !$0.hasPendingEdit } ?? makeWindow()
        let shown = ShownNote(window: window, container: container, level: box, seen: n)
        DebugLog.note("show: id=\(n.id ?? "-") level=\(level) chars=\(n.text.count) window=\(pool.firstIndex { $0 === window } ?? -1)")
        place.notes.append(shown)
        place.lastBounds = nil
        place.stillFrames = 0  // a note just shown tracks at full rate from its first frame

        window.show(note: n, bounds: f.bounds) { [weak self, weak shown] edited in
            guard let self else { return false }
            return persist {
                // Never over a newer file: a script may have rewritten it since — see Note.merge.
                let disk = try container.notes(at: box.value).first { $0.id == edited.id }
                let toWrite = Note.merge(mine: edited, seen: shown?.seen, disk: disk)
                try container.write(toWrite, at: box.value)
                DebugLog.note("save: id=\(toWrite.id ?? "-") chars=\(toWrite.text.count) merged=\(toWrite != edited)")
                shown?.seen = toWrite
                if toWrite != edited { self.cascade(key: container.key(at: box.value), note: toWrite) }
            }
        }
        // Only an open Tack window cares, and only it knows this note by its storage key.
        window.onLiveEdit = { [weak self] edited in
            guard let self, dashboardOpen else { return }
            grid.update(key: container.key(at: box.value), note: edited)
        }
        window.onDelete = { [weak self, weak window] in
            guard let self, let window else { return }
            forget(window)
        }
        window.onOpenAll = { [weak self] in self?.openDashboard() }
        let choices = container.pinLevels.map {
            (
                level: $0, label: LevelName.label(level: $0, of: container.path.count),
                symbol: LevelName.symbol(level: $0, of: container.path.count),
                place: Container.placeName(for: container.key(at: $0))
            )
        }
        window.setPinLevels(choices, current: level) { [weak self, weak window, weak shown] newLevel in
            guard let self, let window else { return false }
            let moved = self.persist {
                // A note never typed in isn't on disk: there's nothing to move, only the level
                // its first save will land at.
                guard let id = window.noteID, let hit = try container.find(id: id) else { return }
                let note = try container.move(hit.note, from: hit.level, to: newLevel)
                window.adoptID(note.id)
                shown?.seen = note
            }
            guard moved else { return false }
            box.value = newLevel  // redirect this note's later edits — same cell the save closure reads
            // The next new note in this app starts where this one was just put.
            if let app = container.path.first, container.pinLevels.contains(0) {
                NotePreferences.shared.setPinsAppWide(app, newLevel == 0)
            }
            // The dashboard knows a note by its key, and the key just changed: left alone, its
            // cell would write the note back under the old one on the next edit there.
            if self.dashboardOpen { self.grid.reload() }
            return true
        }
        apply(f, to: window)
        return window
    }

    private func makeWindow() -> NoteWindow {
        let window = NoteWindow()
        pool.append(window)
        return window
    }

    /// A new, empty note on the focused surface, placed so it doesn't sit exactly on top of one
    /// that's already there. It reaches disk with its first keystroke, like any note.
    func addNewNote(on container: Container, frame f: Frame) -> NoteWindow? {
        if places[container.app]?.container.focusKey != container.focusKey {
            flushAll()  // bring its existing notes up alongside
            do {
                present(try container.loadAll(), frame: f, container: container)
            } catch {
                reportPersistenceError(error)
                return nil
            }
        }
        current = container
        let place = places[container.app] ?? ShownPlace(container: container)
        places[container.app] = place
        let size = NotePreferences.shared.defaultSize
        let spot = Coord.cascade(
            from: Coord.center(note: size, window: f.bounds.size),
            avoiding: place.notes.map(\.window.offset), note: size, window: f.bounds.size)
        let level = NotePreferences.newNoteLevel(
            pinLevels: container.pinLevels, finest: container.finestLevel,
            appWide: container.path.first.map(NotePreferences.shared.pinsAppWide) ?? false)
        let window = show(Note.new(dx: spot.dx, dy: spot.dy), level: level, in: place, frame: f)
        startTracking()
        window.pulsePlace()
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

    /// Every note on screen, with the place it belongs to.
    private var allShown: [(place: ShownPlace, note: ShownNote)] {
        places.values.flatMap { place in place.notes.map { (place, $0) } }
    }

    /// The note on screen stored at `key` under `id`, if any.
    private func shown(key: String, id: String?) -> (place: ShownPlace, note: ShownNote)? {
        allShown.first { $0.note.key == key && $0.note.window.noteID == id }
    }

    // MARK: - Changes from outside

    /// Modification dates of the note files on screen, as last looked at.
    private var fileDates: [URL: Date?] = [:]

    /// Every poll: has a file behind a note on screen — a floating note, or a card in an open
    /// dashboard — changed since the last look? Then those notes are read again and shown.
    /// A date per file, not a watcher: one stat per file per poll is nothing, it survives the
    /// write-to-a-temp-file-and-rename most tools do, and Finder notes live in many folders.
    private func syncFromDisk() {
        // Every level a shown place loads, not only the ones holding a note now: a note a script
        // adds to any of them belongs on screen too.
        var onScreen = Array(places.values.flatMap(\.container.allKeys)) + allShown.map(\.note.key)
        if dashboardOpen { onScreen += grid.keys }
        var keysByFile: [URL: Set<String>] = [:]
        for key in onScreen {
            if let url = StoredNote.fileURL(of: key) { keysByFile[url, default: []].insert(key) }
        }
        // The dashboard also gains notes a script adds to the central store.
        if dashboardOpen, let store = AppNotes.storeURL, keysByFile[store] == nil {
            keysByFile[store] = []
        }

        for (url, keys) in keysByFile {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let known = fileDates[url]
            fileDates[url] = date
            guard let known, known != date else { continue }  // first look only records the date
            do {
                var changed = keys
                if url == AppNotes.storeURL, dashboardOpen {
                    changed.formUnion(try AppNotes.all().keys)
                }
                for key in changed { adoptFromDisk(key: key, notes: try StoredNote.load(key: key)) }
            } catch {
                // Unreadable is not deleted: a file caught half-written by a script or a sync must not take its notes off the screen. The date is put back so the next poll reads it again.
                fileDates[url] = known
            }
        }
    }

    /// The notes at `key` changed on disk: each floating note showing one of them adopts its new
    /// version unless the user is mid-edit there, and goes if it was deleted there. The
    /// dashboard follows.
    private func adoptFromDisk(key: String, notes: [Note]) {
        for (_, shown) in allShown where shown.key == key {
            guard !shown.window.hasPendingEdit else { continue }
            if let note = notes.first(where: { $0.id == shown.window.noteID }) {
                DebugLog.note("disk: id=\(note.id ?? "-") changed=\(shown.window.currentNote != note)")
                shown.seen = note
                if shown.window.currentNote != note { shown.window.applyLive(note) }
            } else if Self.deletedElsewhere(seen: shown.seen) {
                DebugLog.note("disk: id=\(shown.window.noteID ?? "-") deleted elsewhere, hiding")
                shown.seen = nil
                shown.window.hide()
                forget(shown.window)
            }
        }
        showAddedOnDisk(key: key, notes: notes)
        if dashboardOpen { grid.adoptFromDisk(key: key, notes: notes) }
    }

    /// Notes that appeared at `key` from outside Tack go up on every place on screen that loads
    /// `key`, the way coming back to that place would have shown them.
    private func showAddedOnDisk(key: String, notes: [Note]) {
        for place in places.values {
            let container = place.container
            // Finest first, as loadAll assigns a note to its level.
            guard let level = stride(from: container.finestLevel, through: container.minLevel, by: -1)
                .first(where: { container.key(at: $0) == key })
            else { continue }
            // By id across the whole place: a note shown at another of its levels is not new here.
            let added = Self.unshown(notes, shown: place.notes.map(\.window.noteID))
            guard !added.isEmpty, let f = container.frame() else { continue }
            for note in added {
                DebugLog.note("disk: id=\(note.id ?? "-") added at \(key), showing")
                show(note, level: level, in: place, frame: f)
            }
            startTracking()
        }
    }

    /// The notes in `notes` no window shows yet, matched by id. Pure.
    static func unshown(_ notes: [Note], shown: [String?]) -> [Note] {
        notes.filter { !$0.isDeletion && !shown.contains($0.id) }
    }

    /// A note missing from its file was deleted by somebody else only if Tack last knew it with words in it: an empty note is never stored (`Note.isDeletion`), so one dragged before being typed in, or just emptied, is missing because Tack saved it so, and hiding it would pull it from under the caret.
    static func deletedElsewhere(seen: Note?) -> Bool { seen?.isDeletion != true }

    /// Put `note` on every view of it — the floating note and the dashboard's card — because a
    /// save kept words from the file over the ones on screen.
    private func cascade(key: String, note: Note) {
        shown(key: key, id: note.id)?.note.window.applyLive(note)
        if dashboardOpen { grid.update(key: key, note: note) }
    }

    // MARK: - Notes elsewhere in this app

    /// The focused app's other places that hold notes — other chats, tabs, folders — and how many
    /// each holds. The menu bar shows the total next to its icon, and its menu lists them.
    private var elsewhere: (app: String, places: [(key: String, count: Int)])?

    /// Read again on every change of focus, and whenever the menu opens. Finder notes are
    /// counted per folder, not per note: counting them would read every folder's file.
    private func refreshElsewhere() {
        defer { showElsewhereCount() }
        guard let container = current, let app = container.path.first else { return elsewhere = nil }
        var counts: [String: Int] = [:]
        if app == FinderContainer.bundleID {
            for folder in NotePreferences.shared.knownFolders { counts[NoteStore.key(forFolder: folder)] = 1 }
        } else {
            counts = (try? AppNotes.all())?.mapValues(\.count) ?? [:]
        }
        elsewhere = (app, Container.elsewhere(in: counts, bundleID: app, shown: container.allKeys))
    }

    private func showElsewhereCount() {
        guard let button = statusItem?.button else { return }
        let total = elsewhere?.places.reduce(0) { $0 + $1.count } ?? 0
        button.title = total > 0 ? "\(total)" : ""
        button.imagePosition = total > 0 ? .imageLeading : .imageOnly
        button.toolTip = total > 0 ? "\(total) more note\(total == 1 ? "" : "s") elsewhere in this app" : nil
    }

    private static let elsewhereTag = 7701

    func menuNeedsUpdate(_ menu: NSMenu) {
        DebugLog.note("menu: opened; front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) current=\(current?.focusKey ?? "nil")")
        refreshElsewhere()
        menu.items.filter { $0.tag == Self.elsewhereTag }.forEach(menu.removeItem)
        guard let elsewhere, !elsewhere.places.isEmpty else { return }
        let finder = elsewhere.app == FinderContainer.bundleID
        var items: [NSMenuItem] = [.separator()]
        let header = NSMenuItem(
            title: "Elsewhere in \(Container.appName(bundleID: elsewhere.app))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)
        for place in elsewhere.places.prefix(15) {
            var name = Container.placeName(for: place.key)
            if name.count > 48 { name = String(name.prefix(47)) + "…" }
            let item = NSMenuItem(
                title: finder || place.count == 1 ? name : "\(name) (\(place.count))",
                action: #selector(goElsewhere(_:)), keyEquivalent: "")
            item.representedObject = place.key
            item.target = self
            item.indentationLevel = 1
            items.append(item)
        }
        if elsewhere.places.count > 15 {
            let more = NSMenuItem(title: "More in Open Tack…", action: nil, keyEquivalent: "")
            more.isEnabled = false
            items.append(more)
        }
        for (i, item) in items.enumerated() {
            item.tag = Self.elsewhereTag
            menu.insertItem(item, at: 1 + i)  // right under "Add note here"
        }
    }

    @objc private func goElsewhere(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Container.reveal(key: key)
    }

    // MARK: - Dashboard

    /// Every note at once — what the Tack window shows. Built the first time it opens.
    private(set) lazy var grid: NoteGrid = {
        let grid = NoteGrid { [weak self] error in self?.reportPersistenceError(error) }
        grid.onLiveEdit = { [weak self] key, edited in
            // A note that isn't on screen has nothing to keep in step.
            guard let self, let hit = shown(key: key, id: edited.id) else { return }
            if edited.isDeletion {
                hit.note.window.hideDiscardingPendingSave()
                forget(hit.note.window)
            } else {
                hit.note.window.applyLive(edited)
            }
        }
        return grid
    }()

    private lazy var dashboard: DashboardWindow = {
        let dashboard = DashboardWindow(grid: grid)
        dashboard.onClose = { [weak self] in self?.refreshElsewhere() }  // notes may have gone there
        return dashboard
    }()

    /// The Tack window is up, so the grid has to keep pace with the disk and the floating notes.
    /// Never builds the window just to ask.
    private var dashboardBuilt = false
    private var dashboardOpen: Bool { dashboardBuilt && dashboard.isOpen }

    /// Bring up the Tack window on every note — or, already up, bring it forward.
    func openDashboard() {
        if !dashboardOpen { flushAll() }  // the grid is about to read disk
        dashboardBuilt = true
        dashboard.open()
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

    /// Take down every note `app` is showing. Every other app's notes are left alone.
    private func hidePlace(app: String) {
        guard let place = places.removeValue(forKey: app) else { return }
        DebugLog.note("hide: \(place.notes.count) note(s) of \(app)")
        place.notes.forEach { $0.window.hide() }
    }

    /// A note left the screen for good (deleted): stop tracking it. Its window goes back to the
    /// pool; a place left with no notes goes too.
    private func forget(_ window: NoteWindow) {
        for (app, place) in places {
            place.notes.removeAll { $0.window === window }
            if place.notes.isEmpty { places[app] = nil }
        }
    }
}
