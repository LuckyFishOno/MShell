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
    func testFindingAFolderListsEverythingUnderIt() throws {
        let tree = try SessionTreeStore(url: path())
        let folder = try tree.add(name: "住商", parent: nil), inner = try tree.add(name: "Branch", parent: folder)
        let direct = try tree.add(name: "web", parent: folder, connection: SavedConnection(host: "a.test", username: "u"))
        let deep = try tree.add(name: "db", parent: inner, connection: SavedConnection(host: "b.test", username: "u"))
        let other = try tree.add(name: "Other", parent: nil, connection: SavedConnection(host: "c.test", username: "u"))
        tree.query = "住商"
        for id in [folder, inner, direct, deep] { XCTAssertTrue(tree.matches(id)) }
        XCTAssertFalse(tree.matches(other))
        tree.query = "db"
        XCTAssertTrue(tree.matches(folder)); XCTAssertTrue(tree.matches(inner)); XCTAssertTrue(tree.matches(deep))
        XCTAssertFalse(tree.matches(direct), "A match deeper down shows its path, not its siblings.")
    }
    func testDraggingReordersAndMovesIntoFoldersAndTheOrderPersists() throws {
        let file = try path(), tree = try SessionTreeStore(url: file)
        let folder = try tree.add(name: "Folder", parent: nil)
        let a = try tree.add(name: "A", parent: nil, connection: SavedConnection(host: "a.test", username: "u"))
        let b = try tree.add(name: "B", parent: nil, connection: SavedConnection(host: "b.test", username: "u"))
        let c = try tree.add(name: "C", parent: nil, connection: SavedConnection(host: "c.test", username: "u"))
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["Folder", "A", "B", "C"])
        try tree.drop(c, on: a, .before)
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["Folder", "C", "A", "B"])
        try tree.drop(folder, on: b, .after)
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["C", "A", "B", "Folder"])
        try tree.drop(a, on: folder, .into)
        XCTAssertEqual(tree.node(a)?.parent, folder)
        let d = try tree.add(name: "D", parent: folder, connection: SavedConnection(host: "d.test", username: "u"))
        try tree.drop(d, on: a, .before)
        XCTAssertEqual(tree.children(of: folder).map(\.name), ["D", "A"])
        try tree.drop(a, on: nil, .into)
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["C", "B", "Folder", "A"])
        let new = try tree.add(name: "0 New", parent: nil, connection: SavedConnection(host: "n.test", username: "u"))
        XCTAssertEqual(tree.children(of: nil).last?.id, new, "Items added after reordering go last.")
        let reopened = try SessionTreeStore(url: file)
        XCTAssertEqual(reopened.children(of: nil).map(\.name), ["C", "B", "Folder", "A", "0 New"])
        XCTAssertEqual(reopened.children(of: folder).map(\.name), ["D"])
    }
    func testDropsOntoOrInsideItselfOrIntoASessionAreRefused() throws {
        let file = try path(), tree = try SessionTreeStore(url: file)
        let outer = try tree.add(name: "Outer", parent: nil), inner = try tree.add(name: "Inner", parent: outer)
        let leaf = try tree.add(name: "Leaf", parent: inner, connection: SavedConnection(host: "a.test", username: "u"))
        let same = try tree.add(name: "Leaf", parent: nil, connection: SavedConnection(host: "b.test", username: "u"))
        let original = try Data(contentsOf: file)
        XCTAssertFalse(tree.canDrop(outer, on: inner, .into)); XCTAssertFalse(tree.canDrop(outer, on: leaf, .before))
        XCTAssertFalse(tree.canDrop(outer, on: outer, .after)); XCTAssertFalse(tree.canDrop(same, on: leaf, .into))
        XCTAssertFalse(tree.canDrop(nil, on: outer, .into)); XCTAssertTrue(tree.canDrop(inner, on: nil, .into))
        XCTAssertThrowsError(try tree.drop(outer, on: inner, .into))
        XCTAssertThrowsError(try tree.drop(same, on: inner, .into), "A name already used in that folder is refused.")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(tree.node(same)?.parent, nil)
    }
    func testSortingByNameKeepsFoldersFirstPersistsAndLeavesTheCustomOrderIntact() throws {
        let file = try path(), tree = try SessionTreeStore(url: file)
        let folder = try tree.add(name: "Folder", parent: nil)
        let a = try tree.add(name: "A", parent: nil, connection: SavedConnection(host: "a.test", username: "u"))
        let b = try tree.add(name: "B", parent: nil, connection: SavedConnection(host: "b.test", username: "u"))
        let c = try tree.add(name: "C", parent: nil, connection: SavedConnection(host: "c.test", username: "u"))
        try tree.drop(c, on: folder, .before); try tree.drop(a, on: b, .after)
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["C", "Folder", "B", "A"])
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("sorting"), "Custom is the default and is not written.")

        try tree.setSorting(.nameDescending)
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["Folder", "C", "B", "A"])
        try tree.setSorting(.nameAscending)
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["Folder", "A", "B", "C"])
        XCTAssertEqual(try SessionTreeStore(url: file).sorting, .nameAscending)

        let inside = try tree.add(name: "Z", parent: folder, connection: SavedConnection(host: "z.test", username: "u"))
        try tree.drop(inside, on: nil, .into)
        try tree.drop(b, on: folder, .into)
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["Folder", "A", "C", "Z"])

        try tree.setSorting(.custom)
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["C", "Folder", "A", "Z"], "Moving while sorted by name keeps the dragged order.")
        XCTAssertEqual(try SessionTreeStore(url: file).sorting, .custom)
    }
    func testDropZonesSplitRowsByHeight() {
        XCTAssertEqual(SessionTreeDropPlacement.at(4, height: 28, isFolder: false, expanded: false), .before)
        XCTAssertEqual(SessionTreeDropPlacement.at(20, height: 28, isFolder: false, expanded: false), .after)
        XCTAssertEqual(SessionTreeDropPlacement.at(4, height: 28, isFolder: true, expanded: false), .before)
        XCTAssertEqual(SessionTreeDropPlacement.at(14, height: 28, isFolder: true, expanded: false), .into)
        XCTAssertEqual(SessionTreeDropPlacement.at(26, height: 28, isFolder: true, expanded: false), .after)
        XCTAssertEqual(SessionTreeDropPlacement.at(26, height: 28, isFolder: true, expanded: true), .into)
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
