import App
import Foundation

enum LayoutCommand {
    private static let usage = "Usage: mshell layout get [--workspace PATH] | mshell layout set <macos|terminal|transfer> [--workspace PATH]"

    static func run(_ arguments: [String]) -> Int32 {
        var args = Array(arguments.dropFirst())
        var storage = WorkspaceModel.defaultStorage
        if args.count >= 2, args[args.count - 2] == "--workspace", let path = args.last, !path.isEmpty {
            storage = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            args.removeLast(2)
        }
        if args == ["--help"] { print(usage); return 0 }
        do {
            if args == ["get"] {
                print(try WorkspaceLayout.load(from: storage).rawValue)
                return 0
            }
            if args.count == 2, args.first == "set", let layout = WorkspaceLayout(rawValue: args[1]) {
                try layout.save(to: storage)
                print(layout.rawValue)
                return 0
            }
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }
}
