import CoreBluetooth
import Foundation
import Observation

/// ESP32-dongle mode: the iPhone connects to the dongle and writes mouse packets;
/// the dongle replays them to the PC as a real Bluetooth (or USB) HID mouse.
@Observable
final class DongleCentral: NSObject, MouseTransport {
    enum State: Equatable {
        case off
        case unavailable(String)
        case scanning
        case connecting(String)
        case pairing(String)
        case connected(String)
        case failed(String)
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    private(set) var state: State = .off
    private(set) var found: [Found] = []

    @ObservationIgnored var onReadyToSend: (() -> Void)?
    @ObservationIgnored var onLinkReset: (() -> Void)?
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var active: CBPeripheral?
    @ObservationIgnored private var input: CBCharacteristic?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var userDisconnected = false

    private static let rememberedKey = "rememberedDongle"
    var remembered: UUID? {
        get { UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.rememberedKey) }
    }

    var isLinkUp: Bool {
        if case .connected = state { return input != nil }
        return false
    }

    func start() {
        wantsRunning = true
        userDisconnected = false
        if let central {
            if central.state == .poweredOn { resume() }
        } else {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func stop() {
        wantsRunning = false
        central?.stopScan()
        if let active { central?.cancelPeripheralConnection(active) }
        active = nil
        input = nil
        found = []
        state = .off
    }

    func connect(_ id: UUID) {
        guard let central, let peripheral = peripherals[id]
                ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        active = peripheral
        peripherals[id] = peripheral
        peripheral.delegate = self
        state = .connecting(peripheral.name ?? "Dongle")
        central.connect(peripheral)
    }

    func forget() {
        remembered = nil
        userDisconnected = true
        if let active { central?.cancelPeripheralConnection(active) }
        active = nil
        input = nil
        resume()
    }

    func send(_ data: Data) -> Bool {
        guard let active, let input, active.canSendWriteWithoutResponse else { return false }
        active.writeValue(data, for: input, type: .withoutResponse)
        return true
    }

    /// Reconnects to the remembered dongle, or scans so the user can pick one.
    private func resume() {
        guard wantsRunning, let central, central.state == .poweredOn, active == nil else { return }
        if let id = remembered, !userDisconnected {
            connect(id)
            if active != nil { return }
        }
        found = []
        state = .scanning
        central.scanForPeripherals(withServices: [MouseProtocol.Dongle.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func fail(_ message: String) {
        state = .failed(message)
        userDisconnected = true // scan instead of auto-retrying into the same failure
        if let active { central?.cancelPeripheralConnection(active) }
    }
}

extension DongleCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            resume()
        case .poweredOff:
            active = nil; input = nil
            state = .unavailable("Bluetooth is off")
        case .unauthorized:
            state = .unavailable("Bluetooth permission denied — enable it in Settings")
        case .unsupported:
            state = .unavailable("Bluetooth LE not supported")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "PhoneTrackpad Dongle"
        if let i = found.firstIndex(where: { $0.id == peripheral.identifier }) {
            found[i].rssi = RSSI.intValue
        } else {
            found.append(Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .pairing(peripheral.name ?? "Dongle")
        peripheral.discoverServices([MouseProtocol.Dongle.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        active = nil
        state = .failed(error?.localizedDescription ?? "Connection failed")
        resume()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral == active else { return }
        active = nil
        input = nil
        onLinkReset?()
        if case .failed = state {} else { state = .scanning }
        // A pending connect never times out on iOS, so the dongle reconnects as soon as it is back in range.
        resume()
    }
}

extension DongleCentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == MouseProtocol.Dongle.service }) else {
            return fail("Not a PhoneTrackpad dongle")
        }
        peripheral.discoverCharacteristics([MouseProtocol.Dongle.input, MouseProtocol.Dongle.info], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        guard let input = chars.first(where: { $0.uuid == MouseProtocol.Dongle.input }),
              let info = chars.first(where: { $0.uuid == MouseProtocol.Dongle.info }) else {
            return fail("Dongle firmware is missing characteristics")
        }
        self.input = input
        // The info characteristic needs an authenticated link, so this read makes
        // iOS show the PIN prompt the first time. Writes without response never would.
        peripheral.readValue(for: info)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == MouseProtocol.Dongle.info else { return }
        if let error {
            input = nil
            return fail("Pairing failed: \(error.localizedDescription)")
        }
        remembered = peripheral.identifier
        userDisconnected = false
        state = .connected(peripheral.name ?? "Dongle")
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        onReadyToSend?()
    }
}
