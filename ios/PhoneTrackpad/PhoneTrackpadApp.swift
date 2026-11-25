import SwiftUI

@main
struct PhoneTrackpadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}

/// Owns the two transports and points the mouse at whichever mode is selected.
@Observable
final class AppModel {
    enum Mode: String, CaseIterable, Identifiable {
        case agent, dongle
        var id: String { rawValue }
        var title: String { self == .agent ? "Windows agent" : "ESP32 dongle" }
    }

    let mouse = MouseController()
    let agent = AgentPeripheral()
    let dongle = DongleCentral()

    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .agent {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            if oldValue != mode { activate() }
        }
    }

    func activate() {
        mouse.releaseAll()
        switch mode {
        case .agent:
            dongle.stop()
            mouse.transport = agent
            agent.start()
        case .dongle:
            agent.stop()
            mouse.transport = dongle
            dongle.start()
        }
    }

    var isConnected: Bool { mode == .agent ? agent.isLinkUp : dongle.isLinkUp }

    var statusText: String {
        switch mode {
        case .agent:
            switch agent.state {
            case .off: return "Off"
            case .unavailable(let why): return why
            case .advertising: return "Waiting for the PC agent…"
            case .connected: return "Connected to PC"
            }
        case .dongle:
            switch dongle.state {
            case .off: return "Off"
            case .unavailable(let why): return why
            case .scanning: return "Looking for dongles…"
            case .connecting(let name): return "Connecting to \(name)…"
            case .pairing(let name): return "Pairing with \(name)…"
            case .connected(let name): return "Connected to \(name)"
            case .failed(let why): return why
            }
        }
    }
}
