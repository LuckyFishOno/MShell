import XCTest
import Network
@testable import App

/// Importing sessions from MobaXterm, PuTTY, CSV, and MShell's own export, and exporting them back out.
@MainActor final class SessionExchangeTests: XCTestCase {
    private func store() throws -> SessionTreeStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exchange-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try SessionTreeStore(url: dir.appendingPathComponent("sessions.json"))
    }

    private func entry(_ draft: ProfileImport, _ path: String) throws -> ProfileImport.Entry {
        try XCTUnwrap(draft.entries.first { $0.path == path }, "No entry \(path) in \(draft.entries.map(\.path))")
    }

    func testMobaXtermSessionsKeepFoldersGatewaysAndProxiesAndSkipOtherTypes() throws {
        let text = """
        [Bookmarks]\r
        SubRep=\r
        ImgNum=42\r
        web=#109#0%web.example.com%2222%deploy%%-1%-1%%%%%0%0%0%_CurrentDrive_:\\keys\\web.ppk%%-1%0%0%0%%1080%%0%0%1#MobaFont%10%0%0%-1%15%236,236,236%30,30,30%180,180,192%0%-1%0%%xterm%-1%-1%_Std_Colors_0_%80%24%0%1%-1%<none>%%0%0%-1#0# #-1\r
        desktop=#91#4%win.example.com%3389%%-1%0%0%0%-1%0%0%-1#MobaFont%10#0# #-1\r
        \r
        [Bookmarks_1]\r
        SubRep=Prod\\DB\r
        ImgNum=41\r
        db=#109#0%10.0.0.5%22%postgres%%-1%-1%%bastion.example.com__PIPE__inner.example.com%22__PIPE__2200%jump__PIPE__%%0%0%%%-1%0%0%0%%1080%%0%0%1#MobaFont%10#0# #-1\r
        proxied=#109#0%behind.example.com%22%<default>%%-1%-1%%%%%0%-1%0%%%-1%0%0%2%proxy.example.com%1080%%0%0%1#MobaFont%10#0# #-1\r
        files=#140#7%files.example.com%22%ftp%-1%0%%0%-1%%0%%%%%%-1#MobaFont%10#0# #-1\r
        """
        let draft = try MobaXtermImport.parse(text, name: "MobaXterm", localUser: "me")
        let web = try entry(draft, "web")
        XCTAssertEqual(web.connection.host, "web.example.com")
        XCTAssertEqual(web.connection.port, 2222)
        XCTAssertEqual(web.connection.username, "deploy")
        XCTAssertNil(web.connection.identityPath, "A Windows key path is not usable on the Mac")
        XCTAssertTrue(web.notes.contains { $0.contains("key file on Windows") })

        XCTAssertEqual(draft.folders.first, ["Prod"])
        XCTAssertTrue(draft.folders.contains(["Prod", "DB"]))
        let db = try entry(draft, "Prod / DB / db")
        XCTAssertEqual(db.jump, ["Jump hosts", "postgres@inner.example.com:2200"],
                       "The last gateway reaches the session; a gateway without a user uses the session's")
        let inner = try entry(draft, "Jump hosts / postgres@inner.example.com:2200")
        XCTAssertEqual(inner.jump, ["Jump hosts", "jump@bastion.example.com"], "Gateways chain first to last")
        XCTAssertEqual(try entry(draft, "Jump hosts / jump@bastion.example.com").connection.port, 22)
        XCTAssertEqual(draft.folders.last, ["Jump hosts"])

        let proxied = try entry(draft, "Prod / DB / proxied")
        XCTAssertEqual(proxied.connection.username, "me", "<default> falls back to the Mac user")
        XCTAssertEqual(proxied.connection.proxyHost, "proxy.example.com")
        XCTAssertEqual(proxied.connection.proxyPort, 1080)
        XCTAssertEqual(proxied.connection.proxy.kind, .socks5)

        let files = try entry(draft, "Prod / DB / files")
        XCTAssertEqual(files.connection.opensFiles, true)
        XCTAssertEqual(files.connection.username, "ftp")
        XCTAssertEqual(draft.skipped.map(\.path), ["desktop"], "RDP is reported, not imported")

        XCTAssertThrowsError(try MobaXtermImport.parse("[Misc]\nShell=bash\n", name: "x"))
    }

    func testPuTTYRegistryExportsReadUTF16AndMapProxiesJumpsAndForwards() throws {
        let text = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions]

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\Default%20Settings]
        "HostName"=""

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\My%20Server]
        "HostName"="admin@my.example.com"
        "PortNumber"=dword:00000016
        "Protocol"="ssh"
        "PublicKeyFile"="C:\\\\Users\\\\me\\\\key.ppk"
        "PortForwardings"="L8080=db.internal:5432,D1080,R9000=localhost:3000,L127.0.0.1:7000=x:1,4L9001=y:2"
        "Colours"=hex:00,01,\\
          02,03

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\via%20socks]
        "HostName"="inside.example.com"
        "UserName"="ops"
        "PortNumber"=dword:00000016
        "ProxyMethod"=dword:00000001
        "ProxyHost"="socks.example.com"
        "ProxyPort"=dword:00000438

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\via%20jump]
        "HostName"="deep.example.com"
        "UserName"="ops"
        "ProxyMethod"=dword:00000006
        "ProxyHost"="gate.example.com"
        "ProxyPort"=dword:00000016
        "ProxyUsername"="gatekeeper"

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\router]
        "HostName"="10.0.0.1"
        "Protocol"="telnet"
        """
        var data = Data([0xFF, 0xFE])
        data.append(text.replacingOccurrences(of: "\n", with: "\r\n").data(using: .utf16LittleEndian)!)
        let draft = try PuTTYImport.parse(ImportText.decode(data), localUser: "me")

        let server = try entry(draft, "My Server")
        XCTAssertEqual(server.connection.username, "admin")
        XCTAssertEqual(server.connection.host, "my.example.com")
        XCTAssertEqual(server.connection.port, 22)
        XCTAssertEqual(server.connection.forwardingRules?.map(\.kind), [.local, .dynamic, .remote])
        XCTAssertEqual(server.connection.forwardingRules?.first?.host, "db.internal")
        XCTAssertEqual(server.connection.forwardingRules?.first?.port, 5432)
        XCTAssertTrue(server.notes.contains { $0.contains("port forwards were not imported") })
        XCTAssertTrue(server.notes.contains { $0.contains("key file on Windows") })

        let socks = try entry(draft, "via socks")
        XCTAssertEqual(socks.connection.proxy.kind, .socks4)
        XCTAssertEqual(socks.connection.proxyPort, 1080)

        let jumped = try entry(draft, "via jump")
        XCTAssertEqual(jumped.jump, ["Jump hosts", "gatekeeper@gate.example.com"])
        XCTAssertNil(jumped.connection.proxyHost)

        XCTAssertFalse(draft.entries.contains { $0.name == "Default Settings" })
        XCTAssertEqual(draft.skipped.map(\.path), ["router"])
    }

    func testCSVImportReadsQuotedFieldsJumpsAndLeavesPasswordsOut() throws {
        let text = """
        \u{FEFF}Folder;Name;Host name;Port;User;Protocol;Key file;Password;Jump host
        Team/Prod;bastion;bastion.example.com;22;ops;ssh;~/.ssh/id_ed25519;hunter2;
        Team/Prod;"db; primary";db.internal;5432;postgres;ssh;;secret;Team/Prod/bastion
        ;files;files.example.com;;;sftp;;;deploy@edge.example.com:2222
        ;bad;bad.example.com;99999;x;ssh;;;
        ;rdp;win.example.com;3389;x;rdp;;;
        """
        let draft = try CSVSessionImport.parse(text, name: "servers", localUser: "me")
        XCTAssertEqual(draft.folders.prefix(2), [["Team"], ["Team", "Prod"]])
        let bastion = try entry(draft, "Team / Prod / bastion")
        XCTAssertEqual(bastion.connection.identityPath, (("~/.ssh/id_ed25519") as NSString).expandingTildeInPath)
        let db = try entry(draft, "Team / Prod / db; primary")
        XCTAssertEqual(db.connection.port, 5432)
        XCTAssertEqual(db.jump, ["Team", "Prod", "bastion"])
        let files = try entry(draft, "files")
        XCTAssertEqual(files.connection.opensFiles, true)
        XCTAssertEqual(files.connection.username, "me")
        XCTAssertEqual(files.jump, ["Jump hosts", "deploy@edge.example.com:2222"])
        XCTAssertTrue(draft.skipped.contains { $0.path == "Password" }, "A password column is reported and ignored")
        XCTAssertEqual(draft.skipped.filter { $0.path != "Password" }.count, 2, "The bad port and the RDP row are reported")
        XCTAssertThrowsError(try CSVSessionImport.parse("name,user\nweb,ops\n", name: "x"), "A host column is required")
    }

    func testExportedSessionsImportBackWithTheirFoldersJumpsAndSettings() throws {
        let tree = try store()
        let team = try tree.add(name: "Team", parent: nil)
        let prod = try tree.add(name: "Prod", parent: team)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let gate = try tree.add(name: "gate", parent: prod, connection: SavedConnection(host: "gate.example.com", username: "ops",
                                                                                         identityPath: home + "/.ssh/id_ed25519"))
        var db = SavedConnection(host: "db.internal", port: 2200, username: "postgres", jumpSessionID: gate)
        db.forwardingRules = [ForwardingRule(kind: .local, listenPort: 5432, host: "127.0.0.1", port: 5432)]
        try tree.add(name: "=db, primary", parent: prod, connection: db)
        let outside = try tree.add(name: "outside", parent: nil, connection: SavedConnection(host: "out.example.com", port: 2022, username: "x"))
        try tree.add(name: "via outside", parent: team, connection: SavedConnection(host: "in.example.com", username: "y", jumpSessionID: outside))

        let data = try SessionExport.data(tree, root: team, format: .mshell)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"~/.ssh/id_ed25519\""), "Key paths are written relative to home")
        XCTAssertFalse(json.contains(home), "The file names no user's own folder")
        let draft = try SessionsFile.read(data)
        XCTAssertEqual(draft.name, "Team")
        let gateEntry = try entry(draft, "Prod / gate")
        XCTAssertEqual(gateEntry.connection.identityPath, home + "/.ssh/id_ed25519")
        let dbEntry = try entry(draft, "Prod / =db, primary")
        XCTAssertEqual(dbEntry.jump, ["Prod", "gate"])
        XCTAssertEqual(dbEntry.connection.forwardingRules?.first?.listenPort, 5432)
        XCTAssertNil(dbEntry.connection.jumpSessionID)
        XCTAssertEqual(try entry(draft, "via outside").jump, ["Jump hosts", "x@out.example.com:2022"],
                       "A jump host outside the export becomes its own session")

        let root = try tree.importProfiles(draft, name: "Imported", parent: nil)
        func isUnder(_ id: UUID?, _ ancestor: UUID) -> Bool {
            var current = tree.node(id)?.parent
            while let parent = current { if parent == ancestor { return true }; current = tree.node(parent)?.parent }
            return false
        }
        let importedDB = try XCTUnwrap(tree.nodes.first { $0.name == "=db, primary" && isUnder($0.id, root) })
        let jumpTarget = try XCTUnwrap(tree.node(importedDB.connection?.jumpSessionID))
        XCTAssertEqual(jumpTarget.name, "gate")
        XCTAssertNotEqual(jumpTarget.id, gate, "The copy links to the imported jump host")
        XCTAssertEqual(tree.node(tree.node(jumpTarget.parent)?.parent)?.id, root)

        let csv = try SessionExport.data(tree, root: team, format: .csv)
        let text = String(decoding: csv, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("\u{FEFF}folder,name,host"))
        XCTAssertTrue(text.contains("\"'=db, primary\""), "Formula-like names are guarded and quoted")
        let back = try CSVSessionImport.parse(text, name: "Team")
        XCTAssertEqual(try entry(back, "Prod / =db, primary").jump, ["Prod", "gate"])
        XCTAssertEqual(try entry(back, "Prod / gate").connection.identityPath, home + "/.ssh/id_ed25519")
        XCTAssertThrowsError(try SessionsFile.read(Data("{\"format\":\"other\"}".utf8)))
    }

    func testWindowsCodePagesDecode() {
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue))
        let data = "[Bookmarks]\nSubRep=住商\n".data(using: String.Encoding(rawValue: big5))!
        XCTAssertNil(String(data: data, encoding: .utf8))
        XCTAssertTrue(ImportText.decode(data).contains("住商"))
    }
}
