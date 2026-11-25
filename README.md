# PhoneTrackpad

Use an iPhone screen as a trackpad for a Windows PC (or any PC), over Bluetooth.

iOS does not let apps act as a Bluetooth HID mouse: CoreBluetooth refuses to publish
the HID service. So the phone needs something on the other end that turns its
packets into real mouse input. This repo has two options, and the app supports both:

| Mode | What you need | What the PC sees |
|------|---------------|------------------|
| **Windows agent** | `windows-agent/` running on the PC | normal mouse input via `SendInput` |
| **ESP32 dongle** | an ESP32 flashed with `firmware/` | a real Bluetooth mouse (`ble-mouse`) or USB mouse (`usb-mouse`, ESP32-S3) |

The dongle needs no software on the PC and works on any OS, the login screen and BIOS (USB build).

## Gestures

| Gesture | Action |
|---|---|
| one finger drag | move pointer (speed + acceleration in Settings) |
| tap | left click |
| two-finger tap | right click |
| three-finger tap | middle click |
| two-finger drag | scroll, vertical and horizontal, with momentum |
| double-tap, hold, drag | drag with left button held |
| bottom Left / Middle / Right pads | press-and-hold buttons (hold Left + move = drag) |

## 1. iOS app (`ios/`)

Requires Xcode 16+ and an iPhone on iOS 17+. The simulator has no Bluetooth.

1. Open `ios/PhoneTrackpad.xcodeproj`.
2. Target **PhoneTrackpad → Signing & Capabilities**: pick your Team. Change the bundle id if Xcode complains.
3. Run on the iPhone. Allow Bluetooth when asked.

The app icon comes from `ios/Tools/RenderIcon.swift` (`swiftc ios/Tools/RenderIcon.swift -o /tmp/r && /tmp/r ios/Tools/AppIcon-1024.png`), scaled with `sips` into `ios/PhoneTrackpad/Icons/` (120 and 180 px). It is loose PNGs, not an asset catalog, because `actool` needs an iOS simulator runtime.

The screen stays awake while the app is open. The link drops when the app goes to the background.

## 2a. Windows agent (`windows-agent/`)

Requires Windows 10 2004+ (x64) with Bluetooth LE.

**Prebuilt:** download `PhoneTrackpadAgent.exe` from [Releases](https://github.com/zumbata/remote-mouse/releases/latest) and run it. It is self-contained, so the PC needs no .NET install.

**From source** (needs the [.NET 10 SDK](https://dotnet.microsoft.com/download)):

```powershell
cd windows-agent
dotnet run -c Release
# or a single exe to copy anywhere:
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
```

Open the app on the iPhone in **Windows agent** mode. The agent finds the phone by itself.
The first time, it asks in the console `"iPhone" wants to control this mouse. Allow? [y/N]`.
Approved phones live in `%APPDATA%\PhoneTrackpad\approved.json`; `PhoneTrackpadAgent --reset` forgets them.

To control elevated windows (Task Manager, installers), run the agent as administrator.

## 2b. ESP32 dongle (`firmware/`)

Requires [PlatformIO](https://platformio.org/install/cli) (CLI or the VS Code extension).

1. **Change the PIN** in `firmware/src/config.h` (`TRACKPAD_PASSKEY`).
2. Flash the build that matches your board:
   ```bash
   cd firmware
   pio run -e ble-mouse -t upload   # any ESP32: PC pairs with it as a Bluetooth mouse
   pio run -e usb-mouse -t upload   # ESP32-S3: plug the native USB port into the PC
   ```
3. `ble-mouse` only: on the PC open **Settings → Bluetooth → Add device**, pick
   *PhoneTrackpad Dongle* and type the PIN.
4. On the iPhone switch to **ESP32 dongle** mode, tap the dongle, type the PIN once.
   The app remembers it and reconnects on its own.

`pio device monitor` shows connections and pairing on the serial console.

## Protocol

Both links carry the same 8-byte little-endian packet:

| Byte | Field | Notes |
|---|---|---|
| 0 | type | `0x01` = mouse |
| 1 | buttons | bit0 left, bit1 right, bit2 middle; absolute state |
| 2–3 | dx | int16, pixels, + = right |
| 4–5 | dy | int16, pixels, + = down |
| 6 | wheel | int8, 1/8 notch, + = scroll up |
| 7 | hwheel | int8, 1/8 notch, + = scroll right |

Receivers apply the button state first, then the motion. Example: left+middle held,
dx −300, dy 5, wheel −3, hwheel 2 → `01 05 d4 fe 05 00 fd 02`.

| GATT | Agent mode (iPhone = peripheral) | Dongle mode (ESP32 = peripheral) |
|---|---|---|
| service | `7A1C0001-5B2E-4E8F-9C3D-2F6A8B1E4D70` | `7A1C0101-…` |
| input | `…0002`, notify | `…0102`, write without response, encrypted + authenticated |
| info | `…0003`, read: `{"id","name"}` | `…0103`, read, encrypted + authenticated (triggers PIN pairing) |

## Security notes

- **Agent mode:** the agent only accepts phones a person approved at the PC. The
  approval is keyed on an install id the phone reports, and the link is not encrypted,
  so someone sniffing nearby BLE traffic could in theory replay that id. Stop the
  agent when you don't need it.
- **Dongle mode:** pairing needs the 6-digit PIN and uses LE Secure Connections, so
  the link is encrypted. Anyone who knows the PIN can pair, so change the default.

## Status

| Part | Verified |
|---|---|
| iOS app | builds for device with Xcode 26.5 (unsigned), no warnings |
| Windows agent | builds clean on .NET 10 SDK 10.0.404; self-contained `dist/win-x64/PhoneTrackpadAgent.exe` published (PE32+ x64) |
| Packet format | Swift encoder tested against the byte layout above |
| ESP32 firmware | written against NimBLE-Arduino 2.5.2 headers, **not compiled yet** |
| Real hardware | **not tested yet**: needs an iPhone, a Windows PC and an ESP32 |

## License

[MIT](LICENSE)
