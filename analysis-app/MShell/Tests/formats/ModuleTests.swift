import XCTest
import CarveShared
@testable import Formats

final class FormatTests: XCTestCase {
    private func installedSamples() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["XSHELL_DIR"], !path.isEmpty else {
            throw XCTSkip("Set XSHELL_DIR to run the installed-sample tests.")
        }
        return URL(fileURLWithPath: path)
    }

    func testAllBundledColorSchemesParseAndRoundTripByteForByte() throws {
        let dir = try installedSamples().appendingPathComponent("ColorSchemes")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "scs" }), !files.isEmpty else { throw XCTSkip("no installed color schemes") }
        XCTAssertEqual(files.count, 20)
        var exact = 0
        for f in files {
            let data = try Data(contentsOf: f), s = try ColorScheme(contentsOf: f)
            XCTAssertEqual(s.ansiPalette.count, 16)
            XCTAssertEqual(try ColorScheme(data: s.encoded(), name: s.name), s, f.lastPathComponent)
            if s.encoded() == data { exact += 1 }
        }
        print("XSHELL-SCS exact-byte round trips: \(exact)/\(files.count)")
        XCTAssertEqual(exact, files.count)
    }

    func testKnownSchemeValues() throws {
        let f = try installedSamples().appendingPathComponent("ColorSchemes/ANSI Colors on Black.scs")
        guard FileManager.default.fileExists(atPath: f.path) else { throw XCTSkip("missing") }
        let s = try ColorScheme(contentsOf: f)
        XCTAssertEqual(s.name, "ANSI Colors on Black")
        XCTAssertEqual(s.encoding, .utf16LittleEndianBOM)
        print("XSHELL-SCS sample:", s.background.hex, s.text.hex, s.normal.map(\.hex), s.bold.map(\.hex))
    }

    func testBundledKeyMap() throws {
        let f = try installedSamples().appendingPathComponent("example.tkm")
        guard FileManager.default.fileExists(atPath: f.path) else { throw XCTSkip("missing") }
        let m = try TerminalKeyMap(contentsOf: f)
        XCTAssertEqual(m.bindings.count, 24)
        XCTAssertEqual(m.binding("F1")?.output, .sequence([0x1B, 0x4F, 0x50]))
        XCTAssertEqual(m.binding("F10")?.output, .sequence(Array("\u{1B}Oy".utf8)))
        XCTAssertEqual(m.binding("F11")?.output, .named("F11"))
        XCTAssertEqual(m.binding("S_F3")?.output, .named("Shift+F3"))
        XCTAssertEqual(m.encoded(), try Data(contentsOf: f), "exact-byte round trip")
    }

    func testDeclaresPlannedInterface() {
        XCTAssertEqual(FormatsFeature.id, "formats")
        XCTAssertEqual(FormatsFeature.contractSha256, "5bd8ffb27b6d098e8a8a4351fd0313592fafe61a008d29940a8a9d0dbc3fdc74")
    }

    func testFeatureEntryOnRealScheme() throws {
        let f = try installedSamples().appendingPathComponent("ColorSchemes/XTerm.scs")
        guard FileManager.default.fileExists(atPath: f.path) else { throw XCTSkip("missing") }
        let r = try FormatsFeature.run(FeatureRequest(payload: "{\"kind\":\"scs\",\"path\":\"\(f.path)\"}"), dependencies: FeatureOutputs([:]))
        XCTAssertTrue(r.payload.contains("\"name\":\"XTerm\""))
    }

    func testSyntheticInputsAndRefusals() throws {
        XCTAssertEqual(try TerminalKeyMap.output("^A^?x"), .sequence([0x01, 0x7F, 0x78]))
        XCTAssertThrowsError(try TerminalKeyMap.output("abc^")) { XCTAssertEqual($0 as? XshellFormatError, .invalidCaretSequence("abc^")) }
        XCTAssertThrowsError(try ColorScheme(data: Data("[Color Scheme]\r\ntext=zzzzzz\r\n".utf8), name: "x")) { XCTAssertEqual($0 as? XshellFormatError, .invalidColor(key: "text", value: "zzzzzz")) }
        XCTAssertThrowsError(try ColorScheme(data: Data("[Other]\r\n".utf8), name: "x")) { XCTAssertEqual($0 as? XshellFormatError, .missingSection("Color Scheme")) }
        let g = (0..<8).map { RGB(red: UInt8($0), green: 0, blue: 0) }
        var s = ColorScheme(name: "n", text: RGB(hex: "ffffff")!, boldText: RGB(hex: "ffffff")!, background: RGB(hex: "000000")!, normal: g, bold: g)
        s.encoding = .utf8
        XCTAssertEqual(try ColorScheme(data: s.encoded(), name: "n"), s)
        XCTAssertEqual(try ColorScheme(data: { var x = s; x.encoding = .utf16LittleEndianBOM; return x.encoded() }(), name: "n"), s)
    }
}
