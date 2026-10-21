import Foundation

/// Pairs key down/up so the key that went down is the one released, even if the finger drifts.
public final class ActionDispatcher {
    private let sink: ActionSink
    public private(set) var pressed: NumKey?

    public init(sink: ActionSink) { self.sink = sink }

    /// Returns the key that went down, if any.
    @discardableResult
    public func clickDown(_ zone: Zone?) -> NumKey? {
        guard pressed == nil, case .key(let k)? = zone else { return nil }
        pressed = k
        sink.perform(.keyDown(k))
        return k
    }

    public func clickUp() {
        guard let k = pressed else { return }
        pressed = nil
        sink.perform(.keyUp(k))
    }

    public func adjust(_ kind: SliderKind, by delta: Double) {
        sink.perform(.adjust(kind, delta: delta))
    }
}
