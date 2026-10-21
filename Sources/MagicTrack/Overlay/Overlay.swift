import AppKit
import SwiftUI
import MagicTrackCore

struct OverlayState: Equatable {
    var layout = Layout()
    var contacts: [Contact] = []
    var primaryID: Int?
    var highlightedKey: NumKey?
    var pressedKey: NumKey?
    var brightness: Double?   // nil = unavailable, strip greyed
    var volume: Double?
    var banner: String?
}

final class OverlayModel: ObservableObject {
    @Published var state = OverlayState()
    @Published var visible = false
}

/// Borderless, non-activating, click-through panel that never takes focus.
final class OverlayPanel: NSPanel {
    private let model: OverlayModel

    init(model: OverlayModel) {
        self.model = model
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar   // raise to .screenSaver if it hides behind full-screen apps
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        contentView = fx
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(aspect: Double) {
        let width = 520 * Settings.overlayScale
        let height = width / aspect
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            setFrame(NSRect(x: vis.midX - width / 2, y: vis.minY + vis.height * 0.15, width: width, height: height), display: true)
        }
        alphaValue = 0
        orderFrontRegardless()
        model.visible = true
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    func hide() {
        guard model.visible else { return }
        model.visible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; animator().alphaValue = 0 }) { [self] in
            if !model.visible { orderOut(nil) }
        }
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let s = model.state
        GeometryReader { geo in
            // Normalized trackpad space (y up) → view space (y down).
            let frame = { (r: Rect) in
                CGRect(x: r.minX * geo.size.width, y: (1 - r.maxY) * geo.size.height,
                       width: r.width * geo.size.width, height: r.height * geo.size.height)
            }
            ZStack(alignment: .topLeading) {
                ForEach(s.layout.keys, id: \.key) { cell in
                    key(cell.key, s).frame(width: frame(cell.rect).width, height: frame(cell.rect).height)
                        .position(x: frame(cell.rect).midX, y: frame(cell.rect).midY)
                }
                ForEach(SliderKind.allCases, id: \.self) { kind in
                    let r = frame(s.layout.strips[kind]!)
                    strip(kind, value: kind == .volume ? s.volume : s.brightness)
                        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
                ForEach(s.contacts) { c in
                    Circle().fill(Color.white.opacity(c.id == s.primaryID ? 0.7 : 0.4))
                        .frame(width: 18, height: 18)
                        .position(x: c.x * geo.size.width, y: (1 - c.y) * geo.size.height)
                }
                if let banner = s.banner {
                    Text(banner).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.85)))
                        .position(x: geo.size.width / 2, y: 10)
                }
            }
        }
        .scaleEffect(model.visible || reduceMotion ? 1 : 0.96)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.visible)
    }

    private func key(_ k: NumKey, _ s: OverlayState) -> some View {
        let pressed = s.pressedKey == k
        let hovered = s.highlightedKey == k
        let border = contrast == .increased ? Color.primary : Color.primary.opacity(0.25)
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(pressed ? 0.3 : hovered ? 0.12 : 0))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered || pressed ? Color.accentColor : border,
                                                                  lineWidth: hovered || pressed ? 2 : 0.5))
            .overlay(Text(k.label).font(.system(size: k.label.count > 1 ? 14 : 22, weight: .medium, design: .rounded)))
            .scaleEffect(pressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
    }

    private func strip(_ kind: SliderKind, value: Double?) -> some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.25), lineWidth: 0.5)
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.5))
                    .frame(height: g.size.height * (value ?? 0))
                VStack(spacing: 2) {
                    Image(systemName: kind == .volume ? "speaker.wave.2.fill" : "sun.max.fill")
                    Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–").font(.system(size: 9).monospacedDigit())
                }
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 6)
            }
        }
        .opacity(value == nil ? 0.35 : 1)
    }
}
