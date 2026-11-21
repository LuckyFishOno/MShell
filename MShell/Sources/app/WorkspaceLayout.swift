import Foundation

/// How the workspace window is arranged. The raw values stay stable for saved preferences and the CLI.
public enum WorkspaceLayout: String, CaseIterable, Codable, Identifiable {
    /// A Mac app: toolbar, flat tabs, and floating panes.
    case native = "macos"
    /// Xshell-style: icon toolbar, address bar, session manager, numbered tabs, compose bar, and status bar.
    case terminal
    /// MobaXterm-style: large-button ribbon, a vertical side rail with sessions, SFTP, and macros,
    /// and a remote monitoring bar.
    case transfer

    public var id: String { rawValue }

    /// Accepts the stored names and the product-style aliases `xshell` and `mobaxterm`.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "macos", "native", "mac": self = .native
        case "terminal", "xshell": self = .terminal
        case "transfer", "mobaxterm", "moba": self = .transfer
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .native: return "macOS"
        case .terminal: return T("Xshell style")
        case .transfer: return T("MobaXterm style")
        }
    }

    var detail: String {
        switch self {
        case .native: return T("Toolbar, flat tabs, and floating panes")
        case .terminal: return T("Session manager, compose bar, and status bar")
        case .transfer: return T("Ribbon, side rail with SFTP, and remote monitoring")
        }
    }

    var symbol: String {
        switch self {
        case .native: return "macwindow"
        case .terminal: return "rectangle.bottomthird.inset.filled"
        case .transfer: return "sidebar.squares.left"
        }
    }

    private static func file(in storage: URL) -> URL {
        storage.appendingPathComponent("layout.json")
    }

    public static func load(from storage: URL) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file(in: storage))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .native }
    }

    public func save(to storage: URL) throws {
        try writePrivate(JSONEncoder().encode(self), to: Self.file(in: storage))
    }
}
