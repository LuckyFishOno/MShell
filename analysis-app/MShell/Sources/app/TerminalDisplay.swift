import SwiftUI
import AppKit
import Terminal
import Formats

struct TerminalDisplay: NSViewRepresentable {
    @ObservedObject var tab: SessionTab
    @ObservedObject var model: WorkspaceModel
    final class Coordinator {
        var revision = -1
        var themeID = ""
        var request = -1
        var cursorVisible = false
        /// The rows and attributed lines on screen, reused for rows that have not changed.
        var rows: [[Cell]] = []
        var lines: [NSAttributedString] = []
        var cursorLine: Int?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        // Rows never exceed the terminal width, so there is no horizontal scroller, and the vertical one
        // is an overlay that only appears while scrolling.
        let scroll = TerminalScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.drawsBackground = true
        let text = TerminalTextView(); text.isEditable = true; text.isSelectable = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isContinuousSpellCheckingEnabled = false; text.allowsUndo = false
        text.isRichText = false; text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 100000, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 18, height: 16)
        // Lay out only the visible part of a long scrollback.
        text.layoutManager?.allowsNonContiguousLayout = true
        text.input = { bytes in model.typeTerminal(tab, bytes: bytes) }
        text.sizeChanged = { rows, cols in model.resizeTerminal(tab, rows: rows, columns: cols) }
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TerminalTextView else { return }
        view.input = { bytes in model.typeTerminal(tab, bytes: bytes) }
        view.sizeChanged = { rows, cols in model.resizeTerminal(tab, rows: rows, columns: cols) }
        view.onFocus = { [weak model, weak tab] in
            guard let model, let tab, model.split?.contains(tab.id) == true, model.selection != tab.id else { return }
            model.selectTab(tab.id, focusTerminal: false)
        }
        if context.coordinator.request != tab.terminalFocusRequest {
            context.coordinator.request = tab.terminalFocusRequest
            DispatchQueue.main.async { [weak model, weak tab, weak view] in
                guard let model, let tab, let view else { return }
                let workspaceTab = model.tabs.contains { $0.id == tab.id }
                if !workspaceTab || model.selection == tab.id { view.window?.makeFirstResponder(view) }
            }
        }
        view.applicationCursorKeys = tab.screen.applicationCursorKeys
        view.bracketedPaste = tab.screen.bracketedPaste
        view.inputEnabled = tab.terminalReady
        let theme = model.theme
        let cursorVisible = tab.terminalReady && tab.screen.cursorVisible
        if context.coordinator.revision == tab.screenRevision && context.coordinator.themeID == theme.id
            && context.coordinator.cursorVisible == cursorVisible { return }

        let background = tab.colorScheme.map { nsColor($0.background) } ?? theme.terminalBackground.nsColor
        let foreground = tab.colorScheme.map { nsColor($0.text) } ?? theme.terminalForeground.nsColor
        let ansi: [NSColor]
        if let scheme = tab.colorScheme {
            ansi = (scheme.normal + scheme.bold).map(nsColor)
        } else {
            ansi = (0..<16).map { theme.terminalANSI($0).nsColor }
        }
        let coordinator = context.coordinator
        let screen = tab.screen
        let rows = screen.scrollback + (0..<screen.rows).map { row in (0..<screen.cols).map { screen.cell(row: row, col: $0) } }
        let cursorLine = screen.scrollback.count + screen.cursorRow
        let cursorColor = cursorVisible ? theme.cursor.nsColor : nil
        if coordinator.themeID != theme.id { coordinator.rows = []; coordinator.lines = []; coordinator.cursorLine = nil }

