import AppKit
import ServiceManagement
import SwiftUI

final class MenuBarController: NSObject, NSMenuDelegate {
    enum Status: String { case ready = "Ready", needsAccessibility = "Needs Accessibility", trackpadUnavailable = "Trackpad unavailable" }

    var status = Status.ready { didSet { updateIcon() } }
    var onToggleEnabled: ((Bool) -> Void)?
    var onOpenNumpad: (() -> Void)?
    var onGrantAccessibility: (() -> Void)?
    var onSaveRecording: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var settingsWindow: NSWindow?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        let name = status == .ready ? "keyboard" : "exclamationmark.triangle"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "MagicTrack")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let statusText = status == .trackpadUnavailable ? "Trackpad access unavailable on this macOS version" : status.rawValue
        menu.addItem(NSMenuItem(title: statusText, action: nil, keyEquivalent: ""))
        if status == .needsAccessibility { add(menu, "Grant Accessibility…", #selector(grant)) }
        menu.addItem(.separator())
        add(menu, "Enabled", #selector(toggleEnabled)).state = Settings.enabled ? .on : .off
        add(menu, "Open Numpad", #selector(openNumpad)).isEnabled = status == .ready && Settings.enabled
        add(menu, "Settings…", #selector(openSettings), key: ",")
        add(menu, "Launch at Login", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        add(menu, "Save Touch Recording", #selector(saveRecording))
        menu.addItem(.separator())
        add(menu, "About MagicTrack", #selector(about))
        add(menu, "Quit MagicTrack", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func grant() { onGrantAccessibility?() }
    @objc private func openNumpad() { onOpenNumpad?() }
    @objc private func saveRecording() { onSaveRecording?() }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        onToggleEnabled?(Settings.enabled)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "MagicTrack Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @AppStorage("gridLayout") private var gridLayout = "4x4"
    @AppStorage("sliderSide") private var sliderSide = "right"
    @AppStorage("idleTimeout") private var idleTimeout = 4.0
    @AppStorage("sliderSensitivity") private var sensitivity = 1.0
    @AppStorage("overlayScale") private var overlayScale = 1.0
    @AppStorage("palmSizeFactor") private var palmSizeFactor = 1.5
    @AppStorage("hapticsEnabled") private var haptics = true

    var body: some View {
        Form {
            Picker("Grid", selection: $gridLayout) { Text("4 × 4").tag("4x4"); Text("4 × 5").tag("4x5") }
            Picker("Sliders on", selection: $sliderSide) { Text("Right").tag("right"); Text("Left").tag("left") }
            slider("Idle timeout", $idleTimeout, 2...15, format: "%.0f s")
            slider("Slider sensitivity", $sensitivity, 0.5...2, format: "%.1f×")
            slider("Overlay size", $overlayScale, 0.75...1.5, format: "%.2f×")
            slider("Palm rejection", $palmSizeFactor, 1.2...2.5, format: "%.1f×")
            Toggle("Haptic feedback", isOn: $haptics)
            Text("Changes apply the next time the numpad opens.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}
