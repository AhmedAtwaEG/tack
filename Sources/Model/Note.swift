import Foundation

/// One post-it: text, its offset (dx, dy) from the Finder window's top-left corner, its colour
/// as an "RRGGBB" hex string, and its size. Colour and size are optional for the same reason —
/// nil means "the default", which is what every file written before they existed decodes to.
struct Note: Codable, Equatable {
    var text: String
    var dx: Double
    var dy: Double
    var color: String? = nil
    var font: String? = nil  // NoteFont.rawValue
    var w: Double? = nil
    var h: Double? = nil
    /// Folded down to its title bar, like a Stickies note. nil (every older file) means expanded;
    /// `w`/`h` keep the expanded size either way, so unfolding restores it.
    var collapsed: Bool? = nil
    /// Which note this is among the others pinned to the same place. Every note this version of
    /// Tack writes has one; a note from before multiple notes existed has none on disk and is
    /// given a stable one as it's read (see `NoteList.identified`).
    var id: String? = nil

    /// A brand-new note: its own id, everything else default.
    static func new(dx: Double, dy: Double) -> Note {
        Note(text: "", dx: dx, dy: dy, id: UUID().uuidString)
    }

    /// The app-wide deletion convention: an empty note is not stored, it's removed. Every store
    /// honours this one property, so "does trimming count as empty?" can only ever have one answer.
    var isDeletion: Bool { text.isEmpty }

    /// What a collapsed note's bar reads: the first line with text in it, minus the markdown
    /// that marks its block (heading, list, quote, checkbox) and any bold/italic markers.
    static func title(of markdown: String) -> String {
        for line in markdown.split(whereSeparator: \.isNewline) {
            var s = line.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: #"^(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+|>\s*)"#,
                options: .regularExpression)
            {
                s.removeSubrange(r)
            }
            for marker in ["**", "__", "~~", "`"] { s = s.replacingOccurrences(of: marker, with: "") }
            s = s.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s }
        }
        return ""
    }
}

/// Every note pinned to one place (a folder, a window, a tab, an app), as one value on disk.
///
/// The format is a compatibility guarantee in both directions: a place with exactly one note is
/// written as that bare note object — byte-for-byte the format from before multiple notes, so
/// older Tack builds keep reading it — and only a place with two or more becomes a JSON array.
/// Reading accepts either. An empty list is never written; the stores delete the place instead.
struct NoteList: Codable, Equatable {
    var notes: [Note]

    init(_ notes: [Note]) { self.notes = notes }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Note].self) {
            notes = many
        } else {
            notes = [try container.decode(Note.self)]  // the pre-multi-note shape; throws if neither
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if notes.count == 1 { try container.encode(notes[0]) } else { try container.encode(notes) }
    }

    /// Notes written before ids existed get one derived from where they live and their position
    /// there, so the same note gets the same id on every read and two older notes in different
    /// places never collide. It sticks the first time the place is written back.
    func identified(key: String) -> [Note] {
        notes.enumerated().map { i, note in
            var n = note
            if n.id?.isEmpty ?? true { n.id = "legacy|\(key)|\(i)" }
            return n
        }
    }

    /// `note` written into `notes` by id: replaced in place, appended if it's new, removed if it's
    /// a deletion (an empty note). Pure, so every store edits a place the same way.
    static func applying(_ note: Note, to notes: [Note]) -> [Note] {
        var out = notes
        let i = out.firstIndex { $0.id == note.id }
        switch (i, note.isDeletion) {
        case (let i?, true): out.remove(at: i)
        case (let i?, false): out[i] = note
        case (nil, false): out.append(note)
        case (nil, true): break  // deleting a note that was never saved: nothing to do
        }
        return out
    }
}
