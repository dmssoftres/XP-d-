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
                .frame(minWidth: 860, minHeight: 640)
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
        if store.hid.isConnected {
            Label(menuBarBatteryStatus, systemImage: menuBarBatterySymbol)
                .foregroundStyle(menuBarBatteryColor)
        }
        Divider()
        Toggle("Show Input Overlay", isOn: Bindable(store).showsInputOverlay)
        Picker("Hide Overlay After", selection: Bindable(store).inputOverlayDuration) {
            ForEach(MappingStore.inputOverlayDurationOptions, id: \.self) { duration in
                Text("\(duration.formatted()) seconds").tag(duration)
            }
        }
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

    private var menuBarBatteryStatus: String {
        guard let percentage = store.hid.batteryPercentage else {
            return "Battery unavailable"
        }
        return "Battery \(percentage)%"
    }

    private var menuBarBatteryColor: Color {
        guard let percentage = store.hid.batteryPercentage else {
            return .secondary
        }
        if percentage <= 10 { return .red }
        if percentage <= 20 { return .orange }
        return .secondary
    }

    private var menuBarBatterySymbol: String {
        guard let percentage = store.hid.batteryPercentage else {
            return "questionmark.circle"
        }
        switch percentage {
        case 90...100: return "battery.100percent"
        case 75..<90: return "battery.75percent"
        case 50..<75: return "battery.50percent"
        case 25..<50: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
