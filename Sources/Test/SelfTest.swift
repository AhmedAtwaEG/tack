import AppKit
import Foundation

/// `swift run swift-executable --selftest` — the runnable checks for the non-trivial logic.
enum SelfTest {
    static func run() {
        noteStoreRoundTrip()
        corruptJSONIsPreserved()
        writeFailureIsReported()
        centralBackupKeepsPreviousVersion()
        appNotesRoundTrip()
        allAppNotes()
        noteKeyLabels()
        stableKeyMigration()
        coordFlip()
        fitToWindow()
        clampToWindow()
        containResize()
        centerNewNote()
        colorHexRoundTrip()
        containerKeys()
        containerLoadFallback()
        containerPromotion()
        containerMovePreservesSourceOnFailure()
        containerMoveNeverOverwrites()
        noteListFormat()
        noteListApplying()
        multipleNotesInAFolder()
        multipleAppNotesAtOneKey()
        olderNotesGetDistinctIDs()
        cascadeNewNotes()
        finderContainerRoundTrip()
        finderReplyParsing()
        appleScriptsCompile()
        windowPicking()
        rearrangingIsDetected()
        genericKeyMatchesLegacyFormat()
        levelLabels()
        debouncerCollapses()
        trackingBacksOff()
        markdownSpans()
        markdownParse()
        markdownListEditing()
        inlineToggleKeepsListMarkers()
        markdownRoundTrip()
        markdownInlineClosing()
        blockStyleAtCaret()
        blockNavigation()
        backspaceAtTheEnd()
        noteSizeIsOptional()
        collapsedNote()
        collapsedTitle()
        urlNormalization()
        dashboardBackdrop()
        mergeKeepsNewerFile()
        emptyNoteSurvivesItsOwnSave()
        treePathIsRemembered()
        notePreferencesPalette()
        fontFaces()
        pillGeometry()
        dotGlyphsAreCentred()
        placeNames()
        notesElsewhere()
        newNotesRememberTheApp()
        dashboardGroups()
        dashboardSearch()
        dashboardPlacement()
        notesAddedOnDisk()
        print("✅ all self-tests passed")
    }

    static func allAppNotes() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")

        assert(try! AppNotes.all(from: url).isEmpty, "no file yet is an empty list, not an error")
        let a = Note(text: "a", dx: 1, dy: 2, id: "a")
        try! AppNotes.save(key: "com.apple.Preview|Report.pdf", note: a, to: url)
        try! AppNotes.save(key: "com.apple.Terminal|/dev/ttys003", note: Note(text: "b", dx: 3, dy: 4, id: "b"), to: url)
        let all = try! AppNotes.all(from: url)
        assert(all.keys.sorted() == ["com.apple.Preview|Report.pdf", "com.apple.Terminal|/dev/ttys003"],
            "every stored key is listed")
        assert(all["com.apple.Preview|Report.pdf"] == [a], "notes come back whole")

        try! AppNotes.save(key: "com.apple.Preview|Report.pdf", note: Note(text: "", dx: 1, dy: 2, id: "a"), to: url)
        assert(try! AppNotes.all(from: url).keys.sorted() == ["com.apple.Terminal|/dev/ttys003"],
            "a place whose last note is deleted leaves the list")

        // The Finder half: a real folder with a note, and one that has gone since it was indexed.
        let folder = dir.appendingPathComponent("Documents")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! NoteStore.save(folder: folder.path, note: Note(text: "finder", dx: 5, dy: 6, id: "f"))
        defer { NotePreferences.shared.forgetFolder(folder.path) }  // save() indexes the real domain
        let merged = StoredNote.list(
            appNotes: try! AppNotes.all(from: url),
            folders: [folder.path, dir.appendingPathComponent("gone").path])
        assert(merged.map(\.key) == [
            Container.key(path: [FinderContainer.bundleID, folder.path], level: 1),
            "com.apple.Terminal|/dev/ttys003",
        ], "both stores merge, sorted case-insensitively, and an unreachable folder drops out")
        assert(merged[0].folder == folder.path, "a Finder note knows the folder to write back to")
        assert(merged[1].folder == nil, "an app note has no folder")
        assert(merged[0].note.text == "finder" && merged[1].note.text == "b", "notes survive the merge")

        try! merged[0].save(Note(text: "", dx: 5, dy: 6, id: "f"))
        assert(try! NoteStore.load(folder: folder.path).isEmpty, "a StoredNote deletes through its own store")

