import Foundation
import IOKit
import MTBridge
import MagicTrackCore

/// The C callback can't capture context, so it forwards to the singleton.
private let contactCallback: MTFrameCallback = { device, touches, count, _, _ in
    TouchEngine.shared.receive(device: device, touches: touches, count: Int(count))
    return 0
}

/// Loads MultitouchSupport at runtime and emits `TouchFrame`s on the engine queue.
/// A missing symbol disables trackpad input instead of crashing at launch.
final class TouchEngine: TouchSource {
    static let shared = TouchEngine()

    var onFrame: ((TouchFrame) -> Void)?
    var onDevicesChanged: (() -> Void)?
    private(set) var aspectRatios: [Int: Double] = [:]

    private struct API {
        let createList: MTDeviceCreateListFn
        let register: MTRegisterContactFrameCallbackFn
        let unregister: MTRegisterContactFrameCallbackFn
        let start: MTDeviceStartFn
        let stop: MTDeviceStopFn
        let dimensions: MTDeviceGetSensorSurfaceDimensionsFn?
    }

    private let api: API? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let createList = sym("MTDeviceCreateList", MTDeviceCreateListFn.self),
              let register = sym("MTRegisterContactFrameCallback", MTRegisterContactFrameCallbackFn.self),
              let unregister = sym("MTUnregisterContactFrameCallback", MTRegisterContactFrameCallbackFn.self),
              let start = sym("MTDeviceStart", MTDeviceStartFn.self),
              let stop = sym("MTDeviceStop", MTDeviceStopFn.self)
        else { return nil }
        return API(createList: createList, register: register, unregister: unregister, start: start, stop: stop,
                   dimensions: sym("MTDeviceGetSensorSurfaceDimensions", MTDeviceGetSensorSurfaceDimensionsFn.self))
    }()

    var isAvailable: Bool { api != nil }

    private static let logRaw = ProcessInfo.processInfo.environment["MAGICTRACK_LOG_TOUCHES"] != nil
    private struct Raw { let id: Int32, state: Int32, x: Double, y: Double, size: Double }

    // Set once in start(); everything below is touched only on `queue`.
    private var queue: DispatchQueue?
    private var list: CFArray?
    private var devices: [MTDeviceRef] = []
    private var live: [Int: [Int32: Contact]] = [:]   // per device, keyed by MT identifier
    private var nextID = 0
    private var notifyPort: IONotificationPortRef?

    // MARK: Callback thread: copy and hop, nothing else.

    fileprivate func receive(device: MTDeviceRef?, touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        guard let queue else { return }
        let raw = UnsafeBufferPointer(start: touches, count: count).map {
            Raw(id: $0.identifier, state: $0.state, x: Double($0.normalized.position.x),
                y: Double($0.normalized.position.y), size: Double($0.size))
        }
        let deviceID = Int(bitPattern: device)
        let now = ProcessInfo.processInfo.systemUptime
        if Self.logRaw {
            for r in raw { print(String(format: "dev %x id %d state %d x %.3f y %.3f size %.2f", deviceID, r.id, r.state, r.x, r.y, r.size)) }
        }
        queue.async { self.emit(raw, deviceID: deviceID, time: now) }
    }

    // MARK: Engine queue

    private func emit(_ raw: [Raw], deviceID: Int, time: TimeInterval) {
        let previous = live[deviceID] ?? [:]
        var current: [Int32: Contact] = [:]
        var contacts: [Contact] = []
        for r in raw {
            let down = (3...5).contains(r.state)   // 6-7 = lifting
            if let p = previous[r.id] {
                let moved = abs(r.x - p.x) + abs(r.y - p.y) > 1e-4
                let c = Contact(id: p.id, x: r.x, y: r.y, size: r.size, phase: !down ? .ended : moved ? .moved : .stationary)
                contacts.append(c)
                if down { current[r.id] = c }
            } else if down {
                // Fresh increasing id per touch, so "highest id" means "most recent finger".
                nextID += 1
                let c = Contact(id: nextID, x: r.x, y: r.y, size: r.size, phase: .began)
                contacts.append(c)
                current[r.id] = c
            }
        }
        for (rid, p) in previous where !raw.contains(where: { $0.id == rid }) {
            contacts.append(Contact(id: p.id, x: p.x, y: p.y, size: p.size, phase: .ended))
        }
        live[deviceID] = current
        onFrame?(TouchFrame(contacts: contacts, timestamp: time, deviceID: deviceID))
    }

    /// (Re)enumerates every trackpad. Call on `queue`.
    @discardableResult
    func start(on queue: DispatchQueue) -> Bool {
        guard let api else { return false }
        self.queue = queue
        stop()
        guard let list = api.createList()?.takeRetainedValue() else { return false }
        self.list = list
        for i in 0..<CFArrayGetCount(list) {
            let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))!
            var w: Int32 = 0, h: Int32 = 0
            _ = api.dimensions?(dev, &w, &h)
            aspectRatios[Int(bitPattern: dev)] = w > 0 && h > 0 ? Double(w) / Double(h) : 1.6
            api.register(dev, contactCallback)
            api.start(dev, 0)
            devices.append(dev)
        }
        watchHotplug()
        return !devices.isEmpty
    }

    func stop() {
        guard let api else { return }
        for dev in devices {
            api.unregister(dev, contactCallback)
            api.stop(dev)
        }
        devices = []
        list = nil
        live = [:]
        aspectRatios = [:]
    }

    private func watchHotplug() {
        guard notifyPort == nil, let queue, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iter: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleMultitouchDevice"), { _, iter in
                TouchEngine.drain(iter)
                TouchEngine.shared.onDevicesChanged?()
            }, nil, &iter)
            Self.drain(iter)   // arms the notification
        }
        notifyPort = port
    }

    private static func drain(_ iter: io_iterator_t) {
        while case let obj = IOIteratorNext(iter), obj != 0 { IOObjectRelease(obj) }
    }
}
