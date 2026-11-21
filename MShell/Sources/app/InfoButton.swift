import SwiftUI

/// A small ⓘ-style "!" button that shows an explanation in a popover, in place of a paragraph of fine print.
struct InfoButton: View {
    let text: String
    @State private var showing = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(T("About this setting"))
        .accessibilityHint(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}
