import AppKit
import AudioToolbox
import Carbon.HIToolbox
import CoreAudio
import MagicTrackCore

/// Routes actions to the system. Calls arrive on the engine queue.
final class SystemActions: ActionSink {
    let volume = VolumeController()
    let brightness = BrightnessController()

    func perform(_ action: Action) {
        switch action {
        case .keyDown(let k): KeyEmitter.post(k, down: true)
        case .keyUp(let k): KeyEmitter.post(k, down: false)
        case .adjust(.volume, let d): volume.adjust(by: d)
        case .adjust(.brightness, let d): brightness.adjust(by: d)
        }
    }
}

enum KeyEmitter {
    private static let source = CGEventSource(stateID: .hidSystemState)
    private static let codes: [NumKey: Int] = [
        .k0: kVK_ANSI_Keypad0, .k1: kVK_ANSI_Keypad1, .k2: kVK_ANSI_Keypad2, .k3: kVK_ANSI_Keypad3,
        .k4: kVK_ANSI_Keypad4, .k5: kVK_ANSI_Keypad5, .k6: kVK_ANSI_Keypad6, .k7: kVK_ANSI_Keypad7,
        .k8: kVK_ANSI_Keypad8, .k9: kVK_ANSI_Keypad9, .decimal: kVK_ANSI_KeypadDecimal,
        .multiply: kVK_ANSI_KeypadMultiply, .plus: kVK_ANSI_KeypadPlus, .clear: kVK_ANSI_KeypadClear,
        .divide: kVK_ANSI_KeypadDivide, .enter: kVK_ANSI_KeypadEnter, .minus: kVK_ANSI_KeypadMinus,
        .equals: kVK_ANSI_KeypadEquals,
    ]

    /// A password field has focus; synthetic keys are blocked.
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    static func post(_ key: NumKey, down: Bool) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(codes[key]!), keyDown: down)
        e?.flags = .maskNumericPad
        e?.post(tap: .cghidEventTap)
    }
}

/// Media-key fallback: converts fine deltas into fixed system steps (1/16 each).
struct MediaKeyStepper {
    let up: Int, down: Int
    private var pending = 0.0

    init(up: Int, down: Int) { self.up = up; self.down = down }

    mutating func add(_ delta: Double) {
        pending += delta
        while abs(pending) >= 1.0 / 16 {
            Self.press(pending > 0 ? up : down)
            pending -= pending > 0 ? 1.0 / 16 : -1.0 / 16
        }
    }

    static func press(_ key: Int) {
        for state in [0xA, 0xB] {   // down, up
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (key << 16) | (state << 8), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

final class VolumeController {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var fallback = MediaKeyStepper(up: 0, down: 1)   // NX_KEYTYPE_SOUND_UP / DOWN
    private var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                           mScope: kAudioDevicePropertyScopeOutput,
                                                           mElement: kAudioObjectPropertyElementMain)

    func listen(on queue: DispatchQueue) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        refresh()
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in self?.refresh() }
    }

    private func refresh() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) != noErr {
            device = AudioObjectID(kAudioObjectUnknown)
        }
    }

    var isAvailable: Bool { device != kAudioObjectUnknown }

    private var settable: Bool {
        var s: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &volumeAddress, &s) == noErr && s.boolValue
    }

    func read() -> Double? {
        guard isAvailable else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &v) == noErr ? Double(v) : nil
    }

    func adjust(by delta: Double) {
        guard settable, let current = read() else { return fallback.add(delta) }   // some HDMI / USB devices
        var v = Float32(min(1, max(0, current + delta)))
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}

final class BrightnessController {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let get: Get?
    private let set: Set?
    private var fallback = MediaKeyStepper(up: 2, down: 3)   // NX_KEYTYPE_BRIGHTNESS_UP / DOWN

    init() {
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        get = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
        set = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }
    }

    /// nil in clamshell mode: external displays are not adjusted in v1.
    var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    func read() -> Double? {
        guard let get, let display = builtInDisplay else { return nil }
        var v: Float = 0
        return get(display, &v) == 0 ? Double(v) : nil
    }

    func adjust(by delta: Double) {
        guard let display = builtInDisplay else { return }
        guard let set, let current = read() else { return fallback.add(delta) }
        _ = set(display, Float(min(1, max(0, current + delta))))
    }
}

enum Haptics {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Settings.hapticsEnabled else { return }
        DispatchQueue.main.async { NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now) }
    }
}
