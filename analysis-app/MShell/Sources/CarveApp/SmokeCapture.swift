import AppKit
import Foundation

// Local visual verification of this application's own window; never captures other applications.
@MainActor enum SmokeCapture {
    private static var scheduled = false
    static func scheduleIfRequested(state: @escaping () -> [String: Any] = { [:] }) {
        let args = CommandLine.arguments
        guard !scheduled, let index = args.firstIndex(of: "--capture-window"), index + 1 < args.count else { return }
        scheduled = true
        let destination = URL(fileURLWithPath: args[index + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var report: [String: Any] = ["scope": "own-application-window-bitmap", "captured": false]
            report["state"] = state()
            let preferences = args.contains("--show-preferences")
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && (preferences ? $0.title != "MShell" : $0.title == "MShell") }),
               let view = window.contentView?.superview ?? window.contentView, // the frame view includes the toolbar
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    do {
                        try data.write(to: destination)
                        report["captured"] = true; report["title"] = window.title
                        report["width"] = bitmap.pixelsWide; report["height"] = bitmap.pixelsHigh
                    } catch { report["error"] = error.localizedDescription }
                }
            }
            let commands = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.filter { $0.keyEquivalent == "," }.map { ["title": $0.title, "keyEquivalent": $0.keyEquivalent] } ?? []
            report["preferencesCommands"] = commands
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: destination.appendingPathExtension("json"))
            }
            if args.contains("--exit-after-capture") { NSApp.terminate(nil) }
        }
    }
}
