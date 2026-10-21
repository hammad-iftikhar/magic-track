import Foundation

public struct TriggerConfig {
    public var armWindow: TimeInterval = 0.100   // all five down within this span
    public var tapWindow: TimeInterval = 0.300   // all five lifted within this time of the first touch
    public var maxMovement = 0.03                // per contact, from its start point
    public var fingers = 5
    public var palmFactor = 1.5
    public init() {}
}

/// Detects one five-finger tap. Feed it every frame from one device.
public struct TriggerDetector {
    public var config: TriggerConfig
    private var start: TimeInterval?
    private var origins: [Int: (x: Double, y: Double)] = [:]
    private var failed = false

    public init(config: TriggerConfig = .init()) { self.config = config }

    public var isArming: Bool { start != nil }

    /// True when this frame completes a valid tap.
    public mutating func feed(_ frame: TouchFrame) -> Bool {
        let live = frame.contacts.filter(\.isDown)
        if start == nil {
            guard !live.isEmpty else { return false }
            start = frame.timestamp
        }
        let elapsed = frame.timestamp - start!

        for c in live {
            if let o = origins[c.id] {
                if hypot(c.x - o.x, c.y - o.y) > config.maxMovement { failed = true }   // pinch or swipe
            } else {
                if elapsed > config.armWindow { failed = true }                          // slow placement
                origins[c.id] = (c.x, c.y)
            }
        }
        if origins.count > config.fingers { failed = true }
        if live.count > 1 {
            let median = live.map(\.size).sorted()[live.count / 2]
            if live.contains(where: { $0.size > config.palmFactor * median }) { failed = true }
        }

        guard live.isEmpty else { return false }
        defer { self = TriggerDetector(config: config) }
        return !failed && origins.count == config.fingers && elapsed <= config.tapWindow
    }
}

public enum GestureEvent: Equatable { case activate(deviceID: Int), deactivate }

/// Idle → Arming → Active → Cooldown. Only Active changes how input is treated.
public struct GestureStateMachine {
    public enum State: Equatable { case idle, arming, active, cooldown }

    public var config: TriggerConfig { didSet { detectors = [:] } }
    public var idleTimeout: TimeInterval = 4
    public var cooldown: TimeInterval = 0.4

    public private(set) var isActive = false
    /// Device that drives the overlay while active; nil when opened without a trigger (menu item).
    public private(set) var activeDevice: Int?

    private var detectors: [Int: TriggerDetector] = [:]
    private var lastTouch: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0
    private var lastTime: TimeInterval = 0

    public init(config: TriggerConfig = .init()) { self.config = config }

    public var state: State {
        if isActive { return .active }
        if lastTime < cooldownUntil { return .cooldown }
        return detectors.values.contains(where: \.isArming) ? .arming : .idle
    }

    public func accepts(_ frame: TouchFrame) -> Bool {
        !isActive || activeDevice == nil || activeDevice == frame.deviceID
    }

    public mutating func feed(_ frame: TouchFrame) -> GestureEvent? {
        guard accepts(frame) else { return nil }   // second trackpad is ignored while active
        lastTime = frame.timestamp
        if frame.contacts.contains(where: \.isDown) { lastTouch = frame.timestamp }

        var detector = detectors[frame.deviceID] ?? TriggerDetector(config: config)
        let fired = detector.feed(frame)
        detectors[frame.deviceID] = detector
        guard fired, frame.timestamp >= cooldownUntil else { return nil }

        if isActive {
            deactivate(now: frame.timestamp)
            return .deactivate
        }
        activate(deviceID: frame.deviceID, now: frame.timestamp)
        return .activate(deviceID: frame.deviceID)
    }

    /// Call periodically; closes the overlay after `idleTimeout` with no contacts.
    public mutating func tick(now: TimeInterval) -> GestureEvent? {
        lastTime = now
        guard isActive, now - lastTouch >= idleTimeout else { return nil }
        deactivate(now: now)
        return .deactivate
    }

    public mutating func activate(deviceID: Int?, now: TimeInterval) {
        isActive = true
        activeDevice = deviceID
        lastTouch = now
        cooldownUntil = now + cooldown
    }

    /// Safe to call twice.
    public mutating func deactivate(now: TimeInterval) {
        if isActive { cooldownUntil = now + cooldown }
        isActive = false
        activeDevice = nil
    }
}
