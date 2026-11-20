import XCTest
import Foundation
@testable import App

@MainActor final class ThemeTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-theme-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testCatalogUsesPinnedStandaloneAssetsAndResolvesInheritedColors() throws {
        let themes = try ThemeCatalog.bundled()
        XCTAssertEqual(themes.count, 18)
        let modern = try XCTUnwrap(themes.first { $0.id == "Dark Modern" })
        XCTAssertEqual(modern.background, ThemeColor(hex: "#1f1f1f"))
        XCTAssertEqual(modern.sidebar, ThemeColor(hex: "#181818"))
        XCTAssertEqual(modern.colors["editor.inactiveSelectionBackground"], ThemeColor(hex: "#3a3d41"))
        for theme in themes { for index in 0..<16 { XCTAssertTrue((0...1).contains(theme.terminalANSI(index).red)) } }
        XCTAssertFalse(try XCTUnwrap(themes.first { $0.id == "Light Modern" }).isDark)
    }
    func testPresetPreviewAppliesWorkspaceAndTerminalColorsTogether() throws {
        let storage = try directory()
        let model = try WorkspaceModel(storage: storage)
        let native = model.theme
        let paper = try XCTUnwrap(model.themes.first { $0.id == "paper" })
        func assertMatchesPaper(_ theme: WorkspaceTheme) {
            XCTAssertEqual(theme.background, paper.background)
            XCTAssertEqual(theme.header, paper.header)
            XCTAssertEqual(theme.sidebar, paper.sidebar)
            XCTAssertEqual(theme.tabs, paper.tabs)
            XCTAssertEqual(theme.terminalBackground, paper.terminalBackground)
            XCTAssertEqual(theme.accent, paper.accent)
            XCTAssertFalse(theme.isDark)
        }

        model.beginThemePreview()
        try model.focusThemePreview(paper.id, schedule: false)
        model.advanceThemePreview(milliseconds: 200)
        assertMatchesPaper(model.theme)
        XCTAssertNotEqual(model.theme.sidebar, native.sidebar)
        XCTAssertNotEqual(model.theme.terminalBackground, native.terminalBackground)
        XCTAssertEqual(try WorkspaceModel(storage: storage).themeID, native.id)
        model.cancelThemePreview()
        XCTAssertEqual(model.displayedThemeID, native.id)

        try model.selectTheme(paper.id)
        assertMatchesPaper(try WorkspaceModel(storage: storage).theme)
    }

    func testColorDecodingPreservesAlphaAndRejectsInvalidInputs() {
        XCTAssertEqual(ThemeColor(hex: "#abcd"), ThemeColor(hex: "#aabbccdd"))
        XCTAssertEqual(ThemeColor(hex: "#123"), ThemeColor(hex: "#112233ff"))
        XCTAssertEqual(ThemeColor(hex: "#00000000")?.alpha, 0)
        for value in ["red", "123456", "#12345", "#xxxxxx"] { XCTAssertNil(ThemeColor(hex: value)) }
    }
    func testPreviewDebouncesWithoutSavingAndCancelRestoresThePersistedTheme() throws {
        let storage = try directory(), model = try WorkspaceModel(storage: storage)
        try model.selectTheme("Dark Modern"); model.beginThemePreview()
        try model.focusThemePreview("Light Modern", schedule: false)
        model.advanceThemePreview(milliseconds: 199); XCTAssertEqual(model.displayedThemeID, "Dark Modern")
        model.advanceThemePreview(milliseconds: 1); XCTAssertEqual(model.displayedThemeID, "Light Modern")
        XCTAssertEqual(try WorkspaceModel(storage: storage).themeID, "Dark Modern")
        model.cancelThemePreview(); XCTAssertEqual(model.displayedThemeID, "Dark Modern"); XCTAssertNil(model.themePreview)
    }
    func testAcceptBeforePreviewAndRepeatedFocusUseTheLatestChoice() throws {
        let model = try WorkspaceModel(storage: directory()); try model.selectTheme("Dark Modern")
        model.beginThemePreview(); try model.focusThemePreview("Light Modern", schedule: false)
        model.advanceThemePreview(milliseconds: 100); try model.focusThemePreview("Dark+", schedule: false)
        model.advanceThemePreview(milliseconds: 199); XCTAssertEqual(model.displayedThemeID, "Dark Modern")
        try model.applyThemePreview(); XCTAssertEqual(model.themeID, "Dark+"); XCTAssertNil(model.themePreview)
        model.beginThemePreview(); model.cancelThemePreview(); XCTAssertEqual(model.themeID, "Dark+")
    }
    func testFailedApplyKeepsPreviewAndDoesNotOverwriteSavedTheme() throws {
        let storage = try directory(), model = try WorkspaceModel(storage: storage)
        model.beginThemePreview(); try model.focusThemePreview("Light Modern", schedule: false); model.advanceThemePreview(milliseconds: 200)
        try FileManager.default.createDirectory(at: storage.appendingPathComponent("appearance.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.applyThemePreview()); XCTAssertEqual(model.themeID, "mshell")
        XCTAssertEqual(model.displayedThemeID, "Light Modern"); XCTAssertNotNil(model.themePreview)
        model.cancelThemePreview(); XCTAssertEqual(model.displayedThemeID, "mshell")
    }
    func testCancelledRealTimerCannotApplyAfterPreferencesClose() async throws {
        let model = try WorkspaceModel(storage: directory()); model.beginThemePreview()
        try model.focusThemePreview("Light Modern"); model.cancelThemePreview()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(model.displayedThemeID, "mshell"); XCTAssertNil(model.themePreview)
    }
    func testEveryThemePersistsWithoutReplacingSessionStateOrConnecting() throws {
        let storage = try directory(), model = try WorkspaceModel(storage: storage)
        let first = model.tabs[0]; first.host = "keep.test"; first.password = "unsaved-secret"
        let second = model.addTab(), selection = model.selection
        for theme in model.themes {
            try model.selectTheme(theme.id)
            XCTAssertEqual(try WorkspaceModel(storage: storage).themeID, theme.id)
            XCTAssertEqual(model.tabs.map(\.id), [first.id, second.id]); XCTAssertEqual(model.selection, selection)
            XCTAssertEqual(first.host, "keep.test"); XCTAssertFalse(first.connected)
        }
        XCTAssertFalse(try String(contentsOf: storage.appendingPathComponent("appearance.json"), encoding: .utf8).contains("unsaved-secret"))
        let previous = model.themeID
        XCTAssertThrowsError(try model.selectTheme("not-a-theme")); XCTAssertEqual(model.themeID, previous)
    }
    func testMissingAndStaleThemePreferencesFallBackToNativeWithoutRewriting() throws {
        let storage = try directory(), file = storage.appendingPathComponent("appearance.json")
        XCTAssertEqual(try WorkspaceModel(storage: storage).themeID, "mshell")
        for contents in ["broken", "{\"selectedID\":\"removed-theme\"}"] {
            try Data(contents.utf8).write(to: file)
            XCTAssertEqual(try WorkspaceModel(storage: storage).themeID, "mshell")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), contents)
        }
    }
    func testFailedPersistenceDoesNotChangeActiveTheme() throws {
        let storage = try directory(), model = try WorkspaceModel(storage: storage)
        try FileManager.default.createDirectory(at: storage.appendingPathComponent("appearance.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.selectTheme("Dark Modern")); XCTAssertEqual(model.themeID, "mshell")
    }
    func testThemeSwitchKeepsAnActiveLocalPTYAndItsTranscript() async throws {
        let model = try WorkspaceModel(storage: directory()), tab = model.addLocalTab()
        defer { tab.localShell?.close() }
        let shell = tab.localShell
        model.sendTerminal(tab, bytes: Array("printf 'THEME_BEFORE_%s\\n' OK\r".utf8))
        for _ in 0..<100 {
            if tab.transcript.contains("THEME_BEFORE_OK") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(tab.transcript.contains("THEME_BEFORE_OK"))
        try model.selectTheme("Light Modern")
        XCTAssertTrue(tab.localShell === shell); XCTAssertTrue(tab.terminalReady)
        model.sendTerminal(tab, bytes: Array("printf 'THEME_AFTER_%s\\n' OK\r".utf8))
        for _ in 0..<100 {
            if tab.transcript.contains("THEME_AFTER_OK") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(tab.transcript.contains("THEME_BEFORE_OK")); XCTAssertTrue(tab.transcript.contains("THEME_AFTER_OK"))
        await model.closeAll()
    }
}