        // Several notes at one key: listed one by one, in the order they were added.
        let many = StoredNote.list(
            appNotes: ["k": ["3", "1", "2"].map { Note(text: $0, dx: 0, dy: 0, id: $0) }], folders: [])
        assert(many.map(\.note.text) == ["3", "1", "2"], "a place's notes keep their order: \(many.map(\.note.text))")
        assert(Set(many.map(\.key)) == ["k"], "and all keep the place's key")
    }

    static func noteKeyLabels() {
        // Finder is the one app guaranteed installed, so it's the only name worth asserting.
        assert(Container.appName(bundleID: FinderContainer.bundleID) == "Finder", "installed apps get their name")
        let ghost = "com.example.not-installed"
        assert(Container.appName(bundleID: ghost) == ghost, "an uninstalled app falls back to its bundle ID")
        assert(Container.label(for: ghost + "|Draft") == ghost + " — Draft", "a window title reads as-is")
        assert(Container.label(for: FinderContainer.bundleID + "|/Users/me/Projects") == "Finder — Projects",
            "a folder reads as its own name")
        assert(Container.label(for: "com.apple.Terminal|/dev/ttys003") == "Terminal — ttys003",
            "a tty reads as the tab it is")
        assert(Container.label(for: ghost + "|https://example.com/page") == ghost + " — example.com/page",
            "a URL drops its scheme")
        assert(Container.label(for: ghost + "|https://example.com/") == ghost + " — example.com",
            "a bare host drops its trailing slash")
        assert(Container.label(for: ghost) == ghost, "an app-level key is just the app")

        assert(Container.scopeName(for: ghost) == "App", "one component is the whole app")
        assert(Container.scopeName(for: FinderContainer.bundleID + "|/Users/me") == "Folder", "Finder pins to folders")
        assert(Container.scopeName(for: "com.google.Chrome|https://example.com") == "Tab", "browsers pin to tabs")
        assert(Container.scopeName(for: "com.apple.Terminal|/dev/ttys003") == "Tab", "terminals pin to tabs")
        assert(Container.scopeName(for: ghost + "|Draft") == "Window", "everything else pins to windows")

        assert(Container.revealTarget(for: FinderContainer.bundleID + "|/Users/me") == .folder("/Users/me"),
            "a Finder note opens its folder")
        assert(Container.revealTarget(for: "com.google.Chrome|title|https://example.com/page")
            == .url(URL(string: "https://example.com/page")!), "a tab note opens its page")
        assert(Container.revealTarget(for: "com.apple.Terminal|/dev/ttys003") == .app,
            "a tty is a path, not a page — Terminal just comes forward")
        assert(Container.revealTarget(for: ghost + "|Draft") == .window("Draft"), "a window note raises that window")
        assert(Container.revealTarget(for: ghost + "|") == .app, "a window with no name: just the app")
        assert(Container.revealTarget(for: ghost) == .app, "an app note raises its app")
    }

    static func appNotesRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")
        let key = "selftest|" + UUID().uuidString  // unique: never clobbers a real note
        let n = Note(text: "hello", dx: 12, dy: 34, id: "n")
        try! AppNotes.save(key: key, note: n, to: url)
        let loaded = try! AppNotes.load(key: key, from: url)
        assert(loaded == [n], "app note round-trip mismatch")

        try! AppNotes.save(key: key, note: Note(text: "", dx: 12, dy: 34, id: "n"), to: url)
        let deleted = try! AppNotes.load(key: key, from: url)
        assert(deleted.isEmpty, "empty text should delete the app note")
    }

    static func stableKeyMigration() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")
        let id = UUID().uuidString
        let legacy = "selftest|old-title|\(id)"
        let stable = "selftest|\(id)"
        // Written the way an older Tack did: one bare note, no id.
        try! Data(#"{"\#(legacy)":{"text":"migrate me","dx":12,"dy":34}}"#.utf8).write(to: url)

        let migrated = try! AppNotes.load(key: stable, migrating: legacy, from: url)
        let stableNotes = try! AppNotes.load(key: stable, from: url)
        let legacyNotes = try! AppNotes.load(key: legacy, from: url)
        assert(migrated.map(\.text) == ["migrate me"], "legacy note should migrate: \(migrated)")
        assert(stableNotes == migrated, "migrated note should use the stable key, under the same id")
        assert(legacyNotes.isEmpty, "legacy title-dependent key should be removed")
        assert(migrated[0].id == "legacy|\(legacy)|0", "an older note's id comes from where it was read")

        // A place with two notes migrates whole, in one go.
        let legacy2 = "selftest|older|\(id)", stable2 = "selftest|2|\(id)"
        for t in ["x", "y"] { try! AppNotes.save(key: legacy2, note: Note(text: t, dx: 0, dy: 0, id: t), to: url) }
        let both = try! AppNotes.load(key: stable2, migrating: legacy2, from: url)
        assert(both.map(\.id) == ["x", "y"], "every note at the legacy key moves: \(both)")
        assert(try! AppNotes.load(key: legacy2, from: url).isEmpty, "and none stay behind")
        assert(try! AppNotes.load(key: stable, from: url) == stableNotes, "other keys are untouched")
    }

    static func notePreferencesPalette() {
        let suite = "selftest." + UUID().uuidString  // isolated: never touches the real palette
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = NotePreferences(defaults: defaults)

        let base = prefs.palette
        prefs.addColor("123456")
        assert(prefs.palette == base + ["123456"], "addColor should append")
        prefs.addColor("123456")
        assert(prefs.palette == base + ["123456"], "addColor should dedupe")
        prefs.removeColor("123456")
        assert(prefs.palette == base, "removeColor should drop the colour")

        // Never empty the palette: removing the last colour is a no-op.
        var only = prefs.palette
        while only.count > 1 { prefs.removeColor(only[0]); only = prefs.palette }
        let last = only[0]
        prefs.removeColor(last)
        assert(prefs.palette == [last], "palette must keep at least one colour")
    }

    static func centerNewNote() {
        let c = Coord.center(note: CGSize(width: 220, height: 170), window: CGSize(width: 500, height: 400))
        assert(c.dx == 140 && c.dy == 115, "a new note should start centred")
        // A window smaller than the note: it fills it, so there is nothing left to centre.
        let tight = Coord.center(note: CGSize(width: 220, height: 170), window: CGSize(width: 100, height: 100))
        assert(tight.dx == 0 && tight.dy == 0, "a note capped by the window sits at its top-left")
    }

    static func containResize() {
        let window = CGSize(width: 500, height: 400)
        // Right edge pushed past the border: cut there, left edge (dx) stays put.
        let right = Coord.contain(dx: 100, dy: 10, note: CGSize(width: 480, height: 50), window: window)
        assert(right.dx == 100 && right.size.width == 400, "right edge should stop at the border")
        // Top edge pushed above it: cut there, the bottom edge keeps its place (dy + height).
        let top = Coord.contain(dx: 10, dy: -30, note: CGSize(width: 50, height: 120), window: window)
        assert(top.dy == 0 && top.size.height == 90, "top edge should stop at the border")
        // Inside the window: untouched.
        let inside = Coord.contain(dx: 10, dy: 10, note: CGSize(width: 50, height: 60), window: window)
        assert(
            inside.dx == 10 && inside.dy == 10 && inside.size == CGSize(width: 50, height: 60),
            "a resize that fits should be left alone")
    }

    static func colorHexRoundTrip() {
        assert(
            Swatch.hex(from: Swatch.color(fromHex: "FFEB73")) == "FFEB73", "hex round-trip failed")
        assert(
            Swatch.hex(from: Swatch.color(fromHex: "bad")) == Swatch.defaultHex,
            "bad hex should fall back to default")
    }

    static func noteStoreRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.path

        let n = Note(text: "hello", dx: 12, dy: 34, id: "n")
        try! NoteStore.save(folder: folder, note: n)
        let loaded = try! NoteStore.load(folder: folder)
        assert(loaded == [n], "round-trip mismatch")

        try! NoteStore.save(folder: folder, note: Note(text: "", dx: 12, dy: 34, id: "n"))
        let deleted = try! NoteStore.load(folder: folder)
        assert(deleted.isEmpty, "empty text should delete the note")
        assert(
            !FileManager.default.fileExists(atPath: NoteStore.fileURL(forFolder: folder).path),
            "file should be gone")
    }

    static func corruptJSONIsPreserved() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = NoteStore.fileURL(forFolder: dir.path)
        let corrupt = Data("{recover me".utf8)
        try! corrupt.write(to: url)

        do {
            _ = try NoteStore.load(folder: dir.path)
            assert(false, "invalid JSON must not look like a missing note")
        } catch NotePersistenceError.invalidJSON(_, let recovery, _) {
            assert(recovery != nil, "invalid JSON should get a recovery copy")
            assert((try? Data(contentsOf: recovery!)) == corrupt, "recovery copy changed the data")
        } catch {
            assert(false, "unexpected persistence error: \(error)")
        }

        do {
            try NoteStore.save(folder: dir.path, note: Note(text: "new", dx: 1, dy: 2))
            assert(false, "saving must not overwrite invalid JSON")
        } catch {}
        assert((try? Data(contentsOf: url)) == corrupt, "invalid original must remain untouched")
    }

    static func centralBackupKeepsPreviousVersion() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")
        let old = Note(text: "first", dx: 1, dy: 2, id: "o")
        let new = Note(text: "second", dx: 3, dy: 4, id: "n")

        try! AppNotes.save(key: "old", note: old, to: url)
        try! AppNotes.save(key: "new", note: new, to: url)
        let current = try! AppNotes.load(key: "new", from: url)
        let backup = try! AppNotes.load(key: "old", from: url.appendingPathExtension("backup"))
        assert(current == [new], "the current file should contain the new value")
        assert(backup == [old], "the backup should preserve the previous complete value")
    }

    static func writeFailureIsReported() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("missing")
        do {
            try NoteStore.save(folder: missing.path, note: Note(text: "nope", dx: 1, dy: 2))
            assert(false, "an unwritable destination must throw")
        } catch NotePersistenceError.write(let url, _) {
            assert(url == NoteStore.fileURL(forFolder: missing.path), "error should name the file")
        } catch {
            assert(false, "unexpected persistence error: \(error)")
        }
    }

    static func fitToWindow() {
        let note = CGSize(width: 220, height: 170)

        // Window bigger than the note -> shown at its desired size.
        var f = Coord.fit(desired: note, window: CGSize(width: 800, height: 600))
        assert(f == note, "a big window should not shrink the note: \(f)")

        // Window narrower and shorter than the note -> capped to the window, per axis.
        f = Coord.fit(desired: note, window: CGSize(width: 100, height: 90))
        assert(f == CGSize(width: 100, height: 90), "note must never exceed the window: \(f)")

        // Only one axis too small -> only that axis is capped.
        f = Coord.fit(desired: note, window: CGSize(width: 100, height: 600))
        assert(f == CGSize(width: 100, height: 170), "only the tight axis should cap: \(f)")
    }

    static func clampToWindow() {
        let note = CGSize(width: 220, height: 170)
        let win = CGSize(width: 800, height: 600)

        // already inside -> untouched
        var c = Coord.clamp(dx: 100, dy: 50, note: note, window: win)
        assert(c.dx == 100 && c.dy == 50, "inside should not move: \(c)")

        // past the right/bottom edge -> pulled back so the note's far edge sits on the border
        c = Coord.clamp(dx: 999, dy: 999, note: note, window: win)
        assert(c.dx == 580 && c.dy == 430, "should clamp to bottom-right: \(c)")

        // past the left/top edge -> pinned to the corner
        c = Coord.clamp(dx: -50, dy: -50, note: note, window: win)
        assert(c.dx == 0 && c.dy == 0, "should clamp to top-left: \(c)")

        // window smaller than the note -> corner, never a negative offset
        c = Coord.clamp(dx: 30, dy: 30, note: note, window: CGSize(width: 100, height: 100))
        assert(c.dx == 0 && c.dy == 0, "tiny window should pin to corner: \(c)")
    }

    static func debouncerCollapses() {
        let d = Debouncer(delay: 0.05)
        var hits: [Int] = []
        d.call { hits.append(1); return true }
        d.call { hits.append(2); return true }  // must cancel the first
        // Spinning the main run loop drains the main dispatch queue in a CLI process.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        assert(hits == [2], "only the last scheduled block should fire: \(hits)")

        d.call { hits.append(3); return true }
        d.flush()
        assert(hits == [2, 3], "flush should run the pending block immediately: \(hits)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        assert(hits == [2, 3], "a flushed block must not run again: \(hits)")

        d.call { hits.append(4); return true }
        d.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        assert(hits == [2, 3], "cancel should drop the pending block: \(hits)")

        var attempts = 0
        d.call {
            attempts += 1
            return attempts > 1
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        assert(attempts == 1, "the scheduled save should have failed once")
        assert(d.flush() && attempts == 2, "flush should retry retained failed work")
    }

    static func coordFlip() {
        // primary height 1000, window top-left (100,50), offset (20,40) -> note TL (120,90) -> Cocoa y 910
        let p = Coord.cocoaTopLeft(
            finderLeft: 100, finderTop: 50, dx: 20, dy: 40, primaryHeight: 1000)
        assert(p.x == 120 && p.y == 910, "coord flip wrong: \(p)")

        // The round trip: offsets() must be cocoaTopLeft()'s exact inverse, or a drag would
        // shift the note by the drift every time the delegate recomputes dx/dy.
        // cocoaTopLeft returns the note's top-left in Cocoa coords, which is the frame's maxY.
        let back = Coord.offsets(
            noteMinX: Double(p.x), noteCocoaMaxY: Double(p.y),
            finderLeft: 100, finderTop: 50, primaryHeight: 1000)
        assert(back.dx == 20 && back.dy == 40, "flip round trip drifted: \(back)")
    }
}

/// A Container with in-memory storage, so the lookup and promotion logic can be tested
/// without an app, a window, or an Accessibility grant. This is the payoff of the class
/// over the old enum.
private enum FakeWriteError: Error { case blocked }

final class FakeContainer: Container {
    private var storage: [String: [Note]] = [:]
    private let ident: [String]
    private let stableFinestKey: String?
    var failingLevel: Int?
    var writes: [Int] = []

    init(path: [String], finestKey: String? = nil) {
        self.ident = path
        self.stableFinestKey = finestKey
    }

    override var path: [String] { ident }
    override var finestKey: String? { stableFinestKey }
    override func notes(at level: Int) throws -> [Note] { storage[key(at: level)] ?? [] }
    override func write(_ note: Note, at level: Int) throws {
        writes.append(level)
        if failingLevel == level { throw FakeWriteError.blocked }
        let notes = NoteList.applying(note, to: storage[key(at: level)] ?? [])
        storage[key(at: level)] = notes.isEmpty ? nil : notes
    }
}

extension SelfTest {
    static func containerKeys() {
        let p = ["com.foo.Bar", "doc.txt"]
        assert(Container.key(path: p, level: 0) == "com.foo.Bar", "app level should be the bundle ID")

        // The no-migration guarantee: identical to the `bundle + "|" + ident` key the app wrote
        // before Container existed. If this fails, every existing app note is orphaned.
        assert(Container.key(path: p, level: 1) == "com.foo.Bar|doc.txt", "key format changed")

        assert(Container.key(path: ["a", "b", "c"], level: 1) == "a|b", "should join a prefix only")
        assert(Container.key(path: ["a", "b", "c"], level: 2) == "a|b|c", "finest should join all")

        let stable = FakeContainer(path: ["app", "old title", "tab-id"], finestKey: "app|tab-id")
        assert(stable.key(at: 0) == "app", "stable tab key must not change coarser levels")
        assert(stable.key(at: 1) == "app|old title", "window level should retain its own identity")
        assert(stable.key(at: 2) == "app|tab-id", "tab key must exclude the mutable title")
        assert(stable.focusKey == "app|tab-id", "focus identity should use the stable tab key")
        let renamed = FakeContainer(path: ["app", "new title", "tab-id"], finestKey: "app|tab-id")
        assert(renamed.focusKey == stable.focusKey, "a title change must not change tab identity")
    }

    static func containerLoadFallback() {
        let c = FakeContainer(path: ["app", "win", "tab"])
        let n = Note(text: "hi", dx: 1, dy: 2, id: "w")

        assert(try! c.loadAll().isEmpty, "no note anywhere should not resolve")

        try! c.write(n, at: 1)  // a window-level note
        let window = try! c.loadAll()
        assert(window.count == 1 && window[0].note == n && window[0].level == 1,
            "a window note should be visible from the tab: \(window)")

        // Every level's notes show together now — the tab's first, then the window's, the app's.
        try! c.write(Note(text: "tab", dx: 3, dy: 4, id: "t"), at: 2)
        try! c.write(Note(text: "app", dx: 5, dy: 6, id: "a"), at: 0)
        try! c.write(Note(text: "tab2", dx: 7, dy: 8, id: "t2"), at: 2)
        let all = try! c.loadAll()
        assert(all.map(\.note.id) == ["t", "t2", "w", "a"] && all.map(\.level) == [2, 2, 1, 0],
            "every note on the surface, finest level first: \(all.map { ($0.note.id ?? "-", $0.level) })")
        assert(try! c.find(id: "w")?.level == 1, "find locates a note's level by id")
        assert(try! c.find(id: "nope") == nil, "an unknown id finds nothing")
    }

    static func containerPromotion() {
        let c = FakeContainer(path: ["app", "win", "tab"])
        let n = Note(text: "hi", dx: 1, dy: 2, id: "n")
        let neighbour = Note(text: "stays", dx: 3, dy: 4, id: "s")
        try! c.write(n, at: 2)
        try! c.write(neighbour, at: 2)

        let moved = try! c.move(n, from: 2, to: 1)
        assert(moved == n, "a move to a free level keeps the note exactly, id included")
        assert(try! c.notes(at: 2) == [neighbour], "only the moved note leaves the tab")
        assert(try! c.notes(at: 1) == [n], "the note should live at the window level now")
        assert(try! c.find(id: "n")?.level == 1, "and lookup should find it there")
        assert(try! c.move(n, from: 1, to: 1) == n && (try! c.notes(at: 1)) == [n], "a move to its own level is a no-op")
        assert(c.pinLevels == [0, 1, 2], "a plain surface offers every level")
        let tabbed = FakeContainer(path: ["app", "title", "url"], finestKey: "app|url")
        assert(tabbed.pinLevels == [0, 2], "a title-keyed window is not a place to pin")
    }

    static func containerMovePreservesSourceOnFailure() {
        let c = FakeContainer(path: ["app", "win", "tab"])
        let n = Note(text: "safe", dx: 1, dy: 2, id: "n")
        try! c.write(n, at: 2)
        c.writes = []
        c.failingLevel = 1

        do {
            try c.move(n, from: 2, to: 1)
            assert(false, "a failed destination write must throw")
        } catch {}
        assert(c.writes == [1], "destination must be attempted before source deletion")
        assert(try! c.notes(at: 2) == [n], "a failed destination write must preserve the source")

        c.writes = []
        c.failingLevel = 2
        do {
            try c.move(n, from: 2, to: 1)
            assert(false, "a failed source deletion must throw")
        } catch {}
        assert(c.writes == [1, 2], "move must write destination, then delete source")
        assert(try! c.notes(at: 2) == [n] && (try! c.notes(at: 1)) == [n], "failure may duplicate, never lose the note")
        let shown = try! c.loadAll()
        assert(shown.count == 1 && shown[0].level == 2, "a duplicate shows once, at the level it was moving from")
    }

    static func containerMoveNeverOverwrites() {
        // Two different notes that ended up sharing an id at two levels (ids are per place, and
        // hand-edited or older files can collide): moving one onto the other must not replace it.
        let c = FakeContainer(path: ["app", "win", "tab"])
        let mover = Note(text: "mover", dx: 1, dy: 2, id: "x")
        let resident = Note(text: "resident", dx: 3, dy: 4, id: "x")
        try! c.write(mover, at: 2)
        try! c.write(resident, at: 1)

        let moved = try! c.move(mover, from: 2, to: 1)
        assert(moved.id != "x" && moved.text == "mover", "a taken id is replaced by a fresh one")
        assert(try! c.notes(at: 1).map(\.text) == ["resident", "mover"], "the resident note survives")
        assert(try! c.notes(at: 2).isEmpty, "and the mover left its old level")
    }

    static func finderContainerRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let c = FinderContainer(folder: dir.path)
        assert(c.path == ["com.apple.finder", dir.path], "finder path wrong: \(c.path)")

        // A folder note can't be promoted: it lives in a .tack.json *inside* the folder,
        // so level 0 ("all of Finder") would have no file to live in.
        assert(c.minLevel == 1, "Finder should not offer promotion")
        assert(c.finestLevel == 1, "finder path should be two components")

        let n = Note(text: "hi", dx: 1, dy: 2, id: "n")
        try! c.write(n, at: 1)
        let hits = try! c.loadAll()
        assert(hits.count == 1 && hits[0].note == n && hits[0].level == 1, "finder round-trip mismatch: \(hits)")

        try! c.write(Note(text: "", dx: 1, dy: 2, id: "n"), at: 1)
        assert(try! c.loadAll().isEmpty, "empty text should delete the folder note")
        NotePreferences.shared.forgetFolder(dir.path)
    }

    static func genericKeyMatchesLegacyFormat() {
        // Belt and braces alongside containerKeys(): the generic container's finest key must
        // be exactly what AXWindows.focused built before Container existed.
        let legacy = "com.foo.Bar" + "|" + "Untitled 1"
        assert(
            Container.key(path: ["com.foo.Bar", "Untitled 1"], level: 1) == legacy,
            "generic key drifted from the legacy format — existing notes would orphan")
    }

    static func levelLabels() {
        // 3-part path (a browser tab): app / window / tab
        assert(LevelName.label(level: 0, of: 3) == "Pin to this app", "level 0 is always the app")
        // The pill's picker wears one symbol per level: distinct, and real on this macOS.
        let symbols = (0...2).map { LevelName.symbol(level: $0, of: 3) }
        assert(Set(symbols).count == 3, "app, window and tab need three different symbols")
        assert(LevelName.symbol(level: 1, of: 2) == symbols[1], "a 2-part path ends at a window")
        for name in symbols + ["rectangle.stack.fill", "arrow.up.forward.app.fill", "arrow.down.right.and.arrow.up.left", "gearshape.fill"] {
            let found = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            assert(found, "\(name) is not an SF Symbol here — its dot would be blank")
        }
        assert(LevelName.label(level: 1, of: 3) == "Pin to this window", "middle is the window")
        assert(LevelName.label(level: 2, of: 3) == "Pin to this tab", "deepest of 3 is the tab")

        // 2-part path (a plain app window, or Preview where AXDocument already names the tab):
        // the deepest level is the window itself, not a tab.
        assert(LevelName.label(level: 0, of: 2) == "Pin to this app", "level 0 is always the app")
        assert(LevelName.label(level: 1, of: 2) == "Pin to this window", "deepest of 2 is a window")
    }

    static func markdownSpans() {
        func styles(_ s: String) -> [Markdown.Style] { Markdown.spans(in: s).map(\.style) }

        // Content excludes the markers, and both marker runs are reported so they can be dimmed.
        let b = Markdown.spans(in: "a **milk** b")
        assert(b.count == 1 && b[0].style == .inline(.bold), "one bold span expected: \(b)")
        assert(b[0].content == NSRange(location: 4, length: 4), "content should be 'milk': \(b[0])")
        assert(
            b[0].markers == [NSRange(location: 2, length: 2), NSRange(location: 8, length: 2)],
            "markers should be the two '**': \(b[0])")

        // The lookaround guard: the inner '*' of '**' must not read as italic.
        assert(
            styles("**bold**") == [.inline(.bold)],
            "italic fired inside bold: \(styles("**bold**"))")
        assert(styles("*it*") == [.inline(.italic)], "italic")
        assert(styles("_it_") == [.inline(.italic)], "underscore italic")
        assert(styles("snake_case_here").isEmpty, "underscores inside a word are not italic")

        // First claim wins, and code claims first.
        assert(
            styles("`**x**`") == [.inline(.code)],
            "code should claim its span: \(styles("`**x**`"))")

        let h = Markdown.spans(in: "## Shopping")
        assert(h.count == 1 && h[0].style == .heading(2), "should be an h2: \(h)")
        assert(
            h[0].content == NSRange(location: 3, length: 8), "content should be 'Shopping': \(h[0])")
        assert(styles("# a") == [.heading(1)] && styles("### a") == [.heading(3)], "levels 1 and 3")
        assert(styles("#### a").isEmpty, "four hashes is not a heading we style")

        // A todo line must never also read as a bullet.
        assert(styles("- [ ] pay rent") == [.todo(done: false)], "unticked: \(styles("- [ ] pay rent"))")
        assert(styles("- [x] pay rent") == [.todo(done: true)], "ticked")
        assert(styles("- [X] pay rent") == [.todo(done: true)], "uppercase X ticks too")
        assert(styles("- milk") == [.bullet], "plain bullet")

        assert(styles("~~gone~~") == [.inline(.strike)], "strike")
        assert(styles("just text").isEmpty, "plain text has no spans — the no-migration case")
        assert(styles("**foo").isEmpty, "unterminated bold is not a span")

        // Line rules are reported before inline ones, so styling composes rather than flattens.
        assert(
            styles("- **milk** 2L") == [.bullet, .inline(.bold)],
            "bullet then bold: \(styles("- **milk** 2L"))")
        assert(styles("# Shopping\n- milk") == [.heading(1), .bullet], "line rules match per line")
    }

    static func markdownInlineClosing() {
        // The autoformat trigger: a pattern is consumed only when its closing marker is under the
        // caret, so typing the final delimiter is what fires it.
        let b = Markdown.inlineClosingAt(8, in: "**bold**")
        assert(b?.style == .bold && b?.range == NSRange(location: 0, length: 8), "bold closes at 8")
        assert(Markdown.inlineClosingAt(5, in: "**bold**") == nil, "no completion mid-span")

        let c = Markdown.inlineClosingAt(3, in: "`x`")
        assert(c?.style == .code && c?.range == NSRange(location: 0, length: 3), "code closes at 3")

        assert(Markdown.inlineClosingAt(3, in: "*i* z")?.style == .italic, "italic closes at its '*'")
        assert(Markdown.inlineClosingAt(5, in: "*i* z") == nil, "caret past the span doesn't fire")
    }

    static func markdownParse() {
        func font(_ a: NSAttributedString, _ i: Int) -> NSFont? {
            a.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        }
        func isBold(_ f: NSFont?) -> Bool {
            f.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        }

        // Inline markers are consumed into an attribute; the asterisks are gone from the string.
        let bold = MarkdownDocument.parse("**milk**")
        assert(bold.string == "milk", "the ** should be gone: \(bold.string.debugDescription)")
        assert(
            (bold.attribute(.tackInline, at: 0, effectiveRange: nil) as? String) == "bold"
                && isBold(font(bold, 0)), "content should be marked and rendered bold")

        // '#' is consumed too; the line carries a heading level and heading font.
        let h = MarkdownDocument.parse("# Title")
        assert(h.string == "Title", "the '# ' should be gone: \(h.string.debugDescription)")
        assert((h.attribute(.tackHeading, at: 0, effectiveRange: nil) as? Int) == 1, "h1 level")
        assert(font(h, 0)?.pointSize == 18, "h1 should be 18pt")

        // Heading + bold compose: bold inside a heading stays heading-sized.
        let hb = MarkdownDocument.parse("# **Big**")
        assert(hb.string == "Big", "both markers gone: \(hb.string.debugDescription)")
        assert(font(hb, 0)?.pointSize == 18 && isBold(font(hb, 0)), "heading-sized and bold")

        // List syntax becomes a semantic image attachment plus a space, so content starts at 2.
        let bullet = MarkdownDocument.parse("- milk")
        assert(bullet.string == "\u{FFFC} milk", "bullet should become an attachment")
        assert(ListGlyph.at(bullet, 0) == .bullet, "bullet attachment should retain its meaning")

        let open = MarkdownDocument.parse("- [ ] task")
        assert(open.string == "\u{FFFC} task", "open todo should become an attachment")
        assert(ListGlyph.at(open, 0) == .todoOpen, "open todo attachment should retain its meaning")
        assert(open.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) == nil, "open todo not struck")

        let done = MarkdownDocument.parse("- [x] done")
        assert(done.string == "\u{FFFC} done", "done todo should become an attachment")
        assert(ListGlyph.at(done, 0) == .todoDone, "done todo attachment should retain its meaning")
        assert(
            done.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) != nil,
            "a done todo strikes its content")
        let attachment = done.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        assert(attachment?.image?.size == NSSize(width: 14, height: 14), "marker image should be crisp at 14pt")
    }

    static func markdownListEditing() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.string = "- "
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        assert(MarkdownInput.listRule(tv), "typing '- ' should create a bullet")
        guard let ts = tv.textStorage else {
            assert(false, "text view needs storage")
            return
        }
        assert(ListGlyph.at(ts, 0) == .bullet, "live bullet should be an attachment")

        ts.append(NSAttributedString(string: "milk", attributes: MarkdownStyle.base))
        tv.setSelectedRange(NSRange(location: ts.length, length: 0))
        assert(
            MarkdownInput.handle(#selector(NSStandardKeyBindingResponding.insertNewline(_:)), tv),
            "Enter should continue a bullet list")
        assert(ListGlyph.at(ts, 7) == .bullet, "continued list should use a bullet attachment")
        assert(MarkdownDocument.serialize(ts) == "- milk\n- ", "live bullet list should serialize")
    }

    /// ⌘B over a list used to replace every attribute in the selection, list markers included.
    static func inlineToggleKeepsListMarkers() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let source = "# t\n- a\n- [x] b"
        tv.textStorage?.setAttributedString(MarkdownDocument.parse(source))
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        MarkdownInput.toggle(.bold, tv)
        let bold = tv.textStorage.map(MarkdownDocument.serialize)
        assert(bold == "# **t**\n- **a**\n- [x] **b**", "bold must keep headings and markers: \(bold ?? "")")
        MarkdownInput.toggle(.bold, tv)
        let plain = tv.textStorage.map(MarkdownDocument.serialize)
        assert(plain == source, "toggling back must restore the note: \(plain ?? "")")

        // Un-heading a line keeps the bold inside it.
        tv.textStorage?.setAttributedString(MarkdownDocument.parse("# a **b**"))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        _ = MarkdownInput.handle(#selector(NSStandardKeyBindingResponding.deleteBackward(_:)), tv)
        let body = tv.textStorage.map(MarkdownDocument.serialize)
        assert(body == "a **b**", "backspace at a heading's start must keep inline styles: \(body ?? "")")
    }

    /// Saving an empty note removes it from the file; the disk sync must not read that as a deletion from outside and take the note off the screen.
    static func emptyNoteSurvivesItsOwnSave() {
        let fresh = Note(text: "", dx: 10, dy: 10)
        assert(!AppDelegate.deletedElsewhere(seen: fresh), "a new, still empty note stays up")
        let written = Note(text: "words", dx: 10, dy: 10)
        assert(AppDelegate.deletedElsewhere(seen: written), "a note with words that left the file goes")
        assert(AppDelegate.deletedElsewhere(seen: nil), "nothing known about it: the file decides")
    }

    static func trackingBacksOff() {
        assert((0..<30).allSatisfy(AppDelegate.samples), "a window that just moved is read every frame")
        let idle = (30..<90).filter(AppDelegate.samples).count
        assert(idle == 10, "a still window is read one frame in six: \(idle)")
    }

    /// The browser lookup: a search records the way to its hit, and that way is reusable.
    static func treePathIsRemembered() {
        // Each node is its own list of children; the leaf "web" is the target.
        indirect enum Tree { case node(String, [Tree]) }
        let kids: (Tree) -> [Tree] = { if case .node(_, let k) = $0 { return k } else { return [] } }
        let isWeb: (Tree) -> Bool = { if case .node("web", _) = $0 { return true } else { return false } }
        let tree = Tree.node("win", [
            .node("toolbar", [.node("button", [])]),
            .node("group", [.node("tabs", []), .node("web", [])]),
        ])
        var path: [Int] = []
        let hit = AXWindows.find(from: tree, path: &path, children: kids, match: isWeb)
        assert(hit != nil && path == [1, 1], "the search should record the way to its hit: \(path)")
        assert(
            AXWindows.follow(path, from: tree, children: kids, match: isWeb) != nil,
            "a remembered path should lead back to the web area")
        assert(
            AXWindows.follow([0, 0], from: tree, children: kids, match: isWeb) == nil,
            "a path that lands on something else is a miss")
        assert(
            AXWindows.follow([1, 5], from: tree, children: kids, match: isWeb) == nil,
            "a path past the end of a level is a miss, not a crash")
    }

    /// A note keeps following its own window once its app is in the background, and hides
    /// under whatever other app's window covers it.
    static func windowPicking() {
        func win(
            _ pid: Int, _ number: Int, x: CGFloat, layer: Int = 0, w: CGFloat = 200, h: CGFloat = 200
        ) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number,
                kCGWindowLayer as String: layer,
                kCGWindowBounds as String: CGRect(x: x, y: 0, width: w, height: h)
                    .dictionaryRepresentation,
            ]
        }
        // front to back: a floating note, another app, our app's sheet, our app's document
        let screen = [win(9, 1, x: 0, layer: 3), win(2, 20, x: 300), win(1, 11, x: 600), win(1, 10, x: 900)]

        let front = WindowServer.pick(from: screen, pid: 1, number: nil)
        assert(front?.number == 11, "no number means the app's frontmost window")
        let doc = WindowServer.pick(from: screen, pid: 1, number: 10)
        assert(doc?.frame.bounds.minX == 900, "a number follows that window, not the frontmost")
        assert(
            doc?.frame.covering == [CGRect(x: 300, y: 0, width: 200, height: 200)],
            "only other apps' normal windows cover it: \(String(describing: doc?.frame.covering))")

        // A full-screen app's title bar is a thin layer-0 window of its own, above its content.
        let fullScreen = [win(1, 12, x: 0, w: 1440, h: 32), win(2, 21, x: 0, w: 1440, h: 6), win(1, 10, x: 0, w: 1440, h: 900)]
        let content = WindowServer.pick(from: fullScreen, pid: 1, number: nil)
        assert(content?.number == 10, "a strip no note fits in is never the window a note follows")
        assert(content?.frame.covering == [], "nor does another app's strip hide the note")
        assert(WindowServer.pick(from: screen, pid: 1, number: 99) == nil, "a window that left the screen is no window")
    }

    /// Window lists recorded on a 1440×900 screen: at rest, in the middle of a swipe to the next desktop, and with Mission Control open.
    static func rearrangingIsDetected() {
        func dock(x: CGFloat, y: CGFloat = 0, w: CGFloat = 1440, h: CGFloat = 900, layer: Int = -2_147_483_624) -> [String: Any] {
            [
                kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: layer,
                kCGWindowBounds as String: CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation,
            ]
        }
        let app: [String: Any] = [
            kCGWindowOwnerName as String: "Ghostty", kCGWindowLayer as String: 0,
            kCGWindowBounds as String: CGRect(x: 510, y: 25, width: 1440, height: 875).dictionaryRepresentation,
        ]
        let screen = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let bar = dock(x: 0, y: 826, h: 74, layer: 20)  // the Dock itself
        assert(!WindowServer.isRearranging(in: [bar, app, dock(x: 0)], displays: screen), "one wallpaper, where the screen is: at rest")
        let swipe = [app, dock(x: -1556, y: 33, w: 117, h: 97, layer: -2_147_483_603), dock(x: 1640), dock(x: -1368), dock(x: 136)]
        assert(WindowServer.isRearranging(in: swipe, displays: screen), "wallpapers off the screen's own rect: mid-swipe")
        assert(WindowServer.isRearranging(in: [dock(x: 1)], displays: screen), "the first pixel of a swipe counts")
        let two = screen + [CGRect(x: 1440, y: 0, width: 1440, height: 900)]
        assert(!WindowServer.isRearranging(in: [dock(x: 0), dock(x: 1440)], displays: two), "a second screen's wallpaper is at rest too")
        assert(!WindowServer.isRearranging(in: [dock(x: 300, w: 500, h: 400)], displays: screen), "a Dock window that is no wallpaper says nothing")
        // Mission Control: the wallpaper hasn't moved, but the Dock has a window among the normal ones.
        assert(WindowServer.isRearranging(in: [app, dock(x: 0, layer: 0), dock(x: 0)], displays: screen), "a normal-level Dock window: Mission Control")
    }

    static func finderReplyParsing() {
        let hit = FinderWatcher.parse("/Users/me/a|b/|61,288,1221,1033")
        assert(hit?.path == "/Users/me/a|b/", "a bar in a folder name is part of the path")
        assert(
            hit?.bounds == CGRect(x: 61, y: 288, width: 1160, height: 745),
            "left,top,right,bottom should become a rect: \(String(describing: hit?.bounds))")
        assert(FinderWatcher.parse("NONE") == nil, "no Finder window is no folder")
        assert(FinderWatcher.parse("/a|1,2,3") == nil, "a short reply is no folder")

        let folder = CGRect(x: 61, y: 288, width: 1160, height: 745)
        assert(FinderWatcher.near(folder, folder.offsetBy(dx: 1, dy: 0)), "rounding slack")
        assert(!FinderWatcher.near(folder, folder.offsetBy(dx: 40, dy: 0)), "another window is not it")
    }

    /// A script that doesn't compile fails every poll without a word, and that app's notes never show. Compiling sends the app nothing.
    static func appleScriptsCompile() {
        for (name, script) in [("Finder", FinderWatcher.script), ("Terminal", TerminalContainer.ttyScript)] {
            var error: NSDictionary?
            let compiled = script?.compileAndReturnError(&error) == true
            assert(compiled, "the \(name) script must compile: \(error ?? [:])")
        }
    }

    /// Issue #13: a save must not write the old words over a file a script has rewritten.
    static func mergeKeepsNewerFile() {
        let seen = Note(text: "old", dx: 1, dy: 1)
        let disk = Note(text: "from the script", dx: 1, dy: 1)
        let dragged = Note(text: "old", dx: 50, dy: 60)
        let merged = Note.merge(mine: dragged, seen: seen, disk: disk)
        assert(merged.text == "from the script", "a drag keeps the file's words")
        assert(merged.dx == 50 && merged.dy == 60, "and still moves the note")

        let typed = Note(text: "typed now", dx: 1, dy: 1)
        assert(Note.merge(mine: typed, seen: seen, disk: disk) == typed, "what the user typed wins")

        // Each field on its own: the user recolours while a script rewrites the text.
        var recoloured = seen
        recoloured.color = "AEC6FF"
        let both = Note.merge(mine: recoloured, seen: seen, disk: disk)
        assert(both.text == "from the script" && both.color == "AEC6FF", "both changes survive: \(both)")
        assert(Note.merge(mine: dragged, seen: seen, disk: seen) == dragged, "nobody else wrote: as is")
        assert(Note.merge(mine: dragged, seen: nil, disk: disk) == dragged, "nothing seen yet: as is")
        assert(Note.merge(mine: dragged, seen: seen, disk: nil) == dragged, "file gone: as is")

        let pending = Debouncer(delay: 60)
        assert(!pending.isPending, "nothing scheduled, nothing pending")
        pending.call { true }
        assert(pending.isPending, "a scheduled save is pending until it runs")
        pending.flush()
        assert(!pending.isPending, "a run save is no longer pending")
    }

    static func dashboardBackdrop() {
        assert(NoteGrid.backdrop([]) == [], "no notes, no gradient")
        assert(NoteGrid.backdrop(["ffeb73"]) == ["FFEB73", "FFEB73"], "one colour still makes a run")
        assert(
            NoteGrid.backdrop(["FFEB73", "AEC6FF", "ffeb73", "FFB3BA"]) == ["FFEB73", "AEC6FF", "FFB3BA"],
            "each colour once, in the order the notes come")
        assert(NoteGrid.backdrop(["1", "2", "3", "4", "5"]).count == 4, "at most four stops")
    }

    static func markdownRoundTrip() {
        // The backward-compat guarantee: a note saved as markdown must survive parse -> serialize
        // unchanged, so .tack.json stays markdown and pre-Notion notes keep working.
        let corpus = [
            "**bold**", "*italic*", "`code`", "~~strike~~",
            "# Heading", "## Two", "### Three",
            "- item", "- [ ] task", "- [x] done",
            "# **Big**", "- **milk** 2L",
            "plain text",
            "# Title\nsome **bold** here\n- a\n- b",
            "",
        ]
        // Every face, because switching one re-parses the buffer through this round trip: what a
        // note is set in must never reach the file.
        for family in NoteFont.allCases {
            MarkdownStyle.family = family
            for md in corpus {
                let round = MarkdownDocument.serialize(MarkdownDocument.parse(md))
                assert(
                    round == md,
                    "round-trip in \(family) changed \(md.debugDescription) -> \(round.debugDescription)")
            }
        }
        MarkdownStyle.family = .sans
    }

    static func fontFaces() {
        assert(NoteFont(rawValue: "wat") == nil, "an unknown face falls back to the default")
        // Distinct faces, or the font picker would offer three identical choices.
        let faces = Set(NoteFont.allCases.map { $0.font(ofSize: 14).fontName })
        assert(faces.count == NoteFont.allCases.count, "the three faces should differ: \(faces)")
        // Every choice is the same circle, whatever the face measures — the picker's strip is
        // laid out on that assumption.
        for face in NoteFont.allCases {
            let dot = face.dotImage(size: 16).size
            assert(dot.width == dot.height, "\(face)'s dot should stay a circle: \(dot)")
        }
    }

    /// The pill's two shapes: a circle at rest, wider when hovered, and never wider than the
    /// narrowest note it has to sit in.
    /// Every glyph a pill dot wears — the "T" of each face and each SF Symbol — must sit in the
    /// middle of its dot by what is actually drawn, not by its padded box.
    static func dotGlyphsAreCentred() {
        let square = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { _ in
            NSColor.black.setFill()
            NSRect(x: 2, y: 3, width: 4, height: 5).fill()
            return true
        }
        assert(square.inkBounds == NSRect(x: 2, y: 3, width: 4, height: 5), "ink is what is drawn: \(square.inkBounds)")

        let glyphs: [(String, NSImage)] =
            NoteFont.allCases.map { face in
                let label = NSAttributedString(string: "T", attributes: [.font: face.font(ofSize: 11)])
                return ("T in \(face)", NSImage(size: label.size(), flipped: false) { _ in label.draw(at: .zero); return true })
            }
            + ["trash.fill", "square.grid.2x2.fill", "macwindow", "doc.fill"].map { name in
                (name, NSImage(systemSymbolName: name, accessibilityDescription: nil)!
                    .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))!)
            }
        for (name, glyph) in glyphs {
            let canvas = NSRect(x: 0, y: 0, width: 16, height: 16)
            let placed = NSImage(size: canvas.size, flipped: false) { rect in
                glyph.drawInkCentered(in: rect)
                return true
            }
            let ink = placed.inkBounds
            let off = max(abs(ink.midX - canvas.midX), abs(ink.midY - canvas.midY))
            assert(off <= 0.25, "\(name) is \(off)pt off-centre in its dot: \(ink)")
        }
    }

    static func pillGeometry() {
        let closed = NotePill.pillClosedSize
        assert(closed.width == closed.height, "closed, the pill should be a circle: \(closed)")
        let open = NotePill.pillOpenSize
        assert(open.width > closed.width, "hovering should widen the pill")
        assert(open.height == closed.height, "only the width moves, so the corner radius holds")
        assert(
            open.width + NotePill.pillInset * 2 <= NotePreferences.shared.minSize.width,
            "the open pill should fit the smallest note: \(open.width)")

        // The picker's strip is cut to what the note can hold — inverting pillSize, so the two
        // can't drift apart. One dot is the floor: a picker with nothing in it is a dead end.
        assert(NotePill.pillDots(fitting: 10) == 1, "a hopeless width should still offer one dot")
        for width in [100.0, 160.0, 220.0, 400.0] as [CGFloat] {
            let n = NotePill.pillDots(fitting: width)
            let fits = NotePill.pillSize(dots: n).width + NotePill.pillInset * 2 <= width
            assert(fits, "\(n) dots should fit a \(width)pt note")
            assert(
                NotePill.pillSize(dots: n + 1).width + NotePill.pillInset * 2 > width,
                "\(n) dots is short of what fits a \(width)pt note")
        }
        assert(
            NotePill.pillDots(fitting: NotePreferences.shared.defaultSize.width)
                >= NotePreferences.shared.palette.count,
            "the preset palette should fit a default-sized note")
    }

    /// Blocks own their style: anywhere inside a heading block reports that heading, including its
    /// very start, where the caret's neighbour is the previous block's newline.
    static func blockStyleAtCaret() {
        let doc = MarkdownDocument.parse("# Title\nbody\n## Two")
        let start = (doc.string as NSString).range(of: "Title").location
        assert(MarkdownInput.blockHeading(doc, at: start) == 1, "block start should still be H1")
        assert(MarkdownInput.blockHeading(doc, at: start + 3) == 1, "mid-block should be H1")
        let body = (doc.string as NSString).range(of: "body").location
        assert(MarkdownInput.blockHeading(doc, at: body) == nil, "a body block has no heading")
        assert(
            MarkdownInput.blockHeading(doc, at: (doc.string as NSString).range(of: "Two").location) == 2,
            "the last block should be H2")
        // An empty block carries no mark, so there is nothing to report.
        let blank = MarkdownDocument.parse("a\n\nb")
        assert(MarkdownInput.blockHeading(blank, at: 2) == nil, "an empty block reports no heading")
    }

    /// Block mode's walk: Esc selects the caret's block, ↑/↓ step, Enter re-enters at its end.
    static func blockNavigation() {
        let text = "# Title\nbody\n\nlast" as NSString
        let first = Blocks.range(in: text, at: 3)
        assert(text.substring(with: first) == "# Title\n", "the caret's block is its paragraph")
        assert(Blocks.step(from: first, by: -1, in: text) == nil, "nothing above the first block")

        let second = Blocks.step(from: first, by: 1, in: text)!
        assert(text.substring(with: second) == "body\n", "↓ should step to the next block")
        assert(Blocks.step(from: second, by: -1, in: text) == first, "↑ should step back")

        let blank = Blocks.step(from: second, by: 1, in: text)!
        assert(text.substring(with: blank) == "\n", "an empty block is a block")
        let last = Blocks.step(from: blank, by: 1, in: text)!
        assert(Blocks.step(from: last, by: 1, in: text) == nil, "nothing below the last block")

        // Enter drops in after the text, never after the newline (that is the next block).
        assert(Blocks.contentEnd(first, in: text) == 7, "caret lands at the end of the block's text")
        assert(Blocks.contentEnd(last, in: text) == text.length, "a block without a newline ends at its end")
    }

    /// Backspace on an empty last block used to read an attribute one past the end of the text and
    /// take the app down with it. Nothing to handle here — it falls through to the text view.
    static func backspaceAtTheEnd() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.textStorage?.setAttributedString(MarkdownDocument.parse("a\n"))
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        let handled = MarkdownInput.handle(
            #selector(NSStandardKeyBindingResponding.deleteBackward(_:)), tv)
        assert(!handled, "backspace on an empty last block is the text view's own deletion")
    }

    static func noteSizeIsOptional() {
        // The no-migration guarantee, same shape as the key-format one: a note written before
        // resizing existed must still decode, and say nothing about its size rather than 0x0.
        let old = #"{"text":"hi","dx":12,"dy":34}"#.data(using: .utf8)!
        guard let n = try? JSONDecoder().decode(Note.self, from: old) else {
            assert(false, "a pre-resize note should still decode")
            return
        }
        assert(n.w == nil && n.h == nil, "a missing size should decode as nil, not zero: \(n)")
        assert(n.font == nil, "a pre-font note should say nothing about its face: \(n)")
        assert(n.text == "hi" && n.dx == 12, "the rest of the note should survive: \(n)")

        let sized = Note(text: "hi", dx: 1, dy: 2, color: nil, w: 300, h: 240)
        let data = try! JSONEncoder().encode(sized)
        assert(try! JSONDecoder().decode(Note.self, from: data) == sized, "size should round-trip")
    }

    static func collapsedNote() {
        // Same no-migration guarantee: an older note decodes as expanded, and an expanded note
        // writes no `collapsed` key at all, so files stay byte-for-byte what they were.
        let old = #"{"text":"hi","dx":12,"dy":34,"w":300,"h":240}"#.data(using: .utf8)!
        let n = try! JSONDecoder().decode(Note.self, from: old)
        assert(n.collapsed == nil, "a pre-collapse note should decode as expanded: \(n)")
        let plain = String(data: try! JSONEncoder().encode(n), encoding: .utf8)!
        assert(!plain.contains("collapsed"), "an expanded note should not write the key: \(plain)")

        var folded = n
        folded.collapsed = true
        let back = try! JSONDecoder().decode(Note.self, from: try! JSONEncoder().encode(folded))
        assert(back == folded, "collapsed should round-trip")
        assert(back.w == 300 && back.h == 240, "folding must keep the expanded size: \(back)")

        // Folded: the bar keeps the note's width but takes the bar's height; a window shorter
        // than the bar still caps it. Unfolded: exactly `fit`.
        let window = CGSize(width: 800, height: 600)
        let desired = CGSize(width: 300, height: 240)
        assert(
            Coord.shown(desired: desired, window: window, collapsedHeight: 30)
                == CGSize(width: 300, height: 30), "a folded note should be a 30pt bar")
        assert(
            Coord.shown(desired: desired, window: CGSize(width: 200, height: 20), collapsedHeight: 30)
                == CGSize(width: 200, height: 20), "a tiny window should cap even the bar")
        assert(
            Coord.shown(desired: desired, window: window, collapsedHeight: nil)
                == Coord.fit(desired: desired, window: window), "unfolded is just fit")
    }

    static func collapsedTitle() {
        let cases: [(String, String)] = [
            ("ESlint\n\n# Material Editor fragment", "ESlint"),
            ("\n\n  # Heading  \nbody", "Heading"),
            ("- [ ] buy milk", "buy milk"),
            ("- [x] done", "done"),
            ("* item", "item"),
            ("12. twelfth", "twelfth"),
            ("> quoted", "quoted"),
            ("**bold** and `code`", "bold and code"),
            ("#hashtag is not a heading", "#hashtag is not a heading"),
            ("", ""),
            ("\n   \n", ""),
        ]
        for (markdown, expected) in cases {
            let got = Note.title(of: markdown)
            assert(got == expected, "title of \(markdown.debugDescription): \(got.debugDescription)")
        }
    }


    static func urlNormalization() {
        // Query and fragment are session noise; a note pinned to a page should survive them.
        assert(
            BrowserContainer.normalize("https://github.com/x/y?tab=readme#install")
                == "https://github.com/x/y", "should strip query and fragment")
        assert(
            BrowserContainer.normalize("https://x.com/a") == "https://x.com/a",
            "a clean URL should pass through untouched")

        // Anything unparseable is used as-is rather than crashing or collapsing to "".
        assert(BrowserContainer.normalize("notaurl") == "notaurl", "garbage should pass through")
        assert(BrowserContainer.normalize("") == "", "empty should pass through")
    }
}

