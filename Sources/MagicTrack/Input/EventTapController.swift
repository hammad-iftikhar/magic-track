import AppKit
import os

/// One active tap, installed for the app's lifetime on its own thread. A flag decides pass vs swallow,
/// so opening the overlay has no setup latency.
final class EventTapController {
    /// Called on the tap thread.
    var onClick: ((_ down: Bool) -> Void)?
    var onCloseRequest: (() -> Void)?

    private let swallow = OSAllocatedUnfairLock(initialState: false)
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    var swallowing: Bool {
        get { swallow.withLock { $0 } }
        set { swallow.withLock { $0 = newValue } }
    }

    private static let mask: CGEventMask = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp]
        // Raw gesture types: rotate, begin/end, gesture, magnify, swipe, smart magnify, pressure.
        let raw: [UInt32] = [18, 19, 20, 29, 30, 31, 32, 34]
        return (types.map(\.rawValue) + raw).reduce(0) { $0 | (1 << CGEventMask($1)) }
    }()

    var isInstalled: Bool { tap != nil }

    func install() -> Bool {
        guard tap == nil else { return true }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: Self.mask, callback: { _, type, event, refcon in
            Unmanaged<EventTapController>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "MagicTrack.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func remove() {
        swallowing = false
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        runLoop = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if swallowing { onCloseRequest?() }
            return pass
        }
        guard swallowing else { return pass }

        switch type {
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return pass }   // Esc
            onCloseRequest?()
            return nil
        case .keyUp:
            return pass
        case .leftMouseDown:
            onClick?(true)
            return nil
        case .leftMouseUp:
            onClick?(false)
            return nil
        default:
            return nil
        }
    }
}

/// Freezes the pointer while the overlay is open. Idempotent in both directions.
enum CursorLock {
    private static let locked = OSAllocatedUnfairLock(initialState: false)

    static func lock() {
        guard locked.withLock({ let was = $0; $0 = true; return !was }) else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        // ponytail: the window server may ignore a background app's hide; the cursor then stays visible but frozen.
        CGDisplayHideCursor(CGMainDisplayID())
    }

    static func unlock() {
        guard locked.withLock({ let was = $0; $0 = false; return was }) else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
    }
}
