import AppKit

/// Every note Tack holds, laid out side by side — what a note shows when it grows into the
/// Tack dashboard. Only the contents: there is no window of its own, the note *is* the window.
///
/// Each cell is a real `NoteCard`, not a picture of one: the same glass, the same markdown, the
/// same hover pill. What a cell may change is exactly what a card owns — text, colour, face —
/// so browsing the grid can never move or resize a note on the window it belongs to.
final class NoteGrid: NSObject {
    /// The dashboard's top strip, which it is dragged by and the pill sits in.
    static let strip: CGFloat = 30

    /// The dashboard's page: the search field in the strip over the scrolling grid. Mount it in
    /// whatever note is showing the dashboard — over the whole card, strip included.
    let view: NSView = PassThroughView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    private let scroll: FocusScrollView
    private let wrap = WrapView()
    /// Narrows the grid to the notes whose words, app or place contain what is typed.
    private let search = NSSearchField()
    private var cells: [NoteGridCell] = []
    /// The card last clicked: the one that scrolls its own text, and sits lifted off the rest.
    private weak var focused: NoteGridCell?
    private var placeholder: NSTextField?
    private let onError: (Error) -> Void

    /// An edit made in the dashboard, as it lands — for the floating note showing the same one.
    var onLiveEdit: ((String, Note) -> Void)?
    /// A cell brought the app its note lives on to the front.
    var onReveal: (() -> Void)?
    /// The notes in the grid — or their colours — may have changed: the dashboard repaints its
    /// background from `colors`.
    var onChange: (() -> Void)?

    /// The colours of the notes shown, as the dashboard's background uses them.
    var colors: [String] { Self.backdrop(cells.map(\.colorHex)) }

