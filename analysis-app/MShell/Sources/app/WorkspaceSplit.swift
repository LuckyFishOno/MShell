import Foundation
import SwiftUI

enum WorkspaceSplitAxis {
    case sideBySide
    case stacked
}

struct WorkspaceSplit: Equatable {
    var axis: WorkspaceSplitAxis
    var first: UUID
    var second: UUID

    func contains(_ tabID: UUID?) -> Bool { tabID == first || tabID == second }

    mutating func replace(_ active: UUID?, with tabID: UUID) {
        if active == second { second = tabID }
        else { first = tabID }
    }

    func other(than tabID: UUID) -> UUID { tabID == first ? second : first }
}


public struct WorkspaceSplitCommands: Commands {
    @ObservedObject private var model: WorkspaceModel
    public init(model: WorkspaceModel) { self.model = model }

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(T("Split side by side")) { model.splitWorkspace(.sideBySide) }
                .keyboardShortcut("d", modifiers: .command)
            Button(T("Split top and bottom")) { model.splitWorkspace(.stacked) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(T("Close split view")) { model.closeSplit() }
                .disabled(model.split == nil)
        }
    }
}
