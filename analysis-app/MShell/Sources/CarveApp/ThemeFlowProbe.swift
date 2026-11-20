import Foundation
import App

// Exercises the real workspace model and its isolated on-disk preference backend.
enum ThemeFlowProbe {
    static func start() -> Never {
        Task { @MainActor in
            do { try run(); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        dispatchMain()
    }
    @MainActor private static func run() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard input.count <= 1_048_576, let args = try JSONSerialization.jsonObject(with: input) as? [[String: Any]], args.count == 1,
              let scenario = args.first, let name = scenario["id"] as? String, let initial = scenario["initial"] as? [String: Any],
              let selected = initial["savedTheme"] as? String, let steps = scenario["steps"] as? [[String: Any]], steps.count <= 64 else { throw ThemeError.invalidResources }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-theme-flow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try WorkspaceModel(storage: directory)
        try model.selectTheme(selected)
        func snapshot() -> [String: Any] {
            let persisted = (try? Data(contentsOf: directory.appendingPathComponent("appearance.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            return ["activeTheme": model.displayedThemeID, "savedTheme": persisted?["selectedID"] ?? "mshell", "open": model.themePreview != nil, "pendingTheme": model.themePreview?.pendingID as Any? ?? NSNull()]
        }
        var states = [snapshot()]
        for step in steps {
            let fields = step["input"] as? [String: Any] ?? [:]
            switch step["action"] as? String {
            case "open": model.beginThemePreview()
            case "focus": guard let id = fields["theme"] as? String else { throw ThemeError.unknownTheme }; try model.focusThemePreview(id, schedule: false)
            case "wait": guard let delay = fields["milliseconds"] as? Int, (0...30_000).contains(delay) else { throw ThemeError.invalidResources }; model.advanceThemePreview(milliseconds: delay)
            case "accept": try model.applyThemePreview()
            case "cancel": model.cancelThemePreview()
            default: throw ThemeError.invalidResources
            }
            states.append(snapshot())
        }
        let output: [String: Any] = ["schema": "carve/frontend-flow-trace@1", "scenario": name, "states": states]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