        // Rows only change at the bottom, and scrollback drops lines from the top once it is full.
        // Find how many old lines fell off the top, then reuse every unchanged row after that.
        let old = coordinator.rows
        var dropped = 0
        if let firstRow = rows.first, !old.isEmpty, old[0] != firstRow {
            dropped = old.indices.dropFirst().prefix(screen.scrollback.count).first { old[$0] == firstRow } ?? old.count
        }
        let oldCursor = coordinator.cursorLine.map { $0 - dropped }
        var renderer = TerminalLineRenderer(background: background, foreground: foreground, ansi: ansi, color: color)
        var lines: [NSAttributedString] = []; lines.reserveCapacity(rows.count)
        var firstChanged = rows.count
        for (index, row) in rows.enumerated() {
            let oldIndex = dropped + index
            let isCursorLine = index == cursorLine || index == oldCursor
            if !isCursorLine, oldIndex < old.count, old[oldIndex] == row {
                lines.append(coordinator.lines[oldIndex]); continue
            }
            firstChanged = min(firstChanged, index)
            let line = renderer.line(row, cursorColumn: index == cursorLine ? screen.cursorCol : nil, cursorColor: cursorColor)
            if let highlights = tab.highlights {
                for match in highlights.matches(in: line.string).matches {
                    let keyword = highlights.keywords[match.keyword]
                    let range = NSRange(location: match.start, length: match.length)
                    if let rgb = highlights.color(index: keyword.textColorIndex) { line.addAttribute(.foregroundColor, value: nsColor(rgb), range: range) }
                    if !keyword.termBackColor, let rgb = highlights.color(index: keyword.backColorIndex) { line.addAttribute(.backgroundColor, value: nsColor(rgb), range: range) }
                    if keyword.bold { line.addAttribute(.font, value: TerminalLineRenderer.boldFont, range: range) }
                }
            }
            lines.append(line)
        }
        if rows.count != old.count - dropped { firstChanged = min(firstChanged, min(rows.count, max(old.count - dropped, 0))) }
        view.backgroundColor = background
        scroll.backgroundColor = view.backgroundColor
        view.selectedTextAttributes = [.backgroundColor: theme.selection.nsColor]
        view.showTerminalLines(lines, dropped: dropped, firstChanged: firstChanged, cursorLine: cursorLine,
                               cursorColumnOffset: renderer.lastCursorOffset)
        coordinator.rows = rows; coordinator.lines = lines; coordinator.cursorLine = cursorLine
        coordinator.themeID = theme.id
        coordinator.cursorVisible = cursorVisible
        if coordinator.revision != tab.screenRevision {
            coordinator.revision = tab.screenRevision
            if view.selectedRange().length == 0 { view.scrollRangeToVisible(view.terminalInsertionRange) }
        }
    }
    private func nsColor(_ rgb: RGB) -> NSColor { Self.nsColor(rgb) }
    fileprivate static func nsColor(_ rgb: RGB) -> NSColor { NSColor(srgbRed: Double(rgb.red)/255, green: Double(rgb.green)/255, blue: Double(rgb.blue)/255, alpha: 1) }
    private var color: (TerminalColor, NSColor, [NSColor]) -> NSColor { Self.color }
    private static func color(_ value: TerminalColor, fallback: NSColor, ansi: [NSColor]) -> NSColor {
        switch value {
        case .default: return fallback
        case .rgb(let rgb): return nsColor(rgb)
        case .indexed(let index):
            let n = Int(index)
            if n < 16 { return ansi[n] }
            if n >= 232 { return NSColor(white: Double(8 + (n-232)*10)/255, alpha: 1) }
            let i = n - 16, levels = [0.0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: levels[i/36]/255, green: levels[(i/6)%6]/255, blue: levels[i%6]/255, alpha: 1)
        }
    }
}


/// The remote PTY owns echo, line editing and history. Local edits never modify its transcript.
final class TerminalTextView: NSTextView {
    var input: (([UInt8]) -> Void)?
    var onFocus: (() -> Void)?
    var sizeChanged: ((Int, Int) -> Void)?
    var inputEnabled = false
    var applicationCursorKeys = false
    var bracketedPaste = false
    private(set) var terminalInsertionRange = NSRange(location: 0, length: 0)
    private var lastSize = NSSize.zero
    override var acceptsFirstResponder: Bool { true }
    override var shouldDrawInsertionPoint: Bool { false }
    // Dropping a tab on the terminal splits the pane, so the text view must not take drops itself.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func updateDragTypeRegistration() { unregisterDraggedTypes() }

    /// UTF-16 length of each line on screen, so an update can find where its first changed line starts.
    private var lineLengths: [Int] = []

