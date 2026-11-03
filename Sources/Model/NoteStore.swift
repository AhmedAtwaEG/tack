import Foundation

enum NotePersistenceError: LocalizedError {
    case createDirectory(URL, Error)
    case read(URL, Error)
    case invalidJSON(URL, recovery: URL?, Error)
    case encode(URL, Error)
    case backup(URL, Error)
    case write(URL, Error)
    case delete(URL, Error)

    var errorDescription: String? {
        switch self {
        case .createDirectory(let url, let error):
            return "Could not create the notes folder at \(url.path): \(error.localizedDescription)"
        case .read(let url, let error):
            return "Could not read notes at \(url.path): \(error.localizedDescription)"
        case .invalidJSON(let url, let recovery, let error):
            let preserved = recovery.map { " A recovery copy was kept at \($0.path)." }
                ?? " The original file was left untouched."
            return "Notes at \(url.path) contain invalid JSON: \(error.localizedDescription).\(preserved)"
        case .encode(let url, let error):
            return "Could not encode notes for \(url.path): \(error.localizedDescription)"
        case .backup(let url, let error):
            return "Could not back up notes at \(url.path): \(error.localizedDescription)"
        case .write(let url, let error):
            return "Could not save notes at \(url.path): \(error.localizedDescription)"
        case .delete(let url, let error):
            return "Could not delete notes at \(url.path): \(error.localizedDescription)"
        }
    }
}

/// The shared safety boundary for both JSON stores: missing is not an error, malformed is.
private enum JSONFile {
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NotePersistenceError.read(url, error)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NotePersistenceError.invalidJSON(url, recovery: recoveryCopy(of: url), error)
        }
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL, backup: Bool = false) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw NotePersistenceError.encode(url, error)
        }

        if backup, FileManager.default.fileExists(atPath: url.path) {
            do {
                let existing = try Data(contentsOf: url)
                try existing.write(to: backupURL(for: url), options: .atomic)
            } catch {
                throw NotePersistenceError.backup(url, error)
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw NotePersistenceError.write(url, error)
        }
    }

    static func delete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw NotePersistenceError.delete(url, error)
        }
    }

    static func backupURL(for url: URL) -> URL { url.appendingPathExtension("backup") }

    private static func recoveryCopy(of url: URL) -> URL? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let copy = url.appendingPathExtension("corrupt-\(Int(date.timeIntervalSince1970))")
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil  // the invalid original remains untouched and is named in the error
        }
    }
}

/// Reads/writes a hidden `.tack.json` inside the folder itself, so notes travel
/// with the folder when it's moved or copied. One folder can hold several notes (see `NoteList`).
enum NoteStore {
    static let fileName = ".tack.json"

    static func fileURL(forFolder folder: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(fileName)
    }

    /// The key a folder's notes are filed under everywhere else, and what older notes' ids derive from.
    static func key(forFolder folder: String) -> String {
        Container.key(path: [FinderContainer.bundleID, folder], level: 1)
    }

    /// Every note in the folder, in the order they were added; empty when there's no file.
    static func load(folder: String) throws -> [Note] {
        try JSONFile.load(NoteList.self, from: fileURL(forFolder: folder))?
            .identified(key: key(forFolder: folder)) ?? []
    }

    /// Writes one note into the folder by id — replacing it, adding it, or (empty text) removing
    /// it — and leaves the folder's other notes exactly as they were. The last note out takes the
    /// file with it.
    static func save(folder: String, note: Note) throws {
        let url = fileURL(forFolder: folder)
        let current = try load(folder: folder)  // throws on malformed data: never overwrite it
        let notes = NoteList.applying(note, to: current)
        if notes.isEmpty {
            try JSONFile.delete(url)
            NotePreferences.shared.forgetFolder(folder)
        } else {
            try JSONFile.save(NoteList(notes), to: url)
            NotePreferences.shared.rememberFolder(folder)  // the only index these notes get
        }
    }
}

