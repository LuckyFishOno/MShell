import XCTest
import CarveShared
@testable import Profiles
import Formats

final class ProfilesFeatureTests: XCTestCase {
    func testDeclaresPlannedInterface() { XCTAssertEqual(ProfilesFeature.id, "profiles"); XCTAssertEqual(ProfilesFeature.contractSha256, "15eeb0817f41b3cc959114bad8f89ff5f7b1457987244378de9249f50b942490") }

    // Synthetic .xsh built from the key names found in XshellCore.exe. The real section layout is unverified.
    static let sampleXsh = """
    [SessionInfo]\r
    Host=example.com\r
    Port=2222\r
    Protocol=SSH\r
    UserName=alice\r
    [Connection]\r
    AuthMethod=Password\r
    KeepAlive=1\r
    [Terminal]\r
    Rows=40\r
    Cols=132\r
    Encoding=UTF-8\r
    Terminal=xterm\r
    ScrollbackSize=5000\r
    [Appearance]\r
    ColorScheme=XTerm\r
    FontFace=Menlo\r
    FontSize=12\r
    """

    func data(_ s: String, bom: Bool) -> Data { bom ? Data([0xFF, 0xFE]) + s.data(using: .utf16LittleEndian)! : Data(s.utf8) }

    func testParsesWellKnownKeysFromBothEncodings() throws {
        for bom in [false, true] {
            let p = try SessionProfile(data: data(Self.sampleXsh, bom: bom), name: "work")
            XCTAssertEqual(p.name, "work")
            XCTAssertEqual(p.connection.host, "example.com")
            XCTAssertEqual(p.connection.port, 2222)
            XCTAssertEqual(p.connection.userName, "alice")
            XCTAssertEqual(p.resolvedProtocol, .ssh)
            XCTAssertEqual(p.terminal.rows, 40)
            XCTAssertEqual(p.terminal.cols, 132)
            XCTAssertEqual(p.terminal.encoding, "UTF-8")
            XCTAssertEqual(p.terminal.scrollbackSize, 5000)
            XCTAssertTrue(p.terminal.keepAlive)
            XCTAssertEqual(p.appearance.colorScheme, "XTerm")
            XCTAssertEqual(p.appearance.fontFace, "Menlo")
            XCTAssertEqual(p.sections.map(\.name), ["SessionInfo", "Connection", "Terminal", "Appearance"])
            XCTAssertEqual(p.value(section: "Terminal", "Cols"), "132")
        }
    }

    func testDefaultsAndUnknownProtocol() throws {
        let p = try SessionProfile(data: data("[SessionInfo]\r\nHost=h\r\nProtocol=MOSH\r\n", bom: false), name: "x")
        XCTAssertEqual(p.connection.port, 22, "default SSH port")
        XCTAssertEqual(p.terminal.rows, 24)
        XCTAssertEqual(p.resolvedProtocol, .other)
    }

    func testEmptyFileIsRejected() {
        XCTAssertThrowsError(try SessionProfile(data: Data(), name: "x")) { XCTAssertEqual($0 as? XshellFormatError, .missingSection("SessionInfo")) }
    }

    func testFolderLoadCollectsFailures() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("carve-profiles-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try data(Self.sampleXsh, bom: true).write(to: dir.appendingPathComponent("a.xsh"))
        try data("[SessionInfo]\r\nHost=b\r\n", bom: false).write(to: sub.appendingPathComponent("b.xsh"))
        try Data().write(to: dir.appendingPathComponent("broken.xsh"))
        try data("ignore me", bom: false).write(to: dir.appendingPathComponent("notes.txt"))
        let (tree, failed) = try SessionFolder.load(dir)
        XCTAssertEqual(tree.allSessions.map(\.connection.host).sorted(), ["b", "example.com"])
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.0.lastPathComponent, "broken.xsh")
    }

    func testFeatureEntry() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("carve-pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.xsh")
        try data(Self.sampleXsh, bom: true).write(to: file)
        let r = try ProfilesFeature.run(FeatureRequest(payload: #"{"path":"\#(file.path)"}"#), dependencies: FeatureOutputs([:]))
        XCTAssertTrue(r.payload.contains(#""host":"example.com""#), r.payload)
        XCTAssertTrue(r.payload.contains(#""protocol":"SSH""#))
    }
}
