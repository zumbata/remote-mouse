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

The agent pings the phone every second. The phone shows *Connected* only while pings arrive and keeps advertising, so a restarted agent always finds it again; after 3 missed pings the agent drops the link and scans. `--verbose` prints packet counts every 5 s, useful when the pointer does not move.

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
   `usb-mouse` targets 4 MB flash boards such as the ESP32-S3-Zero. On an 8 MB
   board you can drop `board_upload.flash_size` and `board_build.partitions` from
   `platformio.ini`.
3. `ble-mouse` only: on the PC open **Settings → Bluetooth → Add device**, pick
   *PhoneTrackpad Dongle* and type the PIN.
4. On the iPhone open the PhoneTrackpad app, switch to **ESP32 dongle** mode, tap the
   dongle and type the PIN once. The app remembers it and reconnects on its own.
   The dongle does **not** show up in the iPhone's Settings → Bluetooth: iOS lists
   only devices it knows how to use, and the dongle speaks a custom BLE service that
   only the app understands. Pair from the app.

`pio device monitor` shows connections and pairing on the serial console (`ble-mouse`
only: `usb-mouse` turns the USB port into a mouse, so it has no serial console).

**Re-flashing a `usb-mouse` board.** Once flashed, the board shows up as a USB mouse
and its serial port (`/dev/cu.usbmodem…`, `COMx`) is gone, so `upload` can't find it.
Put it in download mode first: hold **BOOT**, press and release **RESET** (or plug the
cable in while holding BOOT), release BOOT, then run the upload again.

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
| ping | `…0004`, write with response: the agent writes 1 byte every second | n/a |

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
| ESP32 firmware | `usb-mouse` builds clean (Arduino-ESP32 3.3.12, NimBLE-Arduino 2.5.2); `ble-mouse` **not compiled yet** |
| Real hardware | `usb-mouse` on an ESP32-S3-Zero, plugged into a Mac: iPhone pairs from the app with the PIN and the pointer works. Agent mode on a Windows PC and `ble-mouse` **not tested yet** |

## License

[MIT](LICENSE)