// MARK: - Several notes per place

extension SelfTest {
    private static func json(_ value: some Encodable) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    static func noteListFormat() {
        // Reading: the pre-multi-note shape (one bare object) and the list shape both decode.
        let bare = #"{"text":"old","dx":1,"dy":2}"#
        let one = try! JSONDecoder().decode(NoteList.self, from: Data(bare.utf8))
        assert(one.notes.map(\.text) == ["old"], "a single older note decodes as a list of one")
        let many = try! JSONDecoder().decode(
            NoteList.self, from: Data(#"[{"text":"a","dx":1,"dy":2,"id":"a"},{"text":"b","dx":3,"dy":4,"id":"b"}]"#.utf8))
        assert(many.notes.map(\.id) == ["a", "b"], "a list decodes in order")

        // Writing: one note stays a bare object — exactly what an older Tack reads as `Note` —
        // and only two or more become an array.
        let single = NoteList([Note(text: "solo", dx: 1, dy: 2, id: "s")])
        let singleJSON = json(single)
        assert(singleJSON.hasPrefix("{"), "one note is written as a bare object: \(singleJSON)")
        let asOlderTackReadsIt = try? JSONDecoder().decode(Note.self, from: Data(singleJSON.utf8))
        assert(asOlderTackReadsIt?.text == "solo", "a one-note place stays readable as a plain Note")
        assert(json(many).hasPrefix("["), "two notes are written as an array")
        assert(try! JSONDecoder().decode(NoteList.self, from: Data(json(many).utf8)) == many, "a list round-trips")

        // Garbage is still an error (the stores turn it into a preserved recovery copy).
        for bad in [#""text""#, "[1,2]", #"{"dx":1}"#, "[]x"] {
            assert((try? JSONDecoder().decode(NoteList.self, from: Data(bad.utf8))) == nil,
                "\(bad) must not decode as notes")
        }

        // Ids for notes written before ids existed: stable per place and position.
        let ids = NoteList([Note(text: "a", dx: 0, dy: 0), Note(text: "b", dx: 0, dy: 0, id: "kept"),
            Note(text: "c", dx: 0, dy: 0, id: "")]).identified(key: "app|win")
        assert(ids.map(\.id) == ["legacy|app|win|0", "kept", "legacy|app|win|2"],
            "missing or empty ids are derived; real ones are kept: \(ids.map(\.id))")
    }

    static func noteListApplying() {
        let a = Note(text: "a", dx: 0, dy: 0, id: "a")
        let b = Note(text: "b", dx: 0, dy: 0, id: "b")
        let c = Note(text: "c", dx: 0, dy: 0, id: "c")
        var a2 = a
        a2.text = "a edited"
        assert(NoteList.applying(c, to: [a, b]) == [a, b, c], "a new id is appended")
        assert(NoteList.applying(a2, to: [a, b, c]) == [a2, b, c], "an edit replaces in place, order kept")
        let delB = Note(text: "", dx: 0, dy: 0, id: "b")
        assert(NoteList.applying(delB, to: [a, b, c]) == [a, c], "a deletion removes only its own id")
        assert(NoteList.applying(delB, to: [a, c]) == [a, c], "deleting a note that isn't there is a no-op")
        assert(NoteList.applying(Note(text: "", dx: 0, dy: 0, id: "a"), to: [a]).isEmpty, "the last one out empties the place")
        assert(NoteList.applying(delB, to: []).isEmpty, "a never-saved note's deletion writes nothing")
    }

    static func multipleNotesInAFolder() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { NotePreferences.shared.forgetFolder(dir.path) }
        let folder = dir.path, url = NoteStore.fileURL(forFolder: folder)

        // A folder note written by an older Tack: one bare object, no id.
        try! Data(#"{"text":"from before","dx":5,"dy":6,"color":"FFEB73"}"#.utf8).write(to: url)
        let legacy = try! NoteStore.load(folder: folder)
        assert(legacy.count == 1 && legacy[0].id == "legacy|\(NoteStore.key(forFolder: folder))|0",
            "an older folder note loads with a derived id: \(legacy)")
        assert(try! NoteStore.load(folder: folder) == legacy, "and gets the same id on every read")

        // A second note joins it: the file becomes a list, the older note keeps its id and data.
        let second = Note(text: "second", dx: 30, dy: 40, id: "2")
        try! NoteStore.save(folder: folder, note: second)
        let both = try! NoteStore.load(folder: folder)
        assert(both == [legacy[0], second], "both notes, older first: \(both)")
        assert(String(data: try! Data(contentsOf: url), encoding: .utf8)!.hasPrefix("["), "two notes make an array")

        // Editing one leaves the other exactly as it was, and keeps the order.
        var edited = legacy[0]
        edited.text = "from before, edited"
        try! NoteStore.save(folder: folder, note: edited)
        assert(try! NoteStore.load(folder: folder) == [edited, second], "an edit touches only its own note")

        // Deleting one goes back to the single-object format an older Tack can read.
        try! NoteStore.save(folder: folder, note: Note(text: "", dx: 0, dy: 0, id: edited.id))
        assert(try! NoteStore.load(folder: folder) == [second], "only the deleted note goes")
        let onDisk = try? JSONDecoder().decode(Note.self, from: try! Data(contentsOf: url))
        assert(onDisk?.text == "second", "one note left is written as a plain Note again")
        assert(NotePreferences.shared.knownFolders.contains(folder), "a folder with a note stays indexed")

        // The last note out takes the file and the index entry with it.
        try! NoteStore.save(folder: folder, note: Note(text: "", dx: 0, dy: 0, id: "2"))
        assert(!FileManager.default.fileExists(atPath: url.path), "no notes left, no file")
        assert(!NotePreferences.shared.knownFolders.contains(folder), "and the folder leaves the index")
    }

    static func multipleAppNotesAtOneKey() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")
        let key = "com.tinyspeck.slackmacgap|general", other = "com.apple.Preview|Report.pdf"
        let elsewhere = Note(text: "elsewhere", dx: 0, dy: 0, id: "e")
        try! AppNotes.save(key: other, note: elsewhere, to: url)

        // Two windows' worth of saves interleaving, the way two debounced notes do: neither may
        // clobber the other, since each write reads the place fresh and changes only its own id.
        var one = Note(text: "one", dx: 10, dy: 10, id: "1")
        var two = Note(text: "two", dx: 40, dy: 40, id: "2")
        try! AppNotes.save(key: key, note: one, to: url)
        try! AppNotes.save(key: key, note: two, to: url)
        one.text = "one, typed more"
        try! AppNotes.save(key: key, note: one, to: url)
        two.collapsed = true
        try! AppNotes.save(key: key, note: two, to: url)
        assert(try! AppNotes.load(key: key, from: url) == [one, two], "both notes keep their own latest edit")
        assert(try! AppNotes.load(key: other, from: url) == [elsewhere], "other places are untouched")

        try! AppNotes.save(key: key, note: Note(text: "", dx: 0, dy: 0, id: "1"), to: url)
        assert(try! AppNotes.load(key: key, from: url) == [two], "deleting one note keeps the other")
        try! AppNotes.save(key: key, note: Note(text: "", dx: 0, dy: 0, id: "2"), to: url)
        assert(try! AppNotes.all(from: url).keys.sorted() == [other], "the emptied place leaves the file")
    }

    static func olderNotesGetDistinctIDs() {
        // Older notes at a tab and its window both sit at position 0 of their place. Their
        // derived ids must differ, or showing every level at once would treat them as one note
        // and hide one of them.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appnotes.json")
        try! Data(#"{"app|win":{"text":"window","dx":1,"dy":1},"app":{"text":"app","dx":2,"dy":2}}"#.utf8).write(to: url)
        let all = try! AppNotes.all(from: url)
        let ids = [all["app|win"]![0].id!, all["app"]![0].id!]
        assert(Set(ids).count == 2, "older notes at different places get different ids: \(ids)")
    }

    static func cascadeNewNotes() {
        let note = CGSize(width: 220, height: 170), window = CGSize(width: 800, height: 600)
        let start = (dx: 100.0, dy: 100.0)
        func at(_ taken: [(dx: Double, dy: Double)]) -> (dx: Double, dy: Double) {
            Coord.cascade(from: start, avoiding: taken, note: note, window: window)
        }
        let free = at([])
        assert(free == (100, 100), "nothing in the way: the note goes where asked")
        let second = at([start])
        assert(second == (124, 124), "taken: one step down and right: \(second)")
        let third = at([start, second])
        assert(third == (148, 148), "and again: \(third)")
        let near = at([(dx: 110, dy: 90)])
        assert(near.dx != 100 || near.dy != 100, "a note a few points off still counts as in the way")

        // Stepping off the bottom-right wraps back inside the window rather than escaping it.
        let corner = (dx: 580.0, dy: 430.0)  // the furthest a 220x170 note can sit
        let wrapped = Coord.cascade(from: corner, avoiding: [corner], note: note, window: window)
        assert(wrapped.dx >= 0 && wrapped.dy >= 0 && wrapped.dx + 220 <= 800 && wrapped.dy + 170 <= 600,
            "a cascaded note stays inside the window: \(wrapped)")
        assert(wrapped != corner, "and doesn't land back on the note it was avoiding")

        // No free spot at all (a window the note fills): it still ends, inside the window.
        let full = Coord.cascade(from: (0, 0), avoiding: [(0, 0)], note: note, window: CGSize(width: 220, height: 170))
        assert(full == (0, 0), "a window with no room settles on the only spot there is: \(full)")

        // A crowd of notes: every one placed still lands inside, and they don't pile up.
        var taken: [(dx: Double, dy: Double)] = []
        for _ in 0..<30 { taken.append(Coord.cascade(from: start, avoiding: taken, note: note, window: window)) }
        assert(taken.allSatisfy { $0.dx >= 0 && $0.dy >= 0 && $0.dx + 220 <= 800 && $0.dy + 170 <= 600 },
            "every cascaded note stays inside the window")
        let distinct = Set(taken.map { "\(Int($0.dx)),\(Int($0.dy))" })
        assert(distinct.count == 30, "thirty notes, thirty different spots: \(distinct.count)")
    }

    static func placeNames() {
        let slack = "com.tinyspeck.slackmacgap"
        assert(Container.placeName(for: slack, appName: "Slack") == "Slack", "a whole-app note is named after the app")
        assert(
            Container.placeName(for: slack + "|design (Channel) - Acme - Slack", appName: "Slack") == "design (Channel) - Acme",
            "a window title's trailing app name goes")
        assert(Container.placeName(for: slack + "|Slack", appName: "Slack") == "Slack", "but not when it is the whole title")
        assert(Container.placeName(for: "x|Report.pdf", appName: "Preview") == "Report.pdf", "a document reads as-is")
        assert(
            Container.placeName(for: FinderContainer.bundleID + "|/Users/me/Projects", appName: "Finder") == "Projects",
            "a folder by its name")
        assert(
            Container.placeName(for: "com.google.Chrome|https://example.com/page?q=1", appName: "Chrome") == "example.com/page",
            "a tab by its page")
    }

    static func notesElsewhere() {
        let notes = ["a": 2, "a|chat1": 1, "a|chat2": 3, "a.helper|x": 1, "b|y": 4, "a|empty": 0]
        let found = Container.elsewhere(in: notes, bundleID: "a", shown: ["a", "a|chat1"])
        assert(found.map(\.key) == ["a|chat2"], "only the app's other places with notes: \(found)")
        assert(found.first?.count == 3, "with how many each holds")
        assert(Container.elsewhere(in: notes, bundleID: "c", shown: []).isEmpty, "an app with no notes has none elsewhere")
        let c = FakeContainer(path: ["app", "win", "tab"])
        assert(c.allKeys == ["app", "app|win", "app|win|tab"], "every level's key: \(c.allKeys)")
    }

    static func newNotesRememberTheApp() {
        assert(NotePreferences.newNoteLevel(pinLevels: [0, 1], finest: 1, appWide: false) == 1, "the window by default")
        assert(NotePreferences.newNoteLevel(pinLevels: [0, 1], finest: 1, appWide: true) == 0, "the app once chosen there")
        assert(NotePreferences.newNoteLevel(pinLevels: [1], finest: 1, appWide: true) == 1, "never a level not offered")

        let suite = "selftest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = NotePreferences(defaults: defaults)
        assert(!prefs.pinsAppWide("a"), "no app pins app-wide until told")
        prefs.setPinsAppWide("a", true)
        prefs.setPinsAppWide("b", true)
        assert(prefs.pinsAppWide("a") && prefs.pinsAppWide("b"), "each app remembers its own")
        prefs.setPinsAppWide("a", false)
        assert(!prefs.pinsAppWide("a") && prefs.pinsAppWide("b"), "and forgets only its own")
    }

    static func notesAddedOnDisk() {
        let a = Note(text: "a", dx: 0, dy: 0, id: "A")
        let b = Note(text: "b", dx: 0, dy: 0, id: "B")
        assert(AppDelegate.unshown([a, b], shown: ["A"]) == [b], "only the note no window shows is new")
        assert(AppDelegate.unshown([a, b], shown: ["A", "B"]).isEmpty, "every note shown: nothing new")
        assert(AppDelegate.unshown([a], shown: []) == [a], "nothing shown: every note is new")
        let legacy = Note(text: "old", dx: 0, dy: 0)
        assert(AppDelegate.unshown([legacy], shown: [nil]).isEmpty, "an id-less note shown is not new")
        let empty = Note(text: "", dx: 0, dy: 0, id: "E")
        assert(AppDelegate.unshown([empty], shown: []).isEmpty, "an empty note is never put up")
    }

    static func dashboardPlacement() {
        let left = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let right = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let left_ = NSRect(x: 100, y: 100, width: 760, height: 560)
        assert(DashboardWindow.placed(left_, on: left) == left_, "on the same display it stays where it was left")
        let moved = DashboardWindow.placed(left_, on: right)
        assert(moved.size == left_.size, "to another display it keeps its size")
        assert(moved.midX == right.midX && moved.midY == right.midY, "centred there: \(moved)")
        let huge = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        let small = NSRect(x: 2000, y: 0, width: 800, height: 600)
        let fitted = DashboardWindow.placed(huge, on: small)
        assert(small.contains(fitted), "shrunk to fit a smaller display: \(fitted)")
        let straddling = NSRect(x: 1300, y: 100, width: 760, height: 560)  // mostly on the right one
        assert(DashboardWindow.placed(straddling, on: right) == straddling, "its centre's display is its own")
    }

    static func dashboardGroups() {
        func n(_ key: String, _ text: String) -> StoredNote { StoredNote(key: key, note: Note(text: text, dx: 0, dy: 0)) }
        // Sorted by key, "com.foo.bar" lands between two places of "com.foo".
        let stored = [n("com.foo", "1"), n("com.foo.bar|x", "2"), n("com.foo|a", "3"), n("com.foo|a", "4")]
        let groups = NoteGrid.groups(stored)
        assert(groups.map(\.app) == ["com.foo", "com.foo.bar"], "one group per app, in first-seen order")
        assert(groups[0].places.map(\.key) == ["com.foo", "com.foo|a"], "an app's places stay together")
        assert(groups[0].places[1].notes.map(\.note.text) == ["3", "4"], "and a place's notes keep their order")
    }

    static func dashboardSearch() {
        let text = "Ship the Café menu  Slack — design"
        assert(NoteGrid.matches("", text), "an empty search matches everything")
        assert(NoteGrid.matches("cafe slack", text), "every word, any order, case and accents ignored")
        assert(!NoteGrid.matches("cafe teams", text), "a word that isn't there misses")
    }

}
