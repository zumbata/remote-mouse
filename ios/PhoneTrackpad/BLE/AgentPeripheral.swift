import CoreBluetooth
import Foundation
import Observation
import UIKit

/// Windows-agent mode: the iPhone advertises a custom GATT service and the
/// PhoneTrackpad agent on the PC connects to it and subscribes to mouse packets.
///
/// A subscription alone does not prove the agent is still listening: Windows can
/// keep a link (and its subscription) open after the agent gave up on it. So the
/// agent writes to the ping characteristic every second, the phone only reports
/// "connected" while pings arrive, and it never stops advertising, so a
/// restarted agent can always find it again.
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
    @ObservationIgnored var onLinkReset: (() -> Void)?
    @ObservationIgnored private var manager: CBPeripheralManager?
    @ObservationIgnored private var inputCharacteristic: CBMutableCharacteristic?
    @ObservationIgnored private var subscriber: CBCentral?
    @ObservationIgnored private var lastPing = Date.distantPast
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var wantsRunning = false

    /// No ping for this long means the agent is gone, whatever the link layer says.
    private static let staleAfter: TimeInterval = 4

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
        watchdog?.invalidate()
        watchdog = nil
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
        let ping = CBMutableCharacteristic(type: MouseProtocol.Agent.ping,
                                           properties: [.write],
                                           value: nil,
                                           permissions: [.writeable])
        let service = CBMutableService(type: MouseProtocol.Agent.service, primary: true)
        service.characteristics = [input, info, ping]
        inputCharacteristic = input
        manager.add(service)
        startWatchdog()
    }

    private func advertise() {
        guard wantsRunning, let manager, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [MouseProtocol.Agent.service],
            CBAdvertisementDataLocalNameKey: "PhoneTrackpad",
        ])
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.subscriber != nil,
                  Date().timeIntervalSince(self.lastPing) > Self.staleAfter else { return }
            self.dropLink()
        }
    }

    private func dropLink() {
        guard subscriber != nil else { return }
        subscriber = nil
        state = .advertising
        onLinkReset?()
        advertise()
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
            onLinkReset?()
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
        // A newer subscriber wins: it is the agent that is actually listening now.
        if subscriber != nil, subscriber != central { onLinkReset?() }
        subscriber = central
        lastPing = Date() // grace period until the first ping arrives
        peripheral.setDesiredConnectionLatency(.low, for: central)
        state = .connected
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == MouseProtocol.Agent.input, central == subscriber else { return }
        dropLink()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        for request in requests where request.characteristic.uuid == MouseProtocol.Agent.ping {
            if request.central == subscriber { lastPing = Date() }
        }
        peripheral.respond(to: first, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        onReadyToSend?()
    }
}
