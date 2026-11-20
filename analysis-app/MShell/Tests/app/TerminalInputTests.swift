import XCTest
import AppKit
@testable import App

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
    func testBothChineseCatalogsHaveCompleteUIKeysAndSystemResolution() throws {
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-TW"]), "zh-Hant")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["en-US"]), "en")
        XCTAssertGreaterThan(UIStrings.table.count, 100)
        for (key, translations) in UIStrings.table {
            XCTAssertFalse(try XCTUnwrap(translations["zh-Hant"], key).isEmpty)
            XCTAssertFalse(try XCTUnwrap(translations["zh-Hans"], key).isEmpty)
        }
        XCTAssertNotEqual(UIStrings.text("Connect", language: .traditionalChinese), "Connect")
        XCTAssertNotEqual(UIStrings.text("Connect", language: .simplifiedChinese), "Connect")
    }
}
