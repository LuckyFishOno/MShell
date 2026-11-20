import Foundation

public enum WorkspaceLayout: String, CaseIterable, Codable, Identifiable {
    case native = "macos"
    case terminal
    case transfer

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "macOS"
        case .terminal: return T("Terminal workspace")
        case .transfer: return T("Transfer workspace")
        }
    }

    var shortTitle: String {
        switch self {
        case .native: return "macOS"
        case .terminal: return T("Terminal")
        case .transfer: return T("Files")
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
