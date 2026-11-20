import AppKit
import SwiftUI

/// Two panes with a draggable divider. New splits start even, and neither side shrinks below
/// `minimum` unless the space is too small for both, so a pane can never be squeezed out of view.
struct PaneSplitView<First: View, Second: View>: View {
    let axis: WorkspaceSplitAxis
    @Binding var ratio: CGFloat
    let first: First
    let second: Second
    let dividerColor: Color
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    private var minimum: CGFloat { axis == .sideBySide ? 220 : 120 }
    private static var gap: CGFloat { 6 }

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .sideBySide ? proxy.size.width : proxy.size.height
            let available = max(total - Self.gap, 0)
            let firstLength = Self.firstLength(ratio: ratio, available: available, minimum: minimum)
            let layout = axis == .sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first.frame(width: axis == .sideBySide ? firstLength : nil, height: axis == .stacked ? firstLength : nil)
                divider(available: available)
                second.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    static func firstLength(ratio: CGFloat, available: CGFloat, minimum: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        let floor = min(minimum, available / 2)
        return min(max(available * ratio, floor), available - floor).rounded()
    }

    private func divider(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(dividerColor.opacity(hovering || dragStart != nil ? 0.55 : 0))
                .frame(width: axis == .sideBySide ? 3 : 36, height: axis == .sideBySide ? 36 : 3)
        }
        .frame(width: axis == .sideBySide ? Self.gap : nil, height: axis == .stacked ? Self.gap : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { (axis == .sideBySide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard available > 0 else { return }
                let start = dragStart ?? ratio
                if dragStart == nil { dragStart = start }
                let delta = axis == .sideBySide ? value.translation.width : value.translation.height
                ratio = min(max(start + delta / available, 0.05), 0.95)
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) { ratio = 0.5 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
