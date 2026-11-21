import Foundation
import SwiftUI

enum WorkspaceSplitAxis {
    case sideBySide
    case stacked
}

/// A pane layout: a single tab, or two child layouts split side by side or stacked.
/// Any pane can be split again, so layouts nest without a fixed pane count.
indirect enum WorkspacePane: Equatable {
    case tab(UUID)
    case split(WorkspaceSplitAxis, WorkspacePane, WorkspacePane)

    /// Tab IDs in reading order (left to right, top to bottom).
    var tabIDs: [UUID] {
        switch self {
        case .tab(let id): return [id]
        case .split(_, let first, let second): return first.tabIDs + second.tabIDs
        }
    }

    func contains(_ id: UUID?) -> Bool { id.map { tabIDs.contains($0) } ?? false }

    func replacing(_ old: UUID, with new: UUID) -> WorkspacePane {
        switch self {
        case .tab(let id): return .tab(id == old ? new : id)
        case .split(let axis, let first, let second):
            return .split(axis, first.replacing(old, with: new), second.replacing(old, with: new))
        }
    }

    /// Splits the pane showing `target` in two. The new tab goes to the right or below,
    /// or to the left or above when `newFirst` is true.
    func splitting(_ target: UUID, axis: WorkspaceSplitAxis, adding new: UUID, newFirst: Bool = false) -> WorkspacePane {
        switch self {
        case .tab(let id):
            guard id == target else { return self }
            return newFirst ? .split(axis, .tab(new), .tab(id)) : .split(axis, .tab(id), .tab(new))
        case .split(let current, let first, let second):
            return .split(current, first.splitting(target, axis: axis, adding: new, newFirst: newFirst),
                          second.splitting(target, axis: axis, adding: new, newFirst: newFirst))
        }
    }

    func swapping(_ a: UUID, _ b: UUID) -> WorkspacePane {
        switch self {
        case .tab(let id): return .tab(id == a ? b : id == b ? a : id)
        case .split(let axis, let first, let second): return .split(axis, first.swapping(a, b), second.swapping(a, b))
        }
    }

    /// Removes the pane showing `id`; its sibling takes the freed space. Returns nil when nothing is left.
    func removing(_ id: UUID) -> WorkspacePane? {
        switch self {
        case .tab(let tab): return tab == id ? nil : self
        case .split(let axis, let first, let second):
            switch (first.removing(id), second.removing(id)) {
            case let (first?, second?): return .split(axis, first, second)
            case let (remaining?, nil), let (nil, remaining?): return remaining
            case (nil, nil): return nil
            }
        }
    }
}

/// Where a dragged tab lands on a pane: an edge splits the pane, the center replaces it.
enum PaneDropEdge: Equatable {
    case left, right, top, bottom, center

    var axis: WorkspaceSplitAxis { self == .top || self == .bottom ? .stacked : .sideBySide }
    var placesNewFirst: Bool { self == .left || self == .top }

    /// Picks the edge for a point in a pane of the given size. Points within 30% of an edge
    /// split toward that edge; the middle area replaces the pane.
    static func at(_ point: CGPoint, in size: CGSize) -> PaneDropEdge {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = min(max(point.x / size.width, 0), 1), y = min(max(point.y / size.height, 0), 1)
        let distances: [(PaneDropEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let nearest = distances.min { $0.1 < $1.1 }!
        return nearest.1 < 0.3 ? nearest.0 : .center
    }
}

struct WorkspaceSplit: Equatable {
    var root: WorkspacePane

    init(axis: WorkspaceSplitAxis, first: UUID, second: UUID) { root = .split(axis, .tab(first), .tab(second)) }
    private init(root: WorkspacePane) { self.root = root }
    /// A split layout for `root`, or nil when it is a single pane.
    static func make(_ root: WorkspacePane) -> WorkspaceSplit? {
        if case .split = root { return WorkspaceSplit(root: root) }
        return nil
    }

    var tabIDs: [UUID] { root.tabIDs }
    func contains(_ tabID: UUID?) -> Bool { root.contains(tabID) }

    func splitting(_ target: UUID, axis: WorkspaceSplitAxis, adding new: UUID) -> WorkspaceSplit {
        WorkspaceSplit(root: root.splitting(target, axis: axis, adding: new))
    }

    /// The layout without `tabID`, or nil when fewer than two panes would remain.
    func removing(_ tabID: UUID) -> WorkspaceSplit? {
        guard let remaining = root.removing(tabID), case .split = remaining else { return nil }
        return WorkspaceSplit(root: remaining)
    }
}


public struct WorkspaceSplitCommands: Commands {
    @ObservedObject private var model: WorkspaceModel
    public init(model: WorkspaceModel) { self.model = model }

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(T("Split side by side")) { model.splitWorkspace(.sideBySide) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!model.canSplit(model.selection))
            Button(T("Split top and bottom")) { model.splitWorkspace(.stacked) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.canSplit(model.selection))
            Button(T(model.maximizedPane == nil ? "Maximize pane" : "Restore pane")) {
                if let id = model.maximizedPane ?? model.selection { model.toggleMaximizedPane(id) }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(model.split == nil)
            Button(T(model.broadcastInput ? "Stop typing into all panes" : "Type into all panes")) { model.toggleBroadcastInput() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.split == nil)
            Button(T("Close split view")) { model.closeSplit() }
                .disabled(model.split == nil)
        }
    }
}