    /// Replaces only what changed: lines that scrolled off the top, then everything from the first
    /// changed line down. Untouched lines keep their layout, which keeps long scrollback cheap.
    func showTerminalLines(_ lines: [NSAttributedString], dropped: Int, firstChanged: Int, cursorLine: Int, cursorColumnOffset: Int?) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        storage.beginEditing()
        var lengths = lineLengths
        var removedFromTop = 0
        if dropped > 0, dropped <= lengths.count {
            removedFromTop = lengths.prefix(dropped).reduce(0, +) + min(dropped, max(lengths.count - 1, 0))
            if dropped == lengths.count { removedFromTop = storage.length }
            storage.deleteCharacters(in: NSRange(location: 0, length: min(removedFromTop, storage.length)))
            lengths.removeFirst(dropped)
        } else if dropped > lengths.count {
            lengths = []
        }
        let kept = min(firstChanged, lengths.count, lines.count)
        let start = kept == 0 ? 0 : lengths.prefix(kept).reduce(0, +) + kept - 1
        let tail = NSMutableAttributedString()
        for index in kept..<lines.count {
            if index > 0 { tail.append(Self.newline) }
            tail.append(lines[index])
        }
        storage.replaceCharacters(in: NSRange(location: min(start, storage.length), length: storage.length - min(start, storage.length)), with: tail)
        storage.endEditing()
        lineLengths = lines.map(\.length)
        let cursorStart = lineLengths.prefix(min(cursorLine, lineLengths.count)).reduce(0, +) + min(cursorLine, lineLengths.count)
        terminalInsertionRange = NSRange(location: min(cursorStart + (cursorColumnOffset ?? lineLengths[safe: cursorLine] ?? 0), storage.length), length: 0)
        let shifted = NSRange(location: selection.location - removedFromTop, length: selection.length)
        setSelectedRange(selection.length > 0 && shifted.location >= 0 && NSMaxRange(shifted) <= storage.length ? shifted : terminalInsertionRange)
    }
    private static let newline = NSAttributedString(string: "\n")

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocus?() } }
        return accepted
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        if selectedRange().length == 0 { setSelectedRange(terminalInsertionRange) }
    }
    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if let bytes = TerminalKeyboard.bytes(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", control: event.modifierFlags.contains(.control), applicationCursorKeys: applicationCursorKeys) { input?(bytes); return }
        interpretKeyEvents([event])
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard inputEnabled else { return }
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        unmarkText(); input?(Array(text.utf8))
    }
    override func cut(_ sender: Any?) { copy(sender) }
    override func paste(_ sender: Any?) {
        guard inputEnabled, let text = NSPasteboard.general.string(forType: .string) else { return }
        guard let bytes = TerminalKeyboard.pasteBytes(text, bracketed: bracketedPaste) else { NSSound.beep(); return }
        input?(bytes)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": paste(nil); return true
            case "c", "x": copy(nil); return true
            case "a": selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    private static let cellWidth = ("M" as NSString).size(withAttributes: [.font: TerminalLineRenderer.regularFont]).width
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: TerminalLineRenderer.regularFont)
    private var pendingResize: DispatchWorkItem?

    /// Resizing the terminal redraws it and makes the shell repaint, so wait until the size settles:
    /// the end of a window resize, or a short pause while panes and sidebars move.
    override func layout() {
        super.layout()
        guard let viewport = enclosingScrollView?.contentView.bounds.size, viewport != lastSize else { return }
        lastSize = viewport
        pendingResize?.cancel()
        guard !inLiveResize else { return }
        let rows = Int((viewport.height - 32) / Self.lineHeight), cols = Int((viewport.width - 36) / Self.cellWidth)
        let work = DispatchWorkItem { [weak self] in self?.sizeChanged?(max(5, rows), max(20, cols)) }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        lastSize = .zero
        needsLayout = true
    }
    override func doCommand(by selector: Selector) { }
}

