import AppKit
import IOKit.hidsystem
import SwiftUI

@main
struct XPdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MappingStore()

    var body: some Scene {
        WindowGroup("XP[d]", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 980, height: 650)

        MenuBarExtra("XP[d]", systemImage: "smallcircle.filled.circle") {
            MenuBarView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }
}

private struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    let store: MappingStore

    var body: some View {
        Text(store.hid.isConnected ? "Shortcut Remote connected" : "Shortcut Remote disconnected")
        Divider()
        Toggle("Show Input Overlay", isOn: Bindable(store).showsInputOverlay)
        Button("Preview Input Overlay") {
            store.previewInputOverlay()
        }
        .disabled(!store.showsInputOverlay)
        Divider()
        Button("Open XP[d]") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