    /// Each colour once, in the order the notes are laid out, at most four — past that a
    /// gradient is mud. One colour still makes two stops, so a gradient always has a run.
    static func backdrop(_ hexes: [String]) -> [String] {
        var seen = Set<String>()
        let distinct = hexes.map { $0.uppercased() }.filter { seen.insert($0).inserted }
        let stops = Array(distinct.prefix(4))
        return stops.count == 1 ? stops + stops : stops
    }

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
        scroll = FocusScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        scroll.topBand = Self.strip  // cards scroll up under the strip the dashboard is dragged by
        scroll.bottomFade = 16
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        // No scroller to see: the wheel and the trackpad still scroll, like a note's own text.
        scroll.hasVerticalScroller = false
        wrap.frame = NSRect(origin: .zero, size: scroll.contentSize)
        wrap.autoresizingMask = [.width]  // the clip view owns the width; layout() sets the height
        scroll.documentView = wrap
        view.autoresizingMask = [.width, .height]
        view.addSubview(scroll)
        // In the strip's left end; the pill has its right end. The rest of the strip still drags.
        search.placeholderString = "Search notes"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 11)
        search.sendsSearchStringImmediately = true
        search.frame = NSRect(x: 12, y: view.bounds.height - Self.strip + 5, width: 200, height: 20)
        search.autoresizingMask = [.minYMargin]
        view.addSubview(search)
        super.init()
        wrap.onPress = { [weak self] in self?.unfocus() }
        search.target = self
        search.action = #selector(searchChanged)
    }

    @objc private func searchChanged() { applyFilter() }

    /// Show only the cards that match the search, and only the headings that still head one.
    private func applyFilter() {
        let query = search.stringValue
        for cell in cells {
            cell.isHidden = !Self.matches(query, cell.searchText)
        }
        let shownKeys = Set(cells.filter { !$0.isHidden }.map(\.key))
        let shownApps = Set(shownKeys.map(Self.app(of:)))
        for heading in wrap.subviews.compactMap({ $0 as? GridHeading }) {
            heading.isHidden = heading.key.map { !shownKeys.contains($0) } ?? !shownApps.contains(heading.app)
        }
        wrap.needsLayout = true
    }

    /// Every word typed appears somewhere in `text`, ignoring case and accents. Pure.
    static func matches(_ query: String, _ text: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func app(of key: String) -> String { key.components(separatedBy: "|")[0] }

    /// The notes grouped the way the grid shows them: by app, then by place, each in the order
    /// it first appears. Keyed by bundle ID, not by sort order — "com.foo.bar" sorts between
    /// "com.foo" and "com.foo|x", so a sorted list alone would split an app in two. Pure.
    static func groups(_ stored: [StoredNote]) -> [(app: String, places: [(key: String, notes: [StoredNote])])] {
        var apps: [String] = []
        var places: [String: [String]] = [:]
        var notes: [String: [StoredNote]] = [:]
        for s in stored {
            let app = app(of: s.key)
            if places[app] == nil { apps.append(app); places[app] = [] }
            if notes[s.key] == nil { places[app]!.append(s.key); notes[s.key] = [] }
            notes[s.key]!.append(s)
        }
        return apps.map { app in (app, places[app]!.map { ($0, notes[$0]!) }) }
    }

    /// Put down whichever card is lifted, and end its editing — a click anywhere off the cards.
    func unfocus() {
        focus(nil)
        wrap.window?.makeFirstResponder(nil)
    }

    func reload() {
        flush()  // a discarded cell's pending save must not land on top of what we're about to read
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        setPlaceholder(false)

        let stored: [StoredNote]
        do {
            stored = try StoredNote.all()
        } catch {
            onError(error)
            return
        }
        defer { onChange?() }
        wrap.subviews.filter { $0 is GridHeading }.forEach { $0.removeFromSuperview() }
        search.stringValue = ""  // every opening starts on every note
        guard !stored.isEmpty else {
            setPlaceholder(true)
            wrap.needsLayout = true
            return
        }
        for group in Self.groups(stored) {
            wrap.addSubview(heading(app: group.app, key: nil))
            for place in group.places {
                wrap.addSubview(heading(app: group.app, key: place.key))
                place.notes.forEach { add(NoteGridCell(stored: $0)) }
            }
        }
        wrap.needsLayout = true
    }

    private func heading(app: String, key: String?) -> GridHeading {
        GridHeading(app: app, key: key) { [weak self] key in
            guard Container.reveal(key: key) else { return }
            self?.onReveal?()
        }
    }

    /// A note changed in its floating window while the dashboard is up. Keystrokes arrive here
    /// undebounced, so the cell keeps pace with the typing rather than with the disk.
    ///
    /// ponytail: text, colour and face follow; a resize doesn't — the cell keeps the size it was
    /// built at until the next reload. Reframing mid-type would reflow the whole grid under the
    /// cursor, which is worse than a stale size.
    func update(key: String, note: Note) {
        defer { onChange?() }
        // Several notes can share a key now; the id says which of them this is.
        if let cell = cells.first(where: { $0.key == key && $0.noteID == note.id }) {
            guard !note.isDeletion else { return drop(cell) }
            cell.apply(note)
            return
        }
        // A note made after the dashboard was opened. Showing nothing would be a quiet lie.
        guard !note.isDeletion else { return }
        add(NoteGridCell(stored: StoredNote(key: key, note: note)), placed: true)
        applyFilter()
    }

    /// `placed`: put the cell with its place's other cards, adding the place's heading — and
    /// its app's — when it is the first there. Otherwise it goes last, as a reload builds it.
    private func add(_ cell: NoteGridCell, placed: Bool = false) {
        if placed { return place(cell) }
        configure(cell)
        wrap.addSubview(cell)
    }

    private func place(_ cell: NoteGridCell) {
        configure(cell)
        let app = Self.app(of: cell.key)
        let views = wrap.subviews
        func belongs(_ v: NSView) -> Bool {
            (v as? NoteGridCell).map { Self.app(of: $0.key) == app } ?? ((v as? GridHeading)?.app == app)
        }
        if let last = views.last(where: { ($0 as? NoteGridCell)?.key == cell.key }) {
            wrap.addSubview(cell, positioned: .above, relativeTo: last)
        } else if let last = views.last(where: belongs) {
            let heading = heading(app: app, key: cell.key)
            wrap.addSubview(heading, positioned: .above, relativeTo: last)
            wrap.addSubview(cell, positioned: .above, relativeTo: heading)
        } else {
            wrap.addSubview(heading(app: app, key: nil))
            wrap.addSubview(heading(app: app, key: cell.key))
            wrap.addSubview(cell)
        }
        wrap.needsLayout = true
    }

    private func configure(_ cell: NoteGridCell) {
        cell.onError = onError
        cell.onDelete = { [weak self] cell in self?.drop(cell) }
        cell.onLiveEdit = { [weak self] key, note in
            self?.onLiveEdit?(key, note)
            self?.onChange?()  // a colour picked on a card shows in the background at once
        }
        cell.onReveal = { [weak self] in self?.onReveal?() }
        cell.onPress = { [weak self, weak cell] in self?.focus(cell) }
        setPlaceholder(false)
        cells.append(cell)
    }

    /// Every note key the grid shows.
    var keys: [String] { cells.map(\.key) }

    /// The notes at `key` changed on disk, outside Tack. Each card shows its note's new version —
    /// or goes, when its note is no longer there — unless the user has an edit to it in flight,
    /// which wins when it lands (see Note.merge). A note new at `key` gets a card; an unchanged
    /// one leaves its card alone.
    func adoptFromDisk(key: String, notes: [Note]) {
        for cell in cells
        where cell.key == key && !cell.hasPendingEdit && !notes.contains(where: { $0.id == cell.noteID }) {
            drop(cell)
        }
        for note in notes {
            let cell = cells.first { $0.key == key && $0.noteID == note.id }
            if let cell, cell.hasPendingEdit || cell.currentNote == note { continue }
            update(key: key, note: note)
        }
    }

    /// Lift `cell` and let it scroll its own text; whichever was lifted before settles back.
    private func focus(_ cell: NoteGridCell?) {
        guard cell !== focused else { return }
        focused?.setFocused(false)
        cell?.setFocused(true)
        focused = cell
    }

    /// Write out anything still sitting in a cell's debounce — on quit, and before a reload.
    /// Every cell is flushed even after one fails: a cell that can't save must not cost the
    /// others their edits.
    @discardableResult func flush() -> Bool {
        cells.map { $0.flush() }.allSatisfy { $0 }
    }

    private func drop(_ cell: NoteGridCell) {
        cells.removeAll { $0 === cell }
        cell.removeFromSuperview()
        // A heading with nothing left under it goes too: the place's, then the app's.
        let keys = Set(cells.map(\.key))
        for heading in wrap.subviews.compactMap({ $0 as? GridHeading }) {
            let empty = heading.key.map { !keys.contains($0) } ?? !keys.contains { Self.app(of: $0) == heading.app }
            if empty { heading.removeFromSuperview() }
        }
        setPlaceholder(cells.isEmpty)
        wrap.needsLayout = true
        onChange?()
    }

    /// Kept as a field rather than found by type: cells hold labels of their own, and picking the
    /// placeholder back out of `wrap.subviews` would be guesswork.
    private func setPlaceholder(_ visible: Bool) {
        if !visible {
            placeholder?.removeFromSuperview()
            placeholder = nil
            return
        }
        guard placeholder == nil else { return }
        let label = NSTextField(labelWithString: "No notes yet — add one from the menu bar.")
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        wrap.addSubview(label)
        placeholder = label
    }
}

