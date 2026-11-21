import XCTest
import Foundation
@testable import App

@MainActor final class ClassicLayoutTests: XCTestCase {
    private func model() throws -> WorkspaceModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-classic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try WorkspaceModel(storage: url)
    }

    func testAddressBarFillsABareHostAndRejectsMalformedInput() throws {
        let model = try model()
        let tab = try XCTUnwrap(model.openAddress(" db.internal:2222 "))
        XCTAssertEqual(tab.host, "db.internal")
        XCTAssertEqual(tab.port, "2222")
        XCTAssertFalse(tab.connected)
        XCTAssertEqual(model.selection, tab.id)
        XCTAssertNil(model.openAddress(""))
        XCTAssertNil(model.openAddress("db.internal:99999"))
        XCTAssertNil(model.openAddress("two words"))
        XCTAssertNil(model.openAddress("ssh://@host"))
    }

    func testAddressBarOpensUserAtHostTargetsWithTheirPort() throws {
        let model = try model()
        let tab = try XCTUnwrap(model.openAddress("ssh://admin@10.0.0.5:2200/"))
        XCTAssertEqual(tab.host, "10.0.0.5")
        XCTAssertEqual(tab.port, "2200")
        XCTAssertEqual(tab.username, "admin")
        XCTAssertEqual(tab.title, "admin@10.0.0.5")
        tab.savedConnectionTask?.cancel()
    }

    func testTerminalFolderComesFromOSC7OrTheWindowTitle() {
        XCTAssertEqual(TerminalFolder.current(screenDirectory: "/srv/app", title: "me@web: ~/x"), "/srv/app")
        XCTAssertEqual(TerminalFolder.fromTitle("me@web: ~/site/logs"), "site/logs")
        XCTAssertEqual(TerminalFolder.fromTitle("me@web: ~"), ".")
        XCTAssertEqual(TerminalFolder.fromTitle("root@web:/var/log"), "/var/log")
        XCTAssertNil(TerminalFolder.fromTitle("vim notes.txt"))
        XCTAssertNil(TerminalFolder.fromTitle("me@web: ~other/x"))
    }

    func testComposeBarNeedsAnOpenTerminal() throws {
        let model = try model()
        XCTAssertEqual(model.sendCompose("uptime", toAll: true), 0)
        XCTAssertEqual(model.sendCompose("", toAll: false), 0)
    }

    func testRemoteMonitorReadsLinuxCountersAndComputesRates() {
        let first = """
        @stat
        cpu  100 0 100 800 0 0 0 0 0 0
        @mem
        MemTotal:        8000000 kB
        MemAvailable:    6000000 kB
        @disk
        /dev/sda1 100000 25000 75000 25% /
        @up
        93784.21 180000.00
        @users
        2
        @net
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 5000 10 0 0 0 0 0 0 5000 10 0 0 0 0 0 0
          eth0: 10000 20 0 0 0 0 0 0 4000 8 0 0 0 0 0 0
        """
        let a = HostSample.parse(remote: first, time: 10)
        XCTAssertEqual(a.cpuTotal, 1000)
        XCTAssertEqual(a.cpuIdle, 800)
        XCTAssertEqual(a.memoryTotal, 8_000_000 * 1024)
        XCTAssertEqual(a.diskUsed, 25_000 * 1024)
        XCTAssertEqual(a.users, 2)
        XCTAssertEqual(a.received, 10000, "loopback traffic is left out")
        XCTAssertEqual(a.sent, 4000)

        var b = a
        b.time = 12; b.cpuTotal = 1200; b.cpuIdle = 850; b.received = 12048; b.sent = 4000
        let stats = HostStats(b, previous: a)
        XCTAssertEqual(stats.cpu ?? -1, 75, accuracy: 0.01)
        XCTAssertEqual(stats.memoryUsed, 2_000_000 * 1024)
        XCTAssertEqual(stats.receiveRate ?? -1, 1024, accuracy: 0.01)
        XCTAssertEqual(stats.sendRate, 0)
        XCTAssertNil(HostStats(a, previous: nil).cpu, "CPU use needs two readings")
        XCTAssertTrue(HostStats(HostSample.parse(remote: "Darwin", time: 1), previous: nil).isEmpty)
        XCTAssertEqual(HostStats.duration(93784), "1d 2h")
        XCTAssertEqual(HostStats.bytes(1536), "1.5 KB")
    }

    func testThisMacReportsMemoryDiskAndUptime() {
        let sample = HostSample.local()
        XCTAssertGreaterThan(sample.memoryTotal ?? 0, 0)
        XCTAssertGreaterThan(sample.diskSize ?? 0, 0)
        XCTAssertNotNil(sample.cpuTotal)
        XCTAssertGreaterThan(sample.uptime ?? 0, 0)
    }

    func testClassicTabsNumberTheirTitlesLikeMobaXterm() {
        XCTAssertEqual(TabChrome.rounded.title("web", number: 2), "2. web")
        XCTAssertEqual(TabChrome.boxed.title("web", number: 2), "web")
        XCTAssertEqual(TabChrome.flat.height, 34)
    }
}
