import XCTest
import AppKit
@testable import App
import Terminal

@MainActor final class TerminalInputTests: XCTestCase {
    func testSpecialKeysAreRemoteBytes() {
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 36, characters: "", control: false), [13])
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 48, characters: "", control: false), [9])
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 8, characters: "c", control: true), [3])
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 126, characters: "", control: false), Array("\u{1b}[A".utf8))
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 126, characters: "", control: false, applicationCursorKeys: true), Array("\u{1b}OA".utf8))
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 51, characters: "", control: false), [127])
    }
    func testTextViewRoutesCommittedUnicodeAndReturnWithoutLocalEcho() {
        let view = TerminalTextView(); view.inputEnabled = true
        var received: [UInt8] = []; view.input = { received += $0 }
        view.insertText("\u{4f60}\u{597d}", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(received, Array("\u{4f60}\u{597d}".utf8)); XCTAssertEqual(view.string, "")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: event); XCTAssertEqual(received.last, 13)
        view.inputEnabled = false; view.insertText("blocked", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(String(decoding: received, as: UTF8.self).contains("blocked"))
    }
    func testTerminalOnlyHandlesEditShortcutsWhileFocused() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = TerminalTextView(frame: NSRect(x: 0, y: 28, width: 250, height: 72))
        let search = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        window.contentView?.addSubview(terminal)
        window.contentView?.addSubview(search)
        terminal.string = "Terminal output"
        let selectAll = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))

        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertFalse(terminal.performKeyEquivalent(with: selectAll))
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(terminal.performKeyEquivalent(with: selectAll))
        XCTAssertEqual(terminal.selectedRange().length, terminal.string.utf16.count)
    }
    private func cell(_ character: Character, _ style: CellStyle = CellStyle()) -> Cell {
        var cell = Cell.blank; cell.character = character; cell.style = style; return cell
    }
    func testTerminalBlockCursorDoesNotFollowTheTextSelection() {
        let view = TerminalTextView()
        func render(cursorColor: NSColor?) {
            var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16)) { _, fallback, _ in fallback }
            let cells = "prompt>   ".map { cell($0) }
            let line = renderer.line(cells, cursorColumn: 7, cursorColor: cursorColor)
            view.showTerminalLines([line], dropped: 0, firstChanged: 0, cursorLine: 0, cursorColumnOffset: renderer.lastCursorOffset)
        }

        render(cursorColor: .green)
        XCTAssertFalse(view.shouldDrawInsertionPoint)
        XCTAssertEqual(view.terminalInsertionRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(view.textStorage?.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? NSColor, .green)
        let selectedText = NSRange(location: 0, length: 6)
        view.setSelectedRange(selectedText)
        render(cursorColor: .green)
        XCTAssertEqual(view.selectedRange(), selectedText)
        XCTAssertEqual(view.textStorage?.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? NSColor, .green)
        render(cursorColor: nil)
        XCTAssertEqual(view.textStorage?.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? NSColor, .black)
    }
    func testIncrementalTerminalUpdatesMatchAFullRedraw() {
        let view = TerminalTextView()
        func lines(_ texts: [String]) -> [NSAttributedString] { texts.map { NSAttributedString(string: $0) } }
        view.showTerminalLines(lines(["a", "bb", "ccc"]), dropped: 0, firstChanged: 0, cursorLine: 2, cursorColumnOffset: 3)
        XCTAssertEqual(view.string, "a\nbb\nccc")
        // A new line at the bottom; the top line falls out of a full scrollback.
        view.showTerminalLines(lines(["bb", "ccc", "dddd"]), dropped: 1, firstChanged: 2, cursorLine: 2, cursorColumnOffset: 4)
        XCTAssertEqual(view.string, "bb\nccc\ndddd")
        XCTAssertEqual(view.terminalInsertionRange.location, "bb\nccc\ndddd".utf16.count)
        // A change in the middle rewrites from there down; the screen also grows.
        view.showTerminalLines(lines(["bb", "CC", "dddd", "e"]), dropped: 0, firstChanged: 1, cursorLine: 3, cursorColumnOffset: 0)
        XCTAssertEqual(view.string, "bb\nCC\ndddd\ne")
        // Everything replaced.
        view.showTerminalLines(lines(["x"]), dropped: 4, firstChanged: 0, cursorLine: 0, cursorColumnOffset: 1)
        XCTAssertEqual(view.string, "x")
        XCTAssertEqual(view.terminalInsertionRange.location, 1)
    }
    func testRendererMergesCellsThatShareAStyleIntoOneRun() {
        var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16)) { _, fallback, _ in fallback }
        var bold = CellStyle(); bold.bold = true
        let cells = "abc".map { cell($0) } + "de".map { cell($0, bold) }
        let line = renderer.line(cells, cursorColumn: nil, cursorColor: nil)
        XCTAssertEqual(line.string, "abcde")
        var runs = 0
        line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { _, _, _ in runs += 1 }
        XCTAssertEqual(runs, 2)
    }
    func testLocalizationsAreCompleteAndTheSystemLanguageResolves() throws {
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-TW"]), "zh-Hant")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-Hans-CN"]), "zh-Hant", "Every Chinese variant uses the Chinese MShell has")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["ja-JP", "zh-Hant-TW", "en"]), "zh-Hant", "The first shipped language wins")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["en-US"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.from(appleLanguages: ["zh-Hant-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.from(appleLanguages: nil), .system)

        // Both catalogs carry the same keys, and every translation is filled in.
        func catalog(_ code: String) throws -> [String: String] {
            let bundle = try XCTUnwrap(UIStrings.bundles[code])
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"), code)
            return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], code)
        }
        let english = try catalog("en"), chinese = try catalog("zh-Hant")
        XCTAssertGreaterThan(english.count, 100)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for (key, value) in chinese { XCTAssertFalse(value.isEmpty, key) }
        XCTAssertNotEqual(UIStrings.text("Connect", language: .traditionalChinese), "Connect")
        XCTAssertEqual(UIStrings.text("Connect", language: .english), "Connect")
        XCTAssertEqual(UIStrings.text("Not a key", language: .traditionalChinese), "Not a key")
    }
}