/// Wraps its subviews left to right at whatever width the scroll view hands it, each at the size
/// it already has — the notes are ragged by design, so there is no grid to fit them to.
///
/// ponytail: every cell is built up front. Fine for the counts a person accumulates; if that ever
/// stops being true, draw unfocused cells as a plain tinted view and swap in a real card on click.
private final class WrapView: NSView {
    private static let gap: CGFloat = 16

    override var isFlipped: Bool { true }  // rows fill top-down, the way they're read

    /// A click between the cards.
    var onPress: () -> Void = {}

    override func mouseDown(with event: NSEvent) { onPress() }

    /// The cards that already have a place. A card arriving (a reload, a new note) is put down
    /// where it belongs; only one that already sat somewhere slides to its new spot — otherwise
    /// every card of a fresh grid would fly in from the corner.
    private let placed = NSHashTable<NSView>.weakObjects()

    override func layout() {
        super.layout()
        let gap = Self.gap
        var x = gap, y = gap, rowHeight: CGFloat = 0
        for sub in subviews where !sub.isHidden {
            // A heading takes a line of its own, the full width; an app's sets off a new group.
            if let heading = sub as? GridHeading {
                if x > gap {
                    y += rowHeight + gap
                    rowHeight = 0
                }
                if heading.key == nil, y > gap { y += 8 }
                x = gap
                heading.setFrameSize(NSSize(width: bounds.width - gap * 2, height: heading.frame.height))
                place(heading, at: NSPoint(x: x, y: y))
                y += heading.frame.height + 6
                continue
            }
            if x > gap, x + sub.frame.width > bounds.width - gap {
                x = gap
                y += rowHeight + gap
                rowHeight = 0
            }
            place(sub, at: NSPoint(x: x, y: y))
            x += sub.frame.width + gap
            rowHeight = max(rowHeight, sub.frame.height)
        }
        // At least as tall as what the scroll view shows: the empty space under the last row is
        // still the grid, and a click there has to reach it (to drop the focus) rather than
        // fall through to the card behind.
        let shown = enclosingScrollView.map { $0.contentSize.height - $0.contentInsets.top - $0.contentInsets.bottom } ?? 0
        let height = max(y + rowHeight + gap, shown)
        // Guarded: setFrameSize re-enters layout, and an unconditional set would never settle.
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
    }

