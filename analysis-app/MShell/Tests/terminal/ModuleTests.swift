import XCTest
import CarveShared
@testable import Terminal

final class TerminalFeatureTests: XCTestCase {
    func testDeclaresPlannedInterface() { XCTAssertEqual(TerminalFeature.id, "terminal"); XCTAssertEqual(TerminalFeature.contractSha256, "cb3383995fe3330e86edffddb98ee6ba98bb58c7d2cfb9c708b35e8d0f231431") }
}

final class TerminalScreenTests: XCTestCase {
    func screen(_ rows: Int = 5, _ cols: Int = 10, _ input: String) -> TerminalScreen {
        var o = TerminalOptions(); o.rows = rows; o.cols = cols
        let s = TerminalScreen(options: o); s.feed(input); return s
    }

    func testTextWrapAndScrollback() {
        let s = screen(3, 5, "hello world\r\nline3\r\nline4")
        // "hello world" wraps as "hello" / " worl" / "d".
        XCTAssertEqual(s.lines, ["d", "line3", "line4"])
        XCTAssertEqual(s.scrollback.count, 2)
        XCTAssertEqual(s.cursorRow, 2); XCTAssertEqual(s.cursorCol, 4)
    }

    func testDeferredWrapAtLastColumn() {
        let s = screen(3, 5, "abcde")
        XCTAssertEqual(s.cursorRow, 0); XCTAssertEqual(s.cursorCol, 4)
        s.feed("\r\nx")
        XCTAssertEqual(s.lines, ["abcde", "x", ""])
    }

    func testCursorMovementAndErase() {
        let s = screen(3, 10, "0123456789\u{1B}[2;3HXY\u{1B}[1;5H\u{1B}[K")
        XCTAssertEqual(s.lines, ["0123", "  XY", ""])
        s.feed("\u{1B}[2J")
        XCTAssertEqual(s.lines, ["", "", ""])
    }

    func testInsertDeleteCharsAndLines() {
        let s = screen(3, 6, "abcdef\u{1B}[1;2H\u{1B}[2P")
        XCTAssertEqual(s.lineText(0), "adef")
        s.feed("\u{1B}[1@")
        XCTAssertEqual(s.lineText(0), "a def")
        s.feed("\u{1B}[2;1Hrow2\u{1B}[1;1H\u{1B}[1L")
        XCTAssertEqual(s.lines, ["", "a def", "row2"])
        s.feed("\u{1B}[1M")
        XCTAssertEqual(s.lines, ["a def", "row2", ""])
    }

    func testSGRColors() {
        let s = screen(1, 10, "\u{1B}[1;31mA\u{1B}[38;5;200mB\u{1B}[48;2;1;2;3mC\u{1B}[0mD")
        XCTAssertEqual(s.cell(row: 0, col: 0).style.foreground, .indexed(1))
        XCTAssertTrue(s.cell(row: 0, col: 0).style.bold)
        XCTAssertEqual(s.cell(row: 0, col: 1).style.foreground, .indexed(200))
        XCTAssertEqual(s.cell(row: 0, col: 2).style.background, .rgb(.init(red: 1, green: 2, blue: 3)))
        XCTAssertEqual(s.cell(row: 0, col: 3).style, CellStyle())
    }

    func testScrollRegion() {
        let s = screen(4, 5, "top\r\n\u{1B}[2;3r\u{1B}[2;1Ha\r\nb\r\nc\r\nd")
        XCTAssertEqual(s.lines[0], "top")
        XCTAssertEqual(Array(s.lines[1...2]), ["c", "d"])
        XCTAssertEqual(s.scrollback.count, 0, "region scrolling does not feed scrollback")
    }

    func testAlternateScreenRestoresPrimary() {
        let s = screen(2, 5, "main\u{1B}[?1049h\u{1B}[Hvim")
        XCTAssertEqual(s.lineText(0), "vim")
        s.feed("\u{1B}[?1049l")
        XCTAssertEqual(s.lineText(0), "main")
        XCTAssertEqual(s.cursorCol, 4)
    }

    func testWideCJKAndAmbiguousOption() {
        let s = screen(1, 6, "中文a")
        XCTAssertEqual(s.lineText(0), "中文a")
        XCTAssertEqual(s.cursorCol, 5)
        var o = TerminalOptions(); o.rows = 1; o.cols = 6; o.cjkAmbiguousAsWide = true
        let w = TerminalScreen(options: o); w.feed("αb")
        XCTAssertEqual(w.cursorCol, 3)
        let wrap = screen(2, 3, "ab中")
        XCTAssertEqual(wrap.lines, ["ab", "中"], "a wide char that does not fit wraps")
    }

    func testOSCTitleBellRepliesAndUnsupported() {
        let s = screen(2, 10, "\u{1B}]0;my host\u{07}\u{07}\u{1B}[6n\u{1B}[?9999h\u{1B}Z")
        XCTAssertEqual(s.title, "my host")
        XCTAssertEqual(s.takeEvents(), [.title("my host"), .bell, .reply(Array("\u{1B}[1;1R".utf8))])
        XCTAssertEqual(s.unsupported["DECSET 9999"], 1)
        XCTAssertEqual(s.unsupported["ESC Z"], 1)
    }

    func testSplitUTF8AndEscapeAcrossFeeds() {
        let s = screen(1, 10, "")
        for b in Array("é\u{1B}[31mx".utf8) { s.feed([b]) }
        XCTAssertEqual(s.lineText(0), "éx")
        XCTAssertEqual(s.cell(row: 0, col: 1).style.foreground, .indexed(1))
    }

    func testCursorKeysBackspaceAndLineDrawing() {
        var o = TerminalOptions(); o.applicationCursorKeys = true; o.backspaceSendsDelete = false
        let s = TerminalScreen(options: o)
        XCTAssertEqual(s.cursorKey("A"), Array("\u{1B}OA".utf8))
        XCTAssertEqual(s.backspaceBytes, [0x08])
        s.feed("\u{1B}[?1l\u{1B}(0lqk\u{1B}(B")
        XCTAssertEqual(s.cursorKey("A"), Array("\u{1B}[A".utf8))
        XCTAssertEqual(s.lineText(0), "┌─┐")
    }

    func testResizeKeepsCursorLine() {
        let s = screen(4, 6, "a\r\nb\r\nc\r\nd")
        s.resize(rows: 2, cols: 3)
        XCTAssertEqual(s.lines, ["c", "d"])
        XCTAssertEqual(s.cursorRow, 1)
        XCTAssertEqual(s.scrollback.map { $0.map { String($0.character) }.joined().trimmingCharacters(in: .whitespaces) }, ["a", "b"])
    }

    func testFeatureEntry() throws {
        let r = try TerminalFeature.run(FeatureRequest(payload: #"{"rows":2,"cols":8,"input":"hi\r\n\u001b[1mthere"}"#), dependencies: FeatureOutputs([:]))
        XCTAssertTrue(r.payload.contains(#""lines":["hi","there"]"#), r.payload)
    }
}
