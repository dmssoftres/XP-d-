import AppKit
import SwiftUI

/// Provides true behind-window blur for the borderless input panel.
struct OverlayGlassMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .titlebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = nil
        view.alphaValue = 1
    }
}

/// Keeps the HUD's native blur isolated from its content and clipping.
struct OverlayGlassSurface: View {
    var body: some View {
        OverlayGlassMaterial()
            .allowsHitTesting(false)
    }
}