    /// The window was resized, or a card came or went, and the rows broke differently: the
    /// cards that moved glide to their new places. During a live resize each layout pass picks
    /// the move up from wherever the card is, so they trail the window's edge and settle.
    private func place(_ sub: NSView, at origin: NSPoint) {
        guard placed.contains(sub) else {
            placed.add(sub)
            return sub.setFrameOrigin(origin)
        }
        guard sub.frame.origin != origin else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            sub.animator().setFrameOrigin(origin)
        }
    }
}

/// One note in the grid: a live card of it, under its place's heading.
private final class NoteGridCell: NSView {
    private let card: NoteCard
    private var stored: StoredNote
    private let saver = Debouncer(delay: 0.5)  // one per cell: a shared one would cancel its peers

    var onError: (Error) -> Void = { _ in }
    var onDelete: (NoteGridCell) -> Void = { _ in }
    var onLiveEdit: (String, Note) -> Void = { _, _ in }
    var onReveal: () -> Void = {}
    var onPress: () -> Void = {}

    var key: String { stored.key }
    var noteID: String? { stored.note.id }
    /// What the dashboard's search looks through: the words, and where the note lives.
    var searchText: String {
        "\(card.editor.markdown) \(Container.label(for: key)) \(Container.scopeName(for: key))"
    }

    /// The colour the card shows now, previews aside — edits included before they are saved.
    var colorHex: String { card.styler.colorHex }

    init(stored: StoredNote) {
        self.stored = stored
        let size = Self.size(of: stored.note)
        card = NoteCard(size: size, blending: .withinWindow)
        super.init(frame: NSRect(origin: .zero, size: size))

        // Only the card in focus scrolls its own text; the others hand the wheel to the grid.
        card.editor.view.scrollsItself = false
        card.onPress = { [weak self] in self?.onPress() }
        wantsLayer = true
        card.view.frame = NSRect(origin: .zero, size: size)
        card.view.autoresizingMask = []  // cells don't resize; the note keeps the size it has
        addSubview(card.view)
        card.load(stored.note)
        card.onEdit = { [weak self] in self?.scheduleSave() }
        card.onDelete = { [weak self] in self?.deleteConfirmed() }
        card.pill.revealIcon = Container.revealIcon(for: stored.key)
        card.pill.onReveal = { [weak self] in
            guard let self, Container.reveal(key: key) else { return }
            onReveal()
        }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // MARK: - Focus

    private static let liftScale: CGFloat = 1.03
    private static let liftDuration = 0.18

    /// The lifted card's shadow, on a layer of its own under the card. Cut out where the card is:
    /// the card is glass, and a shadow cast under it shows straight through and darkens it.
    private lazy var liftShadow: CALayer = {
        let shadow = CALayer()
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        shadow.shadowRadius = 14
        shadow.shadowOpacity = 0
        layer?.insertSublayer(shadow, at: 0)  // below the card
        return shadow
    }()

    /// Picked up or put down. Picked up, the card grows a touch about its own centre and casts a
    /// deeper shadow, as if lifted off the page — and it is the one card whose text scrolls.
    func setFocused(_ focused: Bool) {
        card.editor.view.scrollsItself = focused
        guard let layer else { return }
        let card = self.card.view.frame
        // The layer's anchor is its corner, so the scale is wrapped in a move to the card's
        // centre and back. The header rides along; only the card casts the shadow.
        var lift = CATransform3DMakeTranslation(card.midX, card.midY, 0)
        lift = CATransform3DScale(lift, Self.liftScale, Self.liftScale, 1)
        lift = CATransform3DTranslate(lift, -card.midX, -card.midY, 0)
        let outline = CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12, transform: nil)
        liftShadow.frame = bounds
        liftShadow.shadowPath = outline
        // Everything around the card, and nothing inside it (even-odd: the card is a hole).
        let around = CGMutablePath()
        around.addRect(bounds.insetBy(dx: -40, dy: -40))
        around.addPath(outline)
        let cutout = CAShapeLayer()
        cutout.path = around
        cutout.fillRule = .evenOdd
        liftShadow.mask = cutout
        layer.zPosition = focused ? 1 : 0  // over its neighbours, without reordering the grid

        let to: (transform: CATransform3D, opacity: Float) =
            focused ? (lift, 0.22) : (CATransform3DIdentity, 0)
        for (target, key, value) in [
            (layer, "transform", to.transform as Any), (liftShadow, "shadowOpacity", to.opacity as Any),
        ] {
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = target.presentation()?.value(forKeyPath: key) ?? target.value(forKeyPath: key)
            move.toValue = value
            move.duration = Self.liftDuration
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            target.add(move, forKey: key)
        }
        layer.transform = to.transform
        liftShadow.shadowOpacity = to.opacity
    }