/// Notes bound to app windows (not Finder folders) live in one central JSON, keyed by a
/// window identity string, since a generic app window has no folder to write into. Each key
/// holds that place's notes in the same one-or-many shape as a folder file.
enum AppNotes {
    private static func fileURL() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tack", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw NotePersistenceError.createDirectory(dir, error)
        }
        return dir.appendingPathComponent("appnotes.json")
    }

    /// Every app note at once, keyed by container key — what the Tack window lists.
    static func all() throws -> [String: [Note]] { try all(from: fileURL()) }

    static func all(from url: URL) throws -> [String: [Note]] {
        let raw = try JSONFile.load([String: NoteList].self, from: url) ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.map { ($0.key, $0.value.identified(key: $0.key)) })
    }

    static func load(key: String) throws -> [Note] { try load(key: key, from: fileURL()) }

    static func load(key: String, from url: URL) throws -> [Note] { try all(from: url)[key] ?? [] }

    /// Load a stable key, migrating the old title-dependent key on first access.
    static func load(key: String, migrating legacyKey: String) throws -> [Note] {
        try load(key: key, migrating: legacyKey, from: fileURL())
    }

    /// The whole place moves in a single write — its notes land at the stable key and the
    /// legacy key goes, together, so an interruption can't leave half of them behind. Ids are
    /// fixed as they move, so an older note keeps the id it was shown under.
    static func load(key: String, migrating legacyKey: String, from url: URL) throws -> [Note] {
        var dict = try all(from: url)
        if let notes = dict[key], !notes.isEmpty { return notes }
        guard legacyKey != key, let notes = dict[legacyKey], !notes.isEmpty else { return [] }
        dict[key] = notes
        dict[legacyKey] = nil
        try write(dict, to: url)
        return notes
    }

    static func save(key: String, note: Note) throws {
        try save(key: key, note: note, to: fileURL())
    }

    /// One note into one key by id; every other note — at this key and every other — untouched.
    static func save(key: String, note: Note, to url: URL) throws {
        var dict = try all(from: url)
        let notes = NoteList.applying(note, to: dict[key] ?? [])
        dict[key] = notes.isEmpty ? nil : notes
        try write(dict, to: url)
    }

    private static func write(_ dict: [String: [Note]], to url: URL) throws {
        try JSONFile.save(dict.mapValues(NoteList.init), to: url, backup: true)
    }
}

/// One note wherever it happens to live, under the key its container writes it with — bundle ID
/// first, so a single format both labels a note and routes it back to the right store. What the
/// Tack window lists. Several can share a key; the note's id tells them apart.
struct StoredNote {
    let key: String
    var note: Note

    /// Finder notes only: the folder whose .tack.json holds this note.
    var folder: String? {
        let prefix = FinderContainer.bundleID + "|"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    /// Writes back to whichever store the note came from, at the very same key — a note pinned
    /// to an app stays pinned to the app; the level is never re-derived.
    func save(_ edited: Note) throws {
        if let folder {
            try NoteStore.save(folder: folder, note: edited)
        } else {
            try AppNotes.save(key: key, note: edited)
        }
    }

    /// Every note Tack knows about, grouped by app (bundle IDs mix case, so the sort folds it).
    static func all() throws -> [StoredNote] {
        list(appNotes: try AppNotes.all(), folders: NotePreferences.shared.knownFolders)
    }

    /// The two stores merged. A folder whose note has gone (moved, deleted, or on an unmounted
    /// volume) drops out rather than failing the whole list — one unreachable note must not cost
    /// the user the rest of them. Notes sharing a key stay in the order they were added.
    static func list(appNotes: [String: [Note]], folders: [String]) -> [StoredNote] {
        var all = appNotes.flatMap { key, notes in notes.map { StoredNote(key: key, note: $0) } }
        for folder in folders {
            guard let notes = try? NoteStore.load(folder: folder) else { continue }
            let key = NoteStore.key(forFolder: folder)
            all += notes.map { StoredNote(key: key, note: $0) }
        }
        // Sorted by key alone, and stably (Swift's sort isn't), so a place's notes keep their order.
        return all.enumerated()
            .sorted { a, b in
                let (ka, kb) = (a.element.key.lowercased(), b.element.key.lowercased())
                return ka != kb ? ka < kb : a.offset < b.offset
            }
            .map(\.element)
    }
}
