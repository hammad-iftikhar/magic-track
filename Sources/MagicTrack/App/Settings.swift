import Foundation
import MagicTrackCore

/// UserDefaults-backed settings. The SwiftUI settings window binds the same keys with @AppStorage.
enum Settings {
    static let defaults: [String: Any] = [
        "enabled": true,
        "idleTimeout": 4.0,
        "sliderSide": SliderSide.right.rawValue,
        "gridLayout": GridLayout.fourByFour.rawValue,
        "sliderSensitivity": 1.0,
        "hapticsEnabled": true,
        "overlayScale": 1.0,
        "palmSizeFactor": 1.5,
    ]

    private static var d: UserDefaults { .standard }

    static func register() { d.register(defaults: defaults) }

    static var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var idleTimeout: Double { d.double(forKey: "idleTimeout") }
    static var sliderSide: SliderSide { SliderSide(rawValue: d.string(forKey: "sliderSide") ?? "") ?? .right }
    static var gridLayout: GridLayout { GridLayout(rawValue: d.string(forKey: "gridLayout") ?? "") ?? .fourByFour }
    static var sliderSensitivity: Double { d.double(forKey: "sliderSensitivity") }
    static var hapticsEnabled: Bool { d.bool(forKey: "hapticsEnabled") }
    static var overlayScale: Double { d.double(forKey: "overlayScale") }
    static var palmSizeFactor: Double { d.double(forKey: "palmSizeFactor") }

    static var tipShown: Bool {
        get { d.bool(forKey: "tipShown") }
        set { d.set(newValue, forKey: "tipShown") }
    }
}
