import AppKit
import SwiftUI

enum PermissionManager {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// The keyboard part of the event tap (Esc) may need Input Monitoring.
    static func requestInputMonitoring() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
    }
}

/// Explains the permissions and polls every second until Accessibility is granted.
final class OnboardingWindow: NSWindow {
    private var poll: Timer?
    private var onGranted: (() -> Void)?

    init(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Welcome to MagicTrack"
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: OnboardingView())
        center()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        PermissionManager.promptAccessibility()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, PermissionManager.accessibilityGranted else { return }
            poll?.invalidate()
            close()
            onGranted?()
        }
    }

    override func close() {
        poll?.invalidate()
        super.close()
    }
}

private struct OnboardingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MagicTrack turns your trackpad into a numpad with brightness and volume sliders.")
                .font(.headline)
            Label("**Accessibility** lets MagicTrack pause the cursor while the numpad is open and type keypad keys into the app you're using.",
                  systemImage: "hand.raised")
            Label("**Input Monitoring** may be requested so Esc can close the numpad.", systemImage: "keyboard")
            Spacer()
            HStack {
                Text("Waiting for permission…").foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings") { PermissionManager.openAccessibilitySettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 260)
    }
}
