import CoreBluetooth
import Foundation
import Observation
import UIKit

/// Windows-agent mode: the iPhone advertises a custom GATT service and the
/// PhoneTrackpad agent on the PC connects to it and subscribes to mouse packets.
@Observable
final class AgentPeripheral: NSObject, MouseTransport {
    enum State: Equatable {
        case off
        case unavailable(String)
        case advertising
        case connected
    }

    private(set) var state: State = .off

    @ObservationIgnored var onReadyToSend: (() -> Void)?
    @ObservationIgnored private var manager: CBPeripheralManager?
    @ObservationIgnored private var inputCharacteristic: CBMutableCharacteristic?
    @ObservationIgnored private var subscriber: CBCentral?
    @ObservationIgnored private var wantsRunning = false

    var isLinkUp: Bool { state == .connected }

    /// Stable per-install id the agent uses to remember which phones it approved.
    static let installID: String = {
        let key = "installID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    func start() {
        wantsRunning = true
        if let manager {
            if manager.state == .poweredOn { publish() }
        } else {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        }
    }

    func stop() {
        wantsRunning = false
        manager?.stopAdvertising()
        manager?.removeAllServices()
        inputCharacteristic = nil
        subscriber = nil
        state = .off
    }

    func send(_ data: Data) -> Bool {
        guard let manager, let inputCharacteristic, let subscriber else { return false }
        return manager.updateValue(data, for: inputCharacteristic, onSubscribedCentrals: [subscriber])
    }

    private func publish() {
        guard wantsRunning, let manager, inputCharacteristic == nil else { return }
        let input = CBMutableCharacteristic(type: MouseProtocol.Agent.input,
                                            properties: [.notify],
                                            value: nil,
                                            permissions: [.readable])
        let infoJSON: [String: String] = ["id": Self.installID, "name": UIDevice.current.name]
        let info = CBMutableCharacteristic(type: MouseProtocol.Agent.info,
                                           properties: [.read],
                                           value: try? JSONSerialization.data(withJSONObject: infoJSON),
                                           permissions: [.readable])
        let service = CBMutableService(type: MouseProtocol.Agent.service, primary: true)
        service.characteristics = [input, info]
        inputCharacteristic = input
        manager.add(service)
    }

    private func advertise() {
        guard wantsRunning, let manager, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [MouseProtocol.Agent.service],
            CBAdvertisementDataLocalNameKey: "PhoneTrackpad",
        ])
    }
}

extension AgentPeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            inputCharacteristic = nil
            publish()
        case .poweredOff:
            state = .unavailable("Bluetooth is off")
            inputCharacteristic = nil
            subscriber = nil
        case .unauthorized:
            state = .unavailable("Bluetooth permission denied — enable it in Settings")
        case .unsupported:
            state = .unavailable("Bluetooth LE peripheral mode not supported")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            state = .unavailable("Could not publish service: \(error.localizedDescription)")
            return
        }
        advertise()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            state = .unavailable("Could not advertise: \(error.localizedDescription)")
        } else if subscriber == nil {
            state = .advertising
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == MouseProtocol.Agent.input else { return }
        subscriber = central
        peripheral.setDesiredConnectionLatency(.low, for: central)
        peripheral.stopAdvertising()
        state = .connected
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == MouseProtocol.Agent.input, central == subscriber else { return }
        subscriber = nil
        state = .advertising
        advertise()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        onReadyToSend?()
    }
}
