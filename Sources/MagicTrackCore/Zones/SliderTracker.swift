import Foundation

/// Turns vertical finger movement on the edge strips into throttled value changes and haptic ticks.
public struct SliderTracker {
    public enum Output: Equatable { case adjust(SliderKind, Double), tick(strong: Bool) }

    public static let step = 1.0 / 64

    public var sensitivity: Double
    /// Current level per strip, seeded from the system on activation. nil = unknown (no clamping or ticks).
    public var values: [SliderKind: Double?] = [:]

    private var captured: [Int: (kind: SliderKind, lastY: Double)] = [:]
    private var pending: [SliderKind: Double] = [:]

    public init(sensitivity: Double = 1.0) { self.sensitivity = sensitivity }

    public mutating func update(contacts: [Contact], layout: Layout) -> [Output] {
        var out: [Output] = []
        for c in contacts {
            if !c.isDown { captured[c.id] = nil; continue }
            if let cap = captured[c.id] {
                // Captured until lift, even if the finger drifts out sideways.
                captured[c.id]!.lastY = c.y
                out += apply((c.y - cap.lastY) / layout.stripHeight * sensitivity, to: cap.kind)
            } else if c.phase == .began, case .slider(let kind) = layout.zone(x: c.x, y: c.y) {
                captured[c.id] = (kind, c.y)
            }
        }
        return out
    }

    private mutating func apply(_ delta: Double, to kind: SliderKind) -> [Output] {
        let acc = pending[kind, default: 0] + delta
        guard abs(acc) >= Self.step else { pending[kind] = acc; return [] }
        pending[kind] = 0
        guard let old = values[kind] ?? nil else { return [.adjust(kind, acc)] }

        let new = min(1, max(0, old + acc))
        guard new != old else { return [] }
        values[kind] = new
        var out: [Output] = [.adjust(kind, new - old)]
        if new == 0 || new == 1 {
            out.append(.tick(strong: true))
        } else if tenth(old) != tenth(new) {
            out.append(.tick(strong: false))
        }
        return out
    }

    private func tenth(_ v: Double) -> Int { Int((v * 10 + 1e-9).rounded(.down)) }
}
