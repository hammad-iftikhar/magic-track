import AppKit
import MagicTrackCore

/// Wires touch → gesture → zones → actions → overlay. All state lives on `queue`.
final class Engine {
    let queue = DispatchQueue(label: "MagicTrack.engine", qos: .userInteractive)
    let model = OverlayModel()
    private let touch = TouchEngine.shared
    private let tap = EventTapController()
    private let actions = SystemActions()
    private lazy var dispatcher = ActionDispatcher(sink: actions)
    private lazy var panel = OverlayPanel(model: model)   // main thread only

    private var gesture = GestureStateMachine()
    private var layout = Layout()
    private var slider = SliderTracker()
    private var palmFactor = 1.5
    private var aspect = 1.6
    private var latest: TouchFrame?
    private var recording: [TouchFrame] = []
    private var timer: DispatchSourceTimer?
    private var restartPending = false

    private var pendingState: OverlayState?
    private var flushScheduled = false

    var touchAvailable: Bool { touch.isAvailable }

    init() {
        touch.onFrame = { [unowned self] in handle($0) }
        touch.onDevicesChanged = { [unowned self] in devicesChanged() }
        tap.onClick = { [unowned self] down in queue.async { self.click(down: down) } }
        tap.onCloseRequest = { [unowned self] in queue.async { self.deactivate() } }
        actions.volume.listen(on: queue)
    }

    // MARK: Lifecycle (call from main)

    /// Installs the tap and starts the trackpads. Returns false if the tap couldn't be created (no Accessibility).
    func start() -> Bool {
        guard tap.install() else { return false }
        queue.sync {
            touch.start(on: queue)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25)
            t.setEventHandler { [unowned self] in tick() }
            t.resume()
            timer?.cancel()
            timer = t
        }
        return true
    }

    func stop() {
        queue.sync {
            deactivate()
            timer?.cancel()
            timer = nil
            touch.stop()
        }
        tap.remove()
    }

    var isRunning: Bool { tap.isInstalled }

    func open() { queue.async { self.activate(deviceID: nil) } }
    func close() { queue.async { self.deactivate() } }

    func devicesChanged() {
        queue.async { [self] in
            guard !restartPending else { return }
            restartPending = true
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                restartPending = false
                guard timer != nil else { return }
                // ponytail: device ids are pointers and change on re-enumeration, so any device change closes the overlay.
                deactivate()
                touch.start(on: queue)
            }
        }
    }

    // MARK: Engine queue

    private func handle(_ frame: TouchFrame) {
        recording.append(frame)
        if let first = recording.first, frame.timestamp - first.timestamp > 10 {
            recording.removeAll { frame.timestamp - $0.timestamp > 10 }
        }

        switch gesture.feed(frame) {
        case .activate(let id)?: activate(deviceID: id)
        case .deactivate?: deactivate()
        case nil: break
        }
        guard gesture.isActive, gesture.accepts(frame) else { return }

        latest = frame
        for out in slider.update(contacts: frame.contacts, layout: layout) {
            switch out {
            case .adjust(let kind, let d): dispatcher.adjust(kind, by: d)
            case .tick(let strong): Haptics.perform(strong ? .levelChange : .alignment)
            }
        }
        publish()
    }

    private func click(down: Bool) {
        guard gesture.isActive else { return }
        if down {
            guard !KeyEmitter.secureInputActive else { return publish() }
            let primary = latest.flatMap { primaryContact(in: $0.contacts, palmFactor: palmFactor) }
            if dispatcher.clickDown(primary.map { layout.zone(x: $0.x, y: $0.y) }) != nil {
                Haptics.perform(.generic)
            }
        } else {
            dispatcher.clickUp()
        }
        publish()
    }

    private func tick() {
        if gesture.tick(now: ProcessInfo.processInfo.systemUptime) == .deactivate { deactivate() }
    }

    private func activate(deviceID: Int?) {
        if !gesture.isActive { gesture.activate(deviceID: deviceID, now: ProcessInfo.processInfo.systemUptime) }
        // Settings take effect on the next open.
        layout = Layout(grid: Settings.gridLayout, sliderSide: Settings.sliderSide)
        palmFactor = Settings.palmSizeFactor
        gesture.idleTimeout = Settings.idleTimeout
        gesture.config.palmFactor = palmFactor
        slider = SliderTracker(sensitivity: Settings.sliderSensitivity)
        slider.values = [.brightness: actions.brightness.read(), .volume: actions.volume.read()]
        aspect = deviceID.flatMap { touch.aspectRatios[$0] } ?? touch.aspectRatios.values.first ?? 1.6
        latest = nil

        tap.swallowing = true
        CursorLock.lock()
        let aspect = aspect
        publish()
        DispatchQueue.main.async { self.panel.show(aspect: aspect) }
    }

    /// Every exit path lands here; safe to call twice.
    private func deactivate() {
        dispatcher.clickUp()   // never leave a key held down
        gesture.deactivate(now: ProcessInfo.processInfo.systemUptime)
        tap.swallowing = false
        CursorLock.unlock()
        latest = nil
        DispatchQueue.main.async { self.panel.hide() }
    }

    /// Coalesces overlay updates to at most 60 Hz.
    private func publish() {
        let primary = latest.flatMap { primaryContact(in: $0.contacts, palmFactor: palmFactor) }
        let builtIn = actions.brightness.builtInDisplay != nil
        let banners = [KeyEmitter.secureInputActive ? "Secure input active" : nil, builtIn ? nil : "Built-in only"]
        pendingState = OverlayState(
            layout: layout,
            contacts: latest?.contacts.filter(\.isDown) ?? [],
            primaryID: primary?.id,
            highlightedKey: layout.key(at: primary),
            pressedKey: dispatcher.pressed,
            brightness: builtIn ? (slider.values[.brightness] ?? nil) : nil,
            volume: actions.volume.isAvailable ? (slider.values[.volume] ?? nil) : nil,
            banner: banners.compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            flushScheduled = false
            guard let s = pendingState else { return }
            DispatchQueue.main.async { self.model.state = s }
        }
    }

    // MARK: Fixture recorder

    /// Writes the last 10 s of frames to Application Support and returns the file URL.
    func saveRecording() throws -> URL {
        let frames = queue.sync { recording }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicTrack/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(ISO8601DateFormatter().string(from: Date())).json")
        try JSONEncoder().encode(frames).write(to: url)
        return url
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
