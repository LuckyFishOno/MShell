import SwiftUI
import AppKit
import Terminal
import Formats

struct TerminalDisplay: NSViewRepresentable {
    @ObservedObject var tab: SessionTab
    @ObservedObject var model: WorkspaceModel
    final class Coordinator { var revision = -1; var themeID = ""; var request = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let text = TerminalTextView(); text.isEditable = true; text.isSelectable = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isContinuousSpellCheckingEnabled = false; text.allowsUndo = false
        text.isRichText = false; text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 100000, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.input = { bytes in model.sendTerminal(tab, bytes: bytes) }
        text.sizeChanged = { rows, cols in model.resizeTerminal(tab, rows: rows, columns: cols) }
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TerminalTextView else { return }
        view.input = { bytes in model.sendTerminal(tab, bytes: bytes) }
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
        if context.coordinator.revision == tab.screenRevision && context.coordinator.themeID == theme.id { return }

        let background = tab.colorScheme.map { nsColor($0.background) } ?? theme.terminalBackground.nsColor
        let foreground = tab.colorScheme.map { nsColor($0.text) } ?? theme.terminalForeground.nsColor
        let ansi: [NSColor]
        if let scheme = tab.colorScheme {
            ansi = (scheme.normal + scheme.bold).map(nsColor)
        } else {
            ansi = (0..<16).map { theme.terminalANSI($0).nsColor }
        }
        let text = NSMutableAttributedString(string: "")
        let rows = tab.screen.scrollback + (0..<tab.screen.rows).map { row in (0..<tab.screen.cols).map { tab.screen.cell(row: row, col: $0) } }
        for (rowIndex, row) in rows.enumerated() {
            let line = NSMutableAttributedString(string: "")
            for cell in row where cell.width != 0 {
                var cellForeground = color(cell.style.foreground, fallback: foreground, ansi: ansi)
                var cellBackground = color(cell.style.background, fallback: background, ansi: ansi)
                if cell.style.inverse { swap(&cellForeground, &cellBackground) }
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: cell.style.invisible ? cellBackground : cellForeground, .backgroundColor: cellBackground,
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: cell.style.bold ? .bold : .regular)]
                if cell.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if cell.style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                line.append(NSAttributedString(string: String(cell.character), attributes: attributes))
            }
            if let highlights = tab.highlights {
                for match in highlights.matches(in: line.string).matches {
                    let keyword = highlights.keywords[match.keyword]
                    let range = NSRange(location: match.start, length: match.length)
                    if let rgb = highlights.color(index: keyword.textColorIndex) { line.addAttribute(.foregroundColor, value: nsColor(rgb), range: range) }
                    if !keyword.termBackColor, let rgb = highlights.color(index: keyword.backColorIndex) { line.addAttribute(.backgroundColor, value: nsColor(rgb), range: range) }
                    if keyword.bold { line.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), range: range) }
                }
            }
            text.append(line)
            if rowIndex + 1 < rows.count { text.append(NSAttributedString(string: "\n")) }
        }
        view.backgroundColor = background
        scroll.backgroundColor = view.backgroundColor
        view.selectedTextAttributes = [.backgroundColor: theme.selection.nsColor]
        let selection = view.selectedRange()
        view.textStorage?.setAttributedString(text)
        var cursor = 0
        let targetRow = tab.screen.scrollback.count + tab.screen.cursorRow
        for (index, row) in rows.enumerated() {
            if index < targetRow { cursor += row.filter { $0.width != 0 }.reduce(0) { $0 + String($1.character).utf16.count } + 1 }
            else if index == targetRow {
                cursor += row.prefix(tab.screen.cursorCol).filter { $0.width != 0 }.reduce(0) { $0 + String($1.character).utf16.count }; break
            }
        }
        if selection.length == 0 { view.setSelectedRange(NSRange(location: min(cursor, text.length), length: 0)) }
        else if NSMaxRange(selection) <= text.length { view.setSelectedRange(selection) }
        view.insertionPointColor = theme.cursor.nsColor
        context.coordinator.themeID = theme.id
        if context.coordinator.revision != tab.screenRevision {
            context.coordinator.revision = tab.screenRevision
            if selection.length == 0 { view.scrollRangeToVisible(NSRange(location: min(cursor, text.length), length: 0)) }
        }
    }
    private func nsColor(_ rgb: RGB) -> NSColor { NSColor(srgbRed: Double(rgb.red)/255, green: Double(rgb.green)/255, blue: Double(rgb.blue)/255, alpha: 1) }
    private func color(_ value: TerminalColor, fallback: NSColor, ansi: [NSColor]) -> NSColor {
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
    private var lastSize = NSSize.zero
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocus?() } }
        return accepted
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with: event) }
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
    override func layout() {
        super.layout()
        guard let viewport = enclosingScrollView?.contentView.bounds.size, viewport != lastSize else { return }
        lastSize = viewport
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = NSLayoutManager().defaultLineHeight(for: font)
        let rows = Int((viewport.height - 32) / height), cols = Int((viewport.width - 36) / width)
        DispatchQueue.main.async { [weak self] in self?.sizeChanged?(max(5, rows), max(20, cols)) }
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
