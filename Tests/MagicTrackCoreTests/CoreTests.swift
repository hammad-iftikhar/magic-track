import XCTest
@testable import MagicTrackCore

final class ZoneMapperTests: XCTestCase {
    func testKeyCentresAndDeadBorders() {
        for grid in GridLayout.allCases {
            for side in SliderSide.allCases {
                let layout = Layout(grid: grid, sliderSide: side)
                for cell in layout.keys {
                    let r = cell.rect
                    XCTAssertEqual(layout.zone(x: r.midX, y: r.midY), .key(cell.key), "\(grid) \(side) \(cell.key)")
                    XCTAssertEqual(layout.zone(x: r.minX + 0.005, y: r.midY), .dead)
                    XCTAssertEqual(layout.zone(x: r.midX, y: r.maxY - 0.005), .dead)
                }
            }
        }
    }

    func testStripsBothSides() {
        let right = Layout(sliderSide: .right)
        XCTAssertEqual(right.zone(x: 0.86, y: 0.5), .slider(.brightness))
        XCTAssertEqual(right.zone(x: 0.95, y: 0.5), .slider(.volume))
        XCTAssertEqual(right.zone(x: 0.5, y: 0.01), .outside)

        let left = Layout(sliderSide: .left)
        XCTAssertEqual(left.zone(x: 0.14, y: 0.5), .slider(.brightness))
        XCTAssertEqual(left.zone(x: 0.05, y: 0.5), .slider(.volume))
        // Column order is kept: 7 is still left of 8.
        let x7 = left.keys.first { $0.key == .k7 }!.rect.midX
        let x8 = left.keys.first { $0.key == .k8 }!.rect.midX
        XCTAssertLessThan(x7, x8)
        XCTAssertGreaterThan(x7, 0.17)
    }

    func testGridOrderAndTallEnter() {
        let l4 = Layout(grid: .fourByFour)
        let top = l4.keys.max { $0.rect.midY < $1.rect.midY }!
        XCTAssertTrue([.k7, .k8, .k9, .divide].contains(top.key))

        let l5 = Layout(grid: .fourByFive)
        let enter = l5.keys.first { $0.key == .enter }!.rect
        let plus = l5.keys.first { $0.key == .k3 }!.rect
        XCTAssertGreaterThan(enter.height, plus.height * 2)
        XCTAssertEqual(l5.zone(x: enter.midX, y: enter.midY), .key(.enter))
    }

    func testPrimaryContactSkipsPalm() {
        let finger = Contact(id: 1, x: 0.5, y: 0.5, size: 1, phase: .stationary)
        let palm = Contact(id: 3, x: 0.2, y: 0.2, size: 5, phase: .began)
        let newer = Contact(id: 2, x: 0.6, y: 0.6, size: 1.1, phase: .began)
        XCTAssertEqual(primaryContact(in: [finger, palm, newer], palmFactor: 1.5)?.id, 2)
        XCTAssertNil(primaryContact(in: [], palmFactor: 1.5))
    }
}

final class SliderTrackerTests: XCTestCase {
    let layout = Layout()
    func c(_ y: Double, x: Double = 0.95, _ phase: ContactPhase = .moved) -> [Contact] {
        [Contact(id: 1, x: x, y: y, size: 1, phase: phase)]
    }

    func testCaptureThresholdTicksAndClamp() {
        var t = SliderTracker()
        t.values = [.volume: 0.5]
        XCTAssertEqual(t.update(contacts: c(0.5, .began), layout: layout), [])
        // Below 1/64 of the strip: nothing yet.
        XCTAssertEqual(t.update(contacts: c(0.5 + layout.stripHeight / 128), layout: layout), [])
        // Crossing the threshold emits the accumulated change.
        let out = t.update(contacts: c(0.5 + layout.stripHeight / 64), layout: layout)
        guard case .adjust(.volume, let d)? = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(d, 1.0 / 64, accuracy: 1e-9)

        // Drift sideways into the grid: still captured; +10% crosses the 0.6 boundary.
        let out2 = t.update(contacts: c(0.5 + layout.stripHeight * (1.0 / 64 + 0.1), x: 0.3), layout: layout)
        XCTAssertTrue(out2.contains(.tick(strong: false)))

        // Big swipe clamps at 1 with a strong tick, then further movement does nothing.
        let out3 = t.update(contacts: c(5), layout: layout)
        XCTAssertTrue(out3.contains(.tick(strong: true)))
        XCTAssertEqual(t.values[.volume], 1)
        XCTAssertEqual(t.update(contacts: c(6), layout: layout), [])

        // Lift releases capture.
        _ = t.update(contacts: c(6, .ended), layout: layout)
        XCTAssertEqual(t.update(contacts: c(0), layout: layout), [])
    }

