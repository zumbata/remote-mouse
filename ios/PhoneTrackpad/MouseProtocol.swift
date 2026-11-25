import CoreBluetooth
import Foundation

/// Wire format shared by the iOS app, the Windows agent and the ESP32 firmware.
///
/// One mouse packet is 8 bytes, little-endian:
///   [0]    packet type, 0x01 = mouse
///   [1]    button bitmask (bit0 left, bit1 right, bit2 middle), absolute state
///   [2..3] dx, Int16, pixels, positive = right
///   [4..5] dy, Int16, pixels, positive = down
///   [6]    wheel, Int8, in 1/8 notch units, positive = scroll up (wheel away from user)
///   [7]    hwheel, Int8, in 1/8 notch units, positive = scroll right
///
/// Buttons are sent as absolute state, so the receiver diffs against the previous
/// packet to produce down/up events. Movement in a packet happened while its
/// button state was already in effect, so receivers apply buttons first, then motion.
enum MouseProtocol {
    static let packetTypeMouse: UInt8 = 0x01
    static let wheelUnitsPerNotch = 8

    /// iPhone as peripheral, Windows agent as central.
    enum Agent {
        static let service = CBUUID(string: "7A1C0001-5B2E-4E8F-9C3D-2F6A8B1E4D70")
        static let input = CBUUID(string: "7A1C0002-5B2E-4E8F-9C3D-2F6A8B1E4D70")
        static let info = CBUUID(string: "7A1C0003-5B2E-4E8F-9C3D-2F6A8B1E4D70")
        /// The agent writes here every second; the phone treats silence as a dead link.
        static let ping = CBUUID(string: "7A1C0004-5B2E-4E8F-9C3D-2F6A8B1E4D70")
    }

    /// iPhone as central, ESP32 dongle as peripheral.
    enum Dongle {
        static let service = CBUUID(string: "7A1C0101-5B2E-4E8F-9C3D-2F6A8B1E4D70")
        static let input = CBUUID(string: "7A1C0102-5B2E-4E8F-9C3D-2F6A8B1E4D70")
        static let info = CBUUID(string: "7A1C0103-5B2E-4E8F-9C3D-2F6A8B1E4D70")
    }
}

struct MouseButtons: OptionSet, Equatable {
    let rawValue: UInt8
    static let left = MouseButtons(rawValue: 1 << 0)
    static let right = MouseButtons(rawValue: 1 << 1)
    static let middle = MouseButtons(rawValue: 1 << 2)
}

struct MousePacket: Equatable {
    var buttons: MouseButtons
    var dx: Int16 = 0
    var dy: Int16 = 0
    var wheel: Int8 = 0
    var hwheel: Int8 = 0

    var data: Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = MouseProtocol.packetTypeMouse
        bytes[1] = buttons.rawValue
        let ux = UInt16(bitPattern: dx), uy = UInt16(bitPattern: dy)
        bytes[2] = UInt8(ux & 0xFF); bytes[3] = UInt8(ux >> 8)
        bytes[4] = UInt8(uy & 0xFF); bytes[5] = UInt8(uy >> 8)
        bytes[6] = UInt8(bitPattern: wheel)
        bytes[7] = UInt8(bitPattern: hwheel)
        return Data(bytes)
    }

    /// Adds motion to this packet if it fits without overflow; returns false otherwise.
    mutating func merge(dx: Int, dy: Int, wheel: Int, hwheel: Int) -> Bool {
        let nx = Int(self.dx) + dx, ny = Int(self.dy) + dy
        let nw = Int(self.wheel) + wheel, nh = Int(self.hwheel) + hwheel
        let i16 = Int(Int16.min)...Int(Int16.max), i8 = Int(Int8.min)...Int(Int8.max)
        guard i16 ~= nx, i16 ~= ny, i8 ~= nw, i8 ~= nh else { return false }
        self.dx = Int16(nx); self.dy = Int16(ny); self.wheel = Int8(nw); self.hwheel = Int8(nh)
        return true
    }
}

/// A link that can carry mouse packets to the host.
protocol MouseTransport: AnyObject {
    /// Called when a previously refused send can be retried.
    var onReadyToSend: (() -> Void)? { get set }
    /// Called when the link to the host drops, so queued packets and held buttons are discarded.
    var onLinkReset: (() -> Void)? { get set }
    var isLinkUp: Bool { get }
    /// Returns false when the link is busy; the caller keeps the packet and retries on `onReadyToSend`.
    func send(_ data: Data) -> Bool
}