public enum TerminalKeyboard {
    static func pasteBytes(_ text: String, bracketed: Bool) -> [UInt8]? {
        var payload = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        if bracketed {
            // An embedded escape must not allow pasted text to close the bracket early.
            payload = payload.replacingOccurrences(of: "\u{1b}", with: "")
            payload = "\u{1b}[200~" + payload + "\u{1b}[201~"
        }
        guard payload.utf8.count <= 262_144 else { return nil }
        return Array(payload.utf8)
    }


    public static func bytes(keyCode: UInt16, characters: String, control: Bool, applicationCursorKeys: Bool = false) -> [UInt8]? {
        if control, let value = characters.lowercased().unicodeScalars.first?.value, (0x40...0x7f).contains(value) || value == 0x20 { return [UInt8(value & 0x1f)] }
        let arrow = applicationCursorKeys ? "\u{1b}O" : "\u{1b}["
        let value: String
        switch keyCode {
        case 36, 76: value = "\r"
        case 48: value = "\t"
        case 51: value = "\u{7f}"
        case 53: value = "\u{1b}"
        case 123: value = arrow + "D"
        case 124: value = arrow + "C"
        case 125: value = arrow + "B"
        case 126: value = arrow + "A"
        case 115: value = "\u{1b}[H"
        case 119: value = "\u{1b}[F"
        case 116: value = "\u{1b}[5~"
        case 121: value = "\u{1b}[6~"
        case 117: value = "\u{1b}[3~"
        default: return nil
        }
        return Array(value.utf8)
    }
}


/// A scroll view whose scrollers always overlay the text and fade out, whatever the system setting,
/// so no scroll bar appears in a terminal that is not being scrolled.
final class TerminalScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

/// Builds one attributed line per terminal row. Cells that share a style become a single run, and
/// fonts and attribute dictionaries are reused, so drawing costs a few allocations per style change
/// instead of one per cell.
struct TerminalLineRenderer {
    static let regularFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    let background: NSColor
    let foreground: NSColor
    let ansi: [NSColor]
    let color: (TerminalColor, NSColor, [NSColor]) -> NSColor
    private var cache: [CellStyle: [NSAttributedString.Key: Any]] = [:]
    /// UTF-16 offset of the cursor within the last line built with a cursor column.
    private(set) var lastCursorOffset: Int?

    init(background: NSColor, foreground: NSColor, ansi: [NSColor], color: @escaping (TerminalColor, NSColor, [NSColor]) -> NSColor) {
        self.background = background; self.foreground = foreground; self.ansi = ansi; self.color = color
    }

    mutating func attributes(_ style: CellStyle) -> [NSAttributedString.Key: Any] {
        if let cached = cache[style] { return cached }
        var cellForeground = color(style.foreground, foreground, ansi)
        var cellBackground = color(style.background, background, ansi)
        if style.inverse { swap(&cellForeground, &cellBackground) }
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.invisible ? cellBackground : cellForeground,
            .backgroundColor: cellBackground, .font: style.bold ? Self.boldFont : Self.regularFont]
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        cache[style] = attributes
        return attributes
    }

    mutating func line(_ cells: [Cell], cursorColumn: Int?, cursorColor: NSColor?) -> NSMutableAttributedString {
        let line = NSMutableAttributedString()
        var run = "", runStyle: CellStyle?, length = 0
        var cursor: NSRange?
        func flush() {
            guard let style = runStyle, !run.isEmpty else { return }
            line.append(NSAttributedString(string: run, attributes: attributes(style)))
            run = ""
        }
        for (column, cell) in cells.enumerated() where cell.width != 0 {
            let glyph = String(cell.character), glyphLength = glyph.utf16.count
            if let cursorColumn, (column..<(column + Int(cell.width))).contains(cursorColumn) {
                cursor = NSRange(location: length, length: glyphLength)
            }
            if cell.style != runStyle { flush(); runStyle = cell.style }
            run += glyph; length += glyphLength
        }
        flush()
        if cursorColumn != nil { lastCursorOffset = cursor?.location ?? length }
        if let cursor, let cursorColor {
            let under = line.attribute(.backgroundColor, at: cursor.location, effectiveRange: nil) as? NSColor ?? background
            line.addAttributes([.backgroundColor: cursorColor, .foregroundColor: under], range: cursor)
        }
        return line
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
