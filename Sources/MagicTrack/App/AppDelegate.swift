import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = Engine()
    private lazy var menu = MenuBarController()
    private var onboarding: OnboardingWindow?
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        menu.onToggleEnabled = { [unowned self] _ in refresh() }
        menu.onOpenNumpad = { [unowned self] in engine.open() }
        menu.onGrantAccessibility = { [unowned self] in showOnboarding() }
        menu.onSaveRecording = { [unowned self] in
            do { NSWorkspace.shared.activateFileViewerSelecting([try engine.saveRecording()]) } catch { NSAlert(error: error).runModal() }
        }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in engine.close() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in engine.devicesChanged() }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [unowned self] _ in
            engine.close()
        }

        if PermissionManager.accessibilityGranted { refresh() } else { showOnboarding() }

        // Permission can be revoked at any time.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [unowned self] _ in refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()   // frees the cursor
    }

    private func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindow { [unowned self] in
                PermissionManager.requestInputMonitoring()
                refresh()
                showTipOnce()
            }
        }
        onboarding?.present()
    }

    /// Brings the engine in line with permissions and the Enabled setting.
    private func refresh() {
        guard engine.touchAvailable else {
            menu.status = .trackpadUnavailable
            return
        }
        guard PermissionManager.accessibilityGranted else {
            if engine.isRunning { engine.stop() }
            menu.status = .needsAccessibility
            return
        }
        menu.status = .ready
        if Settings.enabled, !engine.isRunning {
            if !engine.start() { menu.status = .needsAccessibility }
        } else if !Settings.enabled, engine.isRunning {
            engine.stop()
        }
    }

    private func showTipOnce() {
        guard !Settings.tipShown else { return }
        Settings.tipShown = true
        let alert = NSAlert()
        alert.messageText = "MagicTrack is ready"
        alert.informativeText = "Tap with five fingers to open the numpad."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
