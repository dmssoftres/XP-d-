import AppKit
import IOKit.hidsystem
import SwiftUI

@main
struct XPdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: MappingStore
    private let mainWindowController: MainWindowController

    init() {
        let mainWindowController = MainWindowController()
        self.mainWindowController = mainWindowController
        _store = State(initialValue: MappingStore(mainWindowToggle: { [weak mainWindowController] in
            mainWindowController?.toggle() ?? .failure("XP[d] window is unavailable")
        }, runModeTransition: { [weak mainWindowController] enabled in
            mainWindowController?.setRunMode(enabled)
                ?? .failure("XP[d] window is unavailable")
        }))
    }

    /// While a text field has its own typing to undo, ⌘Z undoes that text;
    /// otherwise it undoes the last key-layout change.
    @MainActor
    private static func undoOrForward(store: MappingStore, redo: Bool) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let textUndo = textView.undoManager,
           redo ? textUndo.canRedo : textUndo.canUndo {
            _ = redo ? textUndo.redo() : textUndo.undo()
            return
        }
        let didChange = redo ? store.redo() : store.undo()
        if !didChange { NSSound.beep() }
    }

    var body: some Scene {
        WindowGroup("XP[d]", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 860, minHeight: 640)
                .background(MainWindowRegistrationView(controller: mainWindowController))
        }
        .defaultSize(width: 964, height: 709)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { Self.undoOrForward(store: store, redo: false) }
                    .keyboardShortcut("z")
                Button("Redo") { Self.undoOrForward(store: store, redo: true) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(nsImage: MenuBarIcon.image(midiLocked: store.activeRealm == .midi))
                .accessibilityLabel(store.activeRealm == .midi ? "XP[d], MIDI Lock active" : "XP[d]")
        }
    }
}

/// MenuBarExtra flattens nested SwiftUI labels into separate status-item
/// elements. Render both marks into one template image so the MIDI badge is
/// attached to the XP[d] icon instead of becoming a second menu-bar item.
private enum MenuBarIcon {
    static func image(midiLocked: Bool) -> NSImage {
        let size = NSSize(width: midiLocked ? 25 : 15, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        drawSymbol("smallcircle.filled.circle", in: NSRect(x: 0, y: 2, width: 15, height: 15))
        if midiLocked {
            drawSymbol("m.circle", in: NSRect(x: 12, y: 0, width: 12, height: 12))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawSymbol(_ name: String, in rect: NSRect) {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.draw(in: rect)
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
        Text("XP[d] \(AppVersion.display)")
        Divider()
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
        Text("Profile: \(store.profileName)")
        Label(
            store.midiLocked ? "MIDI Lock" : "Standard",
            systemImage: store.midiLocked ? "pianokeys" : "slider.horizontal.3"
        )
        Button(store.profileRealm == .midi ? "Leave MIDI Lock" : "Enter MIDI Lock") {
            _ = store.toggleWorkspace()
        }
        .disabled(store.profileRealm != .midi && store.midiProfiles.isEmpty)
        if store.profileRealm != .midi && store.midiProfiles.isEmpty {
            Text("Create a MIDI profile to enter MIDI Lock")
        }
        profileSelectionMenu
        if store.profileRealm == .midi {
            midiOutputMenu
        }
        Divider()
        Button("Open XP[d]") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }

    @ViewBuilder
    private var profileSelectionMenu: some View {
        Menu("Select Profile") {
            profileRealmMenu(.standard)
            profileRealmMenu(.midi)
        }
    }

    @ViewBuilder
    private func profileRealmMenu(_ realm: ProfileRealm) -> some View {
        let profiles = store.availableProfiles.filter { store.profileRealm(for: $0) == realm }
        Menu(realm == .midi ? "MIDI" : "Standard") {
            if profiles.isEmpty {
                Text(realm == .midi ? "No MIDI profiles" : "No standard profiles")
            } else {
                ForEach(profiles, id: \.self) { profile in
                    Button {
                        _ = store.selectProfile(profile)
                    } label: {
                        if store.profileName == profile {
                            Label(profile, systemImage: "checkmark")
                        } else {
                            Text(profile)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var midiOutputMenu: some View {
        Menu("MIDI Output") {
            midiEndpointLabel(for: .control)
            midiEndpointLabel(for: .performance)
            if let message = store.lastMessage {
                Divider()
                Text("Last: \(message.summary)")
                    .lineLimit(2)
            }
            if let error = store.lastError {
                Text("Error: \(error)")
                    .lineLimit(2)
            }
            Divider()
            Button("Refresh MIDI Status") {
                store.refreshMIDIEndpointStatus()
            }
            Button("Panic MIDI", role: .destructive) {
                store.panicMIDI()
            }
        }
    }

    @ViewBuilder
    private func midiEndpointLabel(for port: MIDIOutputPort) -> some View {
        let status = store.endpointStatuses[port]
        let available = status?.isAvailable == true
        Label(
            "\(port.displayName): \(available ? "Available" : "Unavailable")",
            systemImage: available ? "checkmark.circle" : "xmark.circle"
        )
        .foregroundStyle(available ? .primary : .secondary)
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
