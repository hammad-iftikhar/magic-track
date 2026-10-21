import Foundation

public struct Rect: Equatable {
    public var minX, maxX, minY, maxY: Double

    public init(x: ClosedRange<Double>, y: ClosedRange<Double>) {
        minX = x.lowerBound; maxX = x.upperBound; minY = y.lowerBound; maxY = y.upperBound
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }

    public func contains(x: Double, y: Double) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
    public func insetBy(_ d: Double) -> Rect { Rect(x: (minX + d)...(maxX - d), y: (minY + d)...(maxY - d)) }
    func offsetBy(dx: Double) -> Rect { Rect(x: (minX + dx)...(maxX + dx), y: minY...maxY) }
    func mirrored() -> Rect { Rect(x: (1 - maxX)...(1 - minX), y: minY...maxY) }
    func union(_ o: Rect) -> Rect { Rect(x: min(minX, o.minX)...max(maxX, o.maxX), y: min(minY, o.minY)...max(maxY, o.maxY)) }
}

public enum GridLayout: String, CaseIterable { case fourByFour = "4x4", fourByFive = "4x5" }
public enum SliderSide: String, CaseIterable { case right, left }

public struct KeyCell: Equatable {
    public let key: NumKey
    public let rect: Rect
}

/// All geometry in normalized trackpad coordinates (x right, y up, 0...1), shared by the overlay and hit testing.
public struct Layout: Equatable {
    public let grid: Rect
    public let keys: [KeyCell]
    public let strips: [SliderKind: Rect]
    public let keyInset = 0.01

    static let rows4x4: [[NumKey?]] = [
        [.k7, .k8, .k9, .divide],
        [.k4, .k5, .k6, .multiply],
        [.k1, .k2, .k3, .minus],
        [.k0, .decimal, .enter, .plus],
    ]
    // ponytail: the spec's two spare top-row cells take − and +, which the tall Enter displaces from column 4.
    static let rows4x5: [[NumKey?]] = [
        [.clear, .equals, .minus, .plus],
        [.k7, .k8, .k9, .divide],
        [.k4, .k5, .k6, .multiply],
        [.k1, .k2, .k3, .enter],
        [.k0, .decimal, nil, .enter],
    ]

    public init(grid kind: GridLayout = .fourByFour, sliderSide: SliderSide = .right) {
        let rows = kind == .fourByFour ? Self.rows4x4 : Self.rows4x5
        let gap = 0.015
        var grid = Rect(x: 0.03...0.80, y: 0.04...0.96)
        var strips: [SliderKind: Rect] = [
            .brightness: Rect(x: 0.83...0.905, y: 0.04...0.96),
            .volume: Rect(x: 0.915...0.99, y: 0.04...0.96),
        ]
        let cellW = (grid.width - 3 * gap) / 4
        let cellH = (grid.height - Double(rows.count - 1) * gap) / Double(rows.count)

        // A key listed in several cells (the 4x5 Enter) spans their union.
        var rects: [NumKey: Rect] = [:], order: [NumKey] = []
        for (r, row) in rows.enumerated() {
            for (c, key) in row.enumerated() {
                guard let key else { continue }
                let minX = grid.minX + Double(c) * (cellW + gap)
                let maxY = grid.maxY - Double(r) * (cellH + gap)
                let cell = Rect(x: minX...(minX + cellW), y: (maxY - cellH)...maxY)
                if let existing = rects[key] { rects[key] = existing.union(cell) } else { rects[key] = cell; order.append(key) }
            }
        }
        var keys = order.map { KeyCell(key: $0, rect: rects[$0]!) }

        if sliderSide == .left {
            // Strips mirror to the left edge; the grid slides right but keeps its column order.
            let dx = 1 - grid.maxX - grid.minX
            grid = grid.offsetBy(dx: dx)
            keys = keys.map { KeyCell(key: $0.key, rect: $0.rect.offsetBy(dx: dx)) }
            strips = strips.mapValues { $0.mirrored() }
        }
        self.grid = grid
        self.keys = keys
        self.strips = strips
    }

    public var stripHeight: Double { strips[.volume]!.height }

    public func zone(x: Double, y: Double) -> Zone {
        for kind in SliderKind.allCases where strips[kind]!.contains(x: x, y: y) { return .slider(kind) }
        if let cell = keys.first(where: { $0.rect.contains(x: x, y: y) }) {
            return cell.rect.insetBy(keyInset).contains(x: x, y: y) ? .key(cell.key) : .dead
        }
        return grid.contains(x: x, y: y) ? .dead : .outside
    }

    public func key(at contact: Contact?) -> NumKey? {
        guard let contact, case .key(let k) = zone(x: contact.x, y: contact.y) else { return nil }
        return k
    }
}

/// The most recent finger that is down and not palm-sized.
public func primaryContact(in contacts: [Contact], palmFactor: Double) -> Contact? {
    let live = contacts.filter(\.isDown)
    guard !live.isEmpty else { return nil }
    // ponytail: median of the current frame's sizes; a resting palm plus one finger can fool it, track a running median if that bites.
    let median = live.map(\.size).sorted()[live.count / 2]
    return live.filter { $0.size <= palmFactor * median }.max { $0.id < $1.id }
}
