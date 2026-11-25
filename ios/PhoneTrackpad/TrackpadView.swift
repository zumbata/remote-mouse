import SwiftUI
import UIKit

/// SwiftUI wrapper around the raw-touch trackpad surface.
struct TrackpadView: UIViewRepresentable {
    let mouse: MouseController

    func makeUIView(context: Context) -> TrackpadSurface {
        let view = TrackpadSurface()
        view.mouse = mouse
        return view
    }

    func updateUIView(_ view: TrackpadSurface, context: Context) {
        view.mouse = mouse
    }
}

/// Reads touches directly (no gesture recognizers) so pointer motion is not delayed.
///
/// Gestures:
///   one finger drag        move pointer
///   one finger tap         left click
///   two finger tap         right click
///   three finger tap       middle click
///   two finger drag        scroll, with momentum after lift
///   double tap, hold, drag left-button drag (select text, move windows)
final class TrackpadSurface: UIView {
    weak var mouse: MouseController?

    private static let tapMaxDuration: TimeInterval = 0.22
    private static let tapMaxTravel: CGFloat = 10
    private static let dragTapWindow: TimeInterval = 0.28

    private var active: Set<UITouch> = []
    private var gestureStart: TimeInterval = 0
    private var maxFingers = 0
    private var travel: CGFloat = 0
    private var lastOneFingerTap: TimeInterval = -1
    private var dragLocked = false
    private var lastMoveTime: TimeInterval = 0

    // Scroll momentum.
    private var scrollVelocity = CGVector.zero // points per second
    private var momentumLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        let now = touches.first?.timestamp ?? CACurrentMediaTime()
        if active.isEmpty {
            gestureStart = now
            lastMoveTime = now
            maxFingers = 0
            travel = 0
            scrollVelocity = .zero
            // A finger landing right after a one-finger tap starts a drag with the left button held.
            if touches.count == 1, mouse?.tapToClick == true,
               lastOneFingerTap > 0, now - lastOneFingerTap < Self.dragTapWindow {
                dragLocked = true
                mouse?.press(.left)
            }
            lastOneFingerTap = -1
        }
        active.formUnion(touches)
        maxFingers = max(maxFingers, active.count)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let mouse else { return }
        var sum = CGVector.zero
        var moved = 0
        var timestamp = lastMoveTime
        for touch in touches where active.contains(touch) {
            let now = touch.preciseLocation(in: self)
            let before = touch.precisePreviousLocation(in: self)
            sum.dx += now.x - before.x
            sum.dy += now.y - before.y
            moved += 1
            timestamp = max(timestamp, touch.timestamp)
        }
        guard moved > 0 else { return }
        let delta = CGVector(dx: sum.dx / CGFloat(moved), dy: sum.dy / CGFloat(moved))
        travel += hypot(delta.dx, delta.dy)
        let interval = min(max(timestamp - lastMoveTime, 1.0 / 240), 0.1)
        lastMoveTime = timestamp

        switch active.count {
        case 1 where maxFingers == 1:
            let speed = Double(hypot(delta.dx, delta.dy)) / interval
            mouse.move(dx: delta.dx, dy: delta.dy, speed: speed)
        case 2:
            mouse.scroll(dx: delta.dx, dy: delta.dy)
            let instant = CGVector(dx: delta.dx / interval, dy: delta.dy / interval)
            // Smooth the velocity so the momentum matches the flick, not the last noisy frame.
            scrollVelocity = CGVector(dx: scrollVelocity.dx * 0.6 + instant.dx * 0.4,
                                      dy: scrollVelocity.dy * 0.6 + instant.dy * 0.4)
        default:
            break // A finger left over from a two-finger gesture should not jerk the pointer.
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        let fingersBefore = active.count
        active.subtract(touches)
        guard active.isEmpty, let mouse else { return }

        let now = touches.first?.timestamp ?? CACurrentMediaTime()
        let isTap = !cancelled
            && now - gestureStart < Self.tapMaxDuration
            && travel < Self.tapMaxTravel

        if dragLocked {
            dragLocked = false
            mouse.release(.left) // A quick second tap here completes a double-click.
            return
        }

        if isTap && mouse.tapToClick {
            switch maxFingers {
            case 1:
                mouse.click(.left)
                lastOneFingerTap = now
            case 2: mouse.click(.right)
            case 3: mouse.click(.middle)
            default: break
            }
            return
        }

        if maxFingers == 2, fingersBefore >= 1, !cancelled,
           hypot(scrollVelocity.dx, scrollVelocity.dy) > 250 {
            startMomentum()
        }
    }

    // MARK: - Momentum

    private func startMomentum() {
        let link = CADisplayLink(target: self, selector: #selector(momentumTick(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        // Exponential decay with a ~0.33 s time constant.
        let decay = exp(-dt / 0.33)
        scrollVelocity = CGVector(dx: scrollVelocity.dx * decay, dy: scrollVelocity.dy * decay)
        if hypot(scrollVelocity.dx, scrollVelocity.dy) < 30 {
            stopMomentum()
            return
        }
        mouse?.scroll(dx: scrollVelocity.dx * dt, dy: scrollVelocity.dy * dt)
    }
}