    /// The note at the size it was left at, floored by the same minimum a real note has.
    private static func size(of note: Note) -> NSSize {
        let fallback = NotePreferences.shared.defaultSize
        let floor = NotePreferences.shared.minSize
        let w = note.w.map { CGFloat($0) } ?? fallback.width
        let h = note.h.map { CGFloat($0) } ?? fallback.height
        return NSSize(width: max(w, floor.width), height: max(h, floor.height))
    }

    // MARK: - Saving

    /// The note as this card shows it now — what a save would write.
    var currentNote: Note { card.note(keeping: stored.note) }
    var hasPendingEdit: Bool { saver.isPending }

    private func scheduleSave() {
        let edited = currentNote  // placement comes back untouched
        onLiveEdit(stored.key, edited)  // the floating note keeps pace; the disk waits for a pause
        let stored = stored  // `stored.note` is what this card last read or wrote: the merge's "seen"
        saver.call { [weak self] in
            do {
                // Never over a newer file: see Note.merge.
                let toWrite = Note.merge(
                    mine: edited, seen: stored.note, disk: try StoredNote.load(key: stored.key, id: edited.id))
                try stored.save(toWrite)
                self?.stored.note = toWrite
                if toWrite != edited {  // the file's words won: show them, here and on the window
                    self?.card.load(toWrite)
                    self?.onLiveEdit(stored.key, toWrite)
                }
                return true
            } catch {
                self?.onError(error)
                return false
            }
        }
    }

    @discardableResult func flush() -> Bool { saver.flush() }

    /// Adopt a version of this note that came from somewhere else — the floating window. Any
    /// pending save is dropped rather than merged: it is older than what just arrived, and one
    /// note can't be typed in two places at once.
    func apply(_ note: Note) {
        saver.cancel()
        stored.note = note
        card.load(note)
    }

    private func deleteConfirmed() {
        let deletion = card.deletion(keeping: stored.note)
        do {
            try stored.save(deletion)
        } catch {
            onError(error)
            return
        }
        saver.cancel()  // a stale delayed save must not recreate the note that just went
        onLiveEdit(stored.key, deletion)  // and its floating twin goes with it
        onDelete(self)
    }
}

/// The dashboard's page: lets every click through that none of its own views take — the strip
/// behind the search field still drags the dashboard.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A full-width line in the grid: an app — its icon and name — or one place inside it, with
/// a button that goes there.
private final class GridHeading: NSView {
    let app: String
    /// The place this heads; nil for the app's own heading.
    let key: String?

    init(app: String, key: String?, onGo: @escaping (String) -> Void) {
        self.app = app
        self.key = key
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: key == nil ? 22 : 18))
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.autoresizingMask = [.width]
        var x: CGFloat = 0
        if let key {
            let scope = Container.scopeName(for: key)
            label.stringValue = scope == "App" ? "Whole app" : "\(scope) · \(Container.placeName(for: key))"
            label.toolTip = key
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let go = NSButton(title: "Go to", target: nil, action: nil)
            go.isBordered = false
            go.font = .systemFont(ofSize: 11, weight: .medium)
            go.contentTintColor = .controlAccentColor
            go.image = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            go.imagePosition = .imageTrailing
            go.toolTip = "Bring this \(scope == "App" ? "app" : scope.lowercased()) to the front"
            go.sizeToFit()
            go.frame = NSRect(x: bounds.width - go.frame.width, y: 0, width: go.frame.width, height: 18)
            go.autoresizingMask = [.minXMargin]
            addSubview(go)
            onGoAction = { onGo(key) }
            go.target = self
            go.action = #selector(goTapped)
            label.frame = NSRect(x: x, y: 1, width: bounds.width - go.frame.width - 8, height: 16)
        } else {
            let icon = NSImageView(image: Container.revealIcon(for: app))
            icon.frame = NSRect(x: 0, y: 1, width: 20, height: 20)
            addSubview(icon)
            x = 26
            label.stringValue = Container.appName(bundleID: app)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .labelColor
            label.frame = NSRect(x: x, y: 2, width: bounds.width - x, height: 18)
        }
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private var onGoAction: () -> Void = {}
    @objc private func goTapped() { onGoAction() }
}
