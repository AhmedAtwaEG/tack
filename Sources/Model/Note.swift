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
