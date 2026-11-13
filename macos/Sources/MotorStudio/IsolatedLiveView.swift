import AppKit
import SwiftUI

/// A fixed-size hosting boundary keeps live content from invalidating the workspace layout.
/// Its parent supplies the height; SwiftUI still handles resizing and accessibility inside it.
struct IsolatedLiveView<Content: View>: NSViewRepresentable {
    @Environment(StudioModel.self) private var model
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: root)
        view.sizingOptions = []
        return view
    }
    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) { view.rootView = root }
    private var root: AnyView { AnyView(content.environment(model).preferredColorScheme(.dark).tint(StudioTheme.mint)) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 260)
    }
}
