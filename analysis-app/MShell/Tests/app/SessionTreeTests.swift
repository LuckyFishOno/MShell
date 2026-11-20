import XCTest
@testable import App

@MainActor final class SessionTreeTests: XCTestCase {
    func path() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tree-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("sessions.json")
    }
    func testPersistenceSortingExpansionAndCredentialExclusion() throws {
        let file = try path(), tree = try SessionTreeStore(url: file)
        let folder = try tree.add(name: "Folder 10", parent: nil)
        _ = try tree.add(name: "Folder 2", parent: nil)
        _ = try tree.add(name: "AAA", parent: nil, connection: SavedConnection(host: "example.test", username: "user"))
        try tree.setExpanded(folder, false)
        let reopened = try SessionTreeStore(url: file)
        XCTAssertEqual(reopened.children(of: nil).map(\.name), ["Folder 2", "Folder 10", "AAA"])
        XCTAssertFalse(try XCTUnwrap(reopened.node(folder)).expanded)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).lowercased().contains("password"))
    }
    func testCycleCollisionInvalidParentAndNameLeaveDiskUnchanged() throws {
        let file = try path(), tree = try SessionTreeStore(url: file)
        let a = try tree.add(name: "A", parent: nil), b = try tree.add(name: "B", parent: a)
        let session = try tree.add(name: "Session", parent: nil, connection: SavedConnection(host: "test", username: "user"))
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try tree.relocate(a, into: b, copy: false))
        XCTAssertThrowsError(try tree.relocate(a, into: b, copy: true))
        XCTAssertThrowsError(try tree.add(name: "a", parent: nil))
        XCTAssertThrowsError(try tree.add(name: "child", parent: session))
        XCTAssertThrowsError(try tree.add(name: "orphan", parent: UUID()))
        for name in ["../bad", "x/y", "x\\y", " ", "a\n", ".."] { XCTAssertThrowsError(try tree.rename(a, to: name)) }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(tree.node(a)?.name, "A")
    }
    func testCopyMoveDeleteRetainSubtreeIdentityAndClipboardSemantics() throws {
        let tree = try SessionTreeStore(url: path())
        let a = try tree.add(name: "A", parent: nil), b = try tree.add(name: "B", parent: nil)
        let child = try tree.add(name: "Child", parent: a)
        let leaf = try tree.add(name: "SSH", parent: child, connection: SavedConnection(host: "test", username: "user"))
        tree.prepareClipboard(child, cut: false); try tree.paste(into: b)
        let copied = try XCTUnwrap(tree.children(of: b).first)
        XCTAssertNotEqual(copied.id, child); XCTAssertEqual(tree.connections(in: copied.id).count, 1)
        XCTAssertNotEqual(tree.connections(in: copied.id).first?.id, leaf); XCTAssertEqual(tree.clipboard, child)
        tree.prepareClipboard(child, cut: true); XCTAssertThrowsError(try tree.paste(into: b)); XCTAssertEqual(tree.clipboard, child)
        try tree.rename(copied.id, to: "Copy"); try tree.paste(into: b)
        XCTAssertNil(tree.clipboard); XCTAssertEqual(tree.node(child)?.parent, b); XCTAssertEqual(tree.node(leaf)?.parent, child)
        try tree.remove(b); XCTAssertNil(tree.node(child)); XCTAssertNil(tree.node(leaf)); XCTAssertEqual(tree.nodes.count, 1)
    }
    func testFilteringKeepsAncestorsAndFindsHostWithoutOpeningConnection() throws {
        let tree = try SessionTreeStore(url: path())
        let folder = try tree.add(name: "Servers", parent: nil)
        let leaf = try tree.add(name: "Production", parent: folder, connection: SavedConnection(host: "target.test", username: "user"))
        tree.query = "TARGET"; XCTAssertTrue(tree.matches(folder)); XCTAssertTrue(tree.matches(leaf))
        tree.query = "missing"; XCTAssertFalse(tree.matches(folder))
    }
    func testWorkspaceCatalogExcludesPasswordAndMissingCredentialsAreReported() async throws {
        let file = try path(), model = try WorkspaceModel(storage: file.deletingLastPathComponent())
        let tab = try XCTUnwrap(model.selected); tab.host = "test"; tab.username = "user"; tab.password = "temporary-test-secret"
        let folder = try model.sessionTree.add(name: "Servers", parent: nil)
        try model.saveConnection(tab, name: "Saved", parent: folder)
        let item = try XCTUnwrap(model.sessionTree.connections(in: folder).first)
        let opened = try XCTUnwrap(model.openSaved(item))
        await opened.savedConnectionTask?.value
        XCTAssertNotNil(opened.error)
        XCTAssertFalse(opened.busy)
        XCTAssertEqual(model.selected?.host, "test"); XCTAssertEqual(model.selected?.password, ""); XCTAssertEqual(model.selected?.connected, false)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("temporary-test-secret"))
        let reopened = try WorkspaceModel(storage: file.deletingLastPathComponent()); XCTAssertEqual(reopened.sessionTree.nodes.count, 2)
    }
    func testFailedDiskWriteDoesNotPublishMutation() throws {
        let file = try path(), tree = try SessionTreeStore(url: file)
        let id = try tree.add(name: "Original", parent: nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try tree.rename(id, to: "Changed"))
        XCTAssertEqual(tree.node(id)?.name, "Original")
    }
    func testCorruptCycleCatalogIsRejected() throws {
        let file = try path(), a = UUID(), b = UUID()
        let nodes = [SessionTreeNode(id: a, parent: b, name: "A"), SessionTreeNode(id: b, parent: a, name: "B")]
        let encoded = try JSONEncoder().encode(nodes)
        let objects = try JSONSerialization.jsonObject(with: encoded)
        try JSONSerialization.data(withJSONObject: ["version": 1, "nodes": objects]).write(to: file)
        XCTAssertThrowsError(try SessionTreeStore(url: file))
    }
}
