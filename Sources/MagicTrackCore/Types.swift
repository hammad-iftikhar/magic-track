import Foundation

public enum ContactPhase: String, Codable { case began, moved, stationary, ended }

public struct Contact: Equatable, Codable, Identifiable {
    public let id: Int              // stable per finger until lift, increases with each new touch
    public let x: Double, y: Double // normalized 0...1, y up
    public let size: Double         // contact area, for palm rejection
    public let phase: ContactPhase

    public init(id: Int, x: Double, y: Double, size: Double, phase: ContactPhase) {
        self.id = id; self.x = x; self.y = y; self.size = size; self.phase = phase
    }

    public var isDown: Bool { phase != .ended }
}

public struct TouchFrame: Codable {
    public let contacts: [Contact]
    public let timestamp: TimeInterval
    public let deviceID: Int

    public init(contacts: [Contact], timestamp: TimeInterval, deviceID: Int) {
        self.contacts = contacts; self.timestamp = timestamp; self.deviceID = deviceID
    }
}

public enum NumKey: String, CaseIterable, Codable {
    case k0, k1, k2, k3, k4, k5, k6, k7, k8, k9,
         decimal, enter, plus, minus, multiply, divide, clear, equals

    public var label: String {
        switch self {
        case .decimal: "."
        case .enter: "Enter"
        case .plus: "+"
        case .minus: "−"
        case .multiply: "×"
        case .divide: "÷"
        case .clear: "Clear"
        case .equals: "="
        default: String(rawValue.dropFirst())
        }
    }
}

public enum SliderKind: String, CaseIterable { case brightness, volume }

public enum Zone: Equatable { case key(NumKey), slider(SliderKind), dead, outside }

public enum Action: Equatable { case keyDown(NumKey), keyUp(NumKey), adjust(SliderKind, delta: Double) }

public protocol TouchSource: AnyObject { var onFrame: ((TouchFrame) -> Void)? { get set } }

public protocol ActionSink { func perform(_ action: Action) }
