import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 12) {
            header
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(white: 0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color(white: 0.22), lineWidth: 1)
                    )
                TrackpadView(mouse: model.mouse)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                if model.mode == .dongle && !model.isConnected {
                    DonglePicker(dongle: model.dongle)
                        .padding()
                } else if !model.isConnected {
                    Text("Start PhoneTrackpadAgent on the PC.\nIt connects to this phone by itself.")
                        .multilineTextAlignment(.center)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            buttonsRow
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.activate()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.mode.title).font(.subheadline.weight(.semibold))
                Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }

    private var buttonsRow: some View {
        HStack(spacing: 10) {
            MouseButtonView(label: "Left", button: .left, mouse: model.mouse)
            MouseButtonView(label: "Middle", button: .middle, mouse: model.mouse)
                .frame(maxWidth: 70)
            MouseButtonView(label: "Right", button: .right, mouse: model.mouse)
        }
        .frame(height: 76)
    }
}

/// A press-and-hold button: down on touch, up on lift, so holding it while
/// moving a finger on the trackpad drags.
struct MouseButtonView: View {
    let label: String
    let button: MouseButtons
    let mouse: MouseController
    @State private var isDown = false

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isDown ? Color(white: 0.3) : Color(white: 0.16))
            .overlay(Text(label).font(.footnote.weight(.medium)).foregroundStyle(.secondary))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDown { isDown = true; mouse.press(button) }
                    }
                    .onEnded { _ in
                        isDown = false
                        mouse.release(button)
                    }
            )
            .accessibilityLabel("\(label) mouse button")
    }
}

struct DonglePicker: View {
    let dongle: DongleCentral

    var body: some View {
        VStack(spacing: 12) {
            if case .scanning = dongle.state, dongle.found.isEmpty {
                ProgressView()
                Text("Power the ESP32 dongle and keep it close.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if case .failed = dongle.state {
                Button("Scan again") { dongle.forget() }
            }
            ForEach(dongle.found) { item in
                Button {
                    dongle.connect(item.id)
                } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(item.name)
                        Spacer()
                        Text("\(item.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 320)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var mouse = model.mouse
        NavigationStack {
            Form {
                Section("Connection") {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(AppModel.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if model.mode == .dongle, model.dongle.remembered != nil {
                        Button("Forget this dongle", role: .destructive) { model.dongle.forget() }
                    }
                }
                Section("Pointer") {
                    LabeledSlider(title: "Speed", value: $mouse.sensitivity, range: 0.5...4)
                    LabeledSlider(title: "Acceleration", value: $mouse.acceleration, range: 0...1.5)
                }
                Section("Scrolling") {
                    LabeledSlider(title: "Scroll speed", value: $mouse.scrollSpeed, range: 0.3...3)
                    Toggle("Natural scrolling", isOn: $mouse.naturalScroll)
                }
                Section {
                    Toggle("Tap to click", isOn: $mouse.tapToClick)
                    Toggle("Haptic feedback", isOn: $mouse.haptics)
                } footer: {
                    Text("Tap = left click · two-finger tap = right click · three-finger tap = middle click · two-finger drag = scroll · double-tap and hold = drag")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(1))).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
