import Foundation
import Observation
import UIKit

/// Turns trackpad gestures into mouse packets, coalesces them while the radio is busy,
/// and pushes them through whichever transport is active.
@Observable
final class MouseController {
    // Settings, persisted in UserDefaults.
    var sensitivity: Double = UserDefaults.standard.object(forKey: "sensitivity") as? Double ?? 1.6 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity") }
    }
    var acceleration: Double = UserDefaults.standard.object(forKey: "acceleration") as? Double ?? 0.6 {
        didSet { UserDefaults.standard.set(acceleration, forKey: "acceleration") }
    }
    var scrollSpeed: Double = UserDefaults.standard.object(forKey: "scrollSpeed") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(scrollSpeed, forKey: "scrollSpeed") }
    }
    var naturalScroll: Bool = UserDefaults.standard.object(forKey: "naturalScroll") as? Bool ?? true {
        didSet { UserDefaults.standard.set(naturalScroll, forKey: "naturalScroll") }
    }
    var tapToClick: Bool = UserDefaults.standard.object(forKey: "tapToClick") as? Bool ?? true {
        didSet { UserDefaults.standard.set(tapToClick, forKey: "tapToClick") }
    }
    var haptics: Bool = UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(haptics, forKey: "haptics") }
    }

    private(set) var buttons: MouseButtons = []

    @ObservationIgnored weak var transport: MouseTransport? {
        didSet {
            pending.removeAll()
            transport?.onReadyToSend = { [weak self] in self?.flush() }
            transport?.onLinkReset = { [weak self] in
                self?.pending.removeAll()
                self?.buttons = []
            }
        }
    }

    @ObservationIgnored private var pending: [MousePacket] = []
    // Sub-pixel and sub-notch remainders carried between events.
    @ObservationIgnored private var remX = 0.0
    @ObservationIgnored private var remY = 0.0
    @ObservationIgnored private var remWheel = 0.0
    @ObservationIgnored private var remHWheel = 0.0
    @ObservationIgnored private let clickFeedback = UIImpactFeedbackGenerator(style: .light)

    // MARK: - Gesture input

    /// Pointer motion in screen points, with the finger speed in points per second.
    func move(dx: Double, dy: Double, speed: Double) {
        // Gain grows with speed: slow moves stay precise, fast flicks cross the screen.
        let boost = 1 + acceleration * min(speed / 600, 3)
        remX += dx * sensitivity * boost
        remY += dy * sensitivity * boost
        let ix = remX.rounded(.towardZero), iy = remY.rounded(.towardZero)
        remX -= ix; remY -= iy
        guard ix != 0 || iy != 0 else { return }
        enqueueMotion(dx: Int(ix), dy: Int(iy), wheel: 0, hwheel: 0)
    }

    /// Two-finger scroll, finger travel in points.
    func scroll(dx: Double, dy: Double) {
        // ~24 pt of finger travel per wheel notch at speed 1.0.
        let unitsPerPoint = Double(MouseProtocol.wheelUnitsPerNotch) / 24 * scrollSpeed
        let sign = naturalScroll ? 1.0 : -1.0
        // Natural: finger up (dy < 0) reveals content below, which is wheel down (negative).
        remWheel += dy * unitsPerPoint * sign
        remHWheel += -dx * unitsPerPoint * sign
        let w = remWheel.rounded(.towardZero), h = remHWheel.rounded(.towardZero)
        remWheel -= w; remHWheel -= h
        guard w != 0 || h != 0 else { return }
        enqueueMotion(dx: 0, dy: 0, wheel: Int(w), hwheel: Int(h))
    }

    func press(_ button: MouseButtons) {
        guard !buttons.contains(button) else { return }
        buttons.insert(button)
        enqueueButtonState()
        if haptics { clickFeedback.impactOccurred() }
    }

    func release(_ button: MouseButtons) {
        guard buttons.contains(button) else { return }
        buttons.remove(button)
        enqueueButtonState()
    }

    func click(_ button: MouseButtons) {
        press(button)
        release(button)
    }

    func releaseAll() {
        guard !buttons.isEmpty else { return }
        buttons = []
        enqueueButtonState()
    }

    // MARK: - Queue

    private func enqueueMotion(dx: Int, dy: Int, wheel: Int, hwheel: Int) {
        guard transport?.isLinkUp == true else { return }
        var dx = dx, dy = dy, wheel = wheel, hwheel = hwheel
        // Merge into the newest unsent packet when it has the same buttons.
        if var last = pending.last, last.buttons == buttons,
           last.merge(dx: dx, dy: dy, wheel: wheel, hwheel: hwheel) {
            pending[pending.count - 1] = last
        } else {
            while dx != 0 || dy != 0 || wheel != 0 || hwheel != 0 {
                let p = MousePacket(buttons: buttons,
                                    dx: Int16(clamping: dx), dy: Int16(clamping: dy),
                                    wheel: Int8(clamping: wheel), hwheel: Int8(clamping: hwheel))
                dx -= Int(p.dx); dy -= Int(p.dy); wheel -= Int(p.wheel); hwheel -= Int(p.hwheel)
                pending.append(p)
            }
        }
        flush()
    }

    private func enqueueButtonState() {
        guard transport?.isLinkUp == true else { return }
        // Button edges are never merged away, so a fast tap still yields down + up.
        pending.append(MousePacket(buttons: buttons))
        flush()
    }

    private func flush() {
        guard let transport else { pending.removeAll(); return }
        while let next = pending.first {
            guard transport.send(next.data) else { return }
            pending.removeFirst()
        }
    }
}