    func testFingerDownDecreasesAndGridContactIgnored() {
        var t = SliderTracker()
        t.values = [.brightness: 0.5]
        _ = t.update(contacts: c(0.5, x: 0.86, .began), layout: layout)
        XCTAssertEqual(t.update(contacts: c(0.3, x: 0.86), layout: layout).first.flatMap {
            if case .adjust(.brightness, let d) = $0 { return d < 0 } else { return nil }
        }, true)

        var g = SliderTracker()
        _ = g.update(contacts: c(0.5, x: 0.3, .began), layout: layout)
        XCTAssertEqual(g.update(contacts: c(0.9, x: 0.86), layout: layout), [])
    }
}

final class GestureTests: XCTestCase {
    /// Five fingers, each placed at `t0 + i*stagger`, moved by `move`, all lifted at `lift`.
    func tap(t0: Double = 0, stagger: Double = 0.01, lift: Double = 0.15, move: Double = 0,
             sizes: [Double] = [1, 1, 1, 1, 1], device: Int = 1, idBase: Int = 0) -> [TouchFrame] {
        let n = sizes.count
        var frames: [TouchFrame] = []
        for i in 0..<n {
            let cs = (0...i).map { j in
                Contact(id: idBase + j, x: 0.1 + 0.15 * Double(j), y: 0.5, size: sizes[j], phase: j == i ? .began : .stationary)
            }
            frames.append(TouchFrame(contacts: cs, timestamp: t0 + Double(i) * stagger, deviceID: device))
        }
        let moved = (0..<n).map { j in Contact(id: idBase + j, x: 0.1 + 0.15 * Double(j) + move, y: 0.5, size: sizes[j], phase: .moved) }
        frames.append(TouchFrame(contacts: moved, timestamp: t0 + lift - 0.01, deviceID: device))
        let ended = moved.map { Contact(id: $0.id, x: $0.x, y: $0.y, size: $0.size, phase: .ended) }
        frames.append(TouchFrame(contacts: ended, timestamp: t0 + lift, deviceID: device))
        return frames
    }

    func run(_ frames: [TouchFrame], _ sm: inout GestureStateMachine) -> [GestureEvent] {
        frames.compactMap { sm.feed($0) }
    }

    func testFiveFingerTapOpensAndCloses() {
        var sm = GestureStateMachine()
        XCTAssertEqual(run(tap(), &sm), [.activate(deviceID: 1)])
        XCTAssertEqual(sm.state, .active)
        // Closing tap inside the cooldown is ignored; after it, closes.
        XCTAssertEqual(run(tap(t0: 0.2, idBase: 10), &sm), [])
        XCTAssertEqual(run(tap(t0: 1, idBase: 20), &sm), [.deactivate])
        XCTAssertEqual(sm.state, .cooldown)
        // The closing tap cannot immediately reopen.
        XCTAssertEqual(run(tap(t0: 1.2, idBase: 30), &sm), [])
        XCTAssertEqual(run(tap(t0: 2, idBase: 40), &sm), [.activate(deviceID: 1)])
    }

    func testRejections() {
        var sm = GestureStateMachine()
        XCTAssertEqual(run(tap(move: 0.05), &sm), [], "pinch / swipe")
        XCTAssertEqual(run(tap(t0: 1, stagger: 0.04, idBase: 10), &sm), [], "slow placement")
        XCTAssertEqual(run(tap(t0: 2, lift: 0.5, idBase: 20), &sm), [], "hold, not a tap")
        XCTAssertEqual(run(tap(t0: 3, sizes: [1, 1, 1, 1], idBase: 30), &sm), [], "four fingers")
        XCTAssertEqual(run(tap(t0: 4, sizes: [1, 1, 1, 1, 1, 1], idBase: 40), &sm), [], "six fingers")
        XCTAssertEqual(run(tap(t0: 5, sizes: [1, 1, 4, 1, 1], idBase: 50), &sm), [], "palm")
        XCTAssertEqual(run(tap(t0: 6, idBase: 60), &sm), [.activate(deviceID: 1)])
    }

    func testIdleTimeoutAndOtherDeviceIgnored() {
        var sm = GestureStateMachine()
        _ = run(tap(), &sm)
        XCTAssertEqual(run(tap(t0: 1, device: 2, idBase: 10), &sm), [], "second trackpad ignored")
        XCTAssertNil(sm.tick(now: 3))
        XCTAssertEqual(sm.tick(now: 4.2), .deactivate)
        XCTAssertNil(sm.tick(now: 5))
        sm.deactivate(now: 5)   // safe twice
        XCTAssertFalse(sm.isActive)
    }
}

final class ActionDispatcherTests: XCTestCase {
    final class Sink: ActionSink { var log: [Action] = []; func perform(_ a: Action) { log.append(a) } }

    func testKeyUpMatchesKeyDownAfterDrift() {
        let sink = Sink()
        let d = ActionDispatcher(sink: sink)
        d.clickDown(.key(.k5))
        d.clickDown(.key(.k6))   // second down while pressed is ignored
        d.clickUp()              // finger is over 6 now, but 5 went down
        d.clickDown(.dead)
        d.clickDown(nil)
        d.clickUp()
        XCTAssertEqual(sink.log, [.keyDown(.k5), .keyUp(.k5)])
    }
}
