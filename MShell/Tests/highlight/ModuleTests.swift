import XCTest
import CarveShared
@testable import Highlight

final class HighlightFeatureTests: XCTestCase {
    func testDeclaresPlannedInterface() { XCTAssertEqual(HighlightFeature.id, "highlight"); XCTAssertEqual(HighlightFeature.contractSha256, "c69bc213e79252eddd5ba698c7e4c69c1b55703c9ef3e1d96db1e7bdfbd89aef") }

    func testBundledSampleParsesAndMatches() throws {
        guard let path = ProcessInfo.processInfo.environment["XSHELL_DIR"], !path.isEmpty else {
            throw XCTSkip("Set XSHELL_DIR to run the installed-sample test.")
        }
        let sample = URL(fileURLWithPath: path).appendingPathComponent("HighlightSample/New Highlight Set (Sample).hls")
        guard FileManager.default.fileExists(atPath: sample.path) else { throw XCTSkip("missing") }
        let s = try HighlightSet(contentsOf: sample)
        XCTAssertEqual(s.version, "1.1")
        XCTAssertEqual(s.keywords.map(\.description), ["Phone number", "IP adress", "Email address", "Only number", "Space"])
        XCTAssertEqual(s.palette.count, 16)
        XCTAssertEqual(s.keywords[0].textColorIndex, 281)
        XCTAssertTrue(s.keywords[0].bold && s.keywords[1].italic && s.keywords[2].underline && s.keywords[3].strikeout)
        let line = "call 555-123-4567 or ping 10.0.0.1"
        let r = s.matches(in: line)
        XCTAssertEqual(r.invalid, [])
        XCTAssertTrue(r.matches.contains(HighlightSet.Match(keyword: 0, start: 5, length: 12)))
        XCTAssertTrue(r.matches.contains(HighlightSet.Match(keyword: 1, start: 26, length: 8)))
        XCTAssertEqual(r.matches.filter { $0.keyword == 4 }.count, 4, "four spaces")
    }

    func testInvalidRegexIsReportedNotThrown() throws {
        let hls = "[Keyword_0]\r\nKeyword=([\r\nUseRegex=1\r\nEnable=1\r\n[Colors]\r\nColors=000000\r\n[info]\r\nCount=1\r\n"
        let s = try HighlightSet(data: Data(hls.utf8), name: "x")
        XCTAssertEqual(s.matches(in: "abc").invalid, [0])
    }
}
