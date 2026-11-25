// PhoneTrackpad dongle.
//
// The iPhone connects over Bluetooth LE and writes 8-byte mouse packets
// (layout in ../README.md). The dongle replays them to the PC either as a
// Bluetooth LE HID mouse (env:ble-mouse) or a USB HID mouse (env:usb-mouse).

#include <Arduino.h>
#include <NimBLEDevice.h>

#include "config.h"

#ifndef TRACKPAD_OUTPUT_USB
#define TRACKPAD_OUTPUT_USB 0
#endif

#if TRACKPAD_OUTPUT_USB
#include "USB.h"
#include "USBHIDMouse.h"
static USBHIDMouse usbMouse;
#else
#include <NimBLEHIDDevice.h>
static NimBLECharacteristic* hidInput = nullptr;
#endif

static const char* kControlService = "7a1c0101-5b2e-4e8f-9c3d-2f6a8b1e4d70";
static const char* kControlInput = "7a1c0102-5b2e-4e8f-9c3d-2f6a8b1e4d70";
static const char* kControlInfo = "7a1c0103-5b2e-4e8f-9c3d-2f6a8b1e4d70";

static constexpr uint8_t kPacketTypeMouse = 0x01;
static constexpr int kWheelUnitsPerNotch = 8;
static constexpr uint8_t kMaxConnections = 2; // the iPhone, plus the PC in BLE mode

struct Packet {
  uint8_t buttons;
  int16_t dx, dy;
  int8_t wheel, hwheel;
};

static NimBLEServer* server = nullptr;
static QueueHandle_t packets = nullptr;
static volatile uint16_t controllerHandle = BLE_HS_CONN_HANDLE_NONE;

static uint8_t heldButtons = 0;
static int wheelRemainder = 0, panRemainder = 0;

// ---------------------------------------------------------------------------
// HID output

#if !TRACKPAD_OUTPUT_USB
// Report ID 1: 5 buttons, X, Y, wheel (all relative, int8), then AC Pan (horizontal wheel).
static const uint8_t kReportMap[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x02,        // Usage (Mouse)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x01,        //   Report ID (1)
    0x09, 0x01,        //   Usage (Pointer)
    0xA1, 0x00,        //   Collection (Physical)
    0x05, 0x09,        //     Usage Page (Button)
    0x19, 0x01,        //     Usage Minimum (1)
    0x29, 0x05,        //     Usage Maximum (5)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x95, 0x05,        //     Report Count (5)
    0x75, 0x01,        //     Report Size (1)
    0x81, 0x02,        //     Input (Data, Var, Abs)
    0x95, 0x01,        //     Report Count (1)
    0x75, 0x03,        //     Report Size (3)
    0x81, 0x03,        //     Input (Const) padding
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x09, 0x31,        //     Usage (Y)
    0x09, 0x38,        //     Usage (Wheel)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x75, 0x08,        //     Report Size (8)
    0x95, 0x03,        //     Report Count (3)
    0x81, 0x06,        //     Input (Data, Var, Rel)
    0x05, 0x0C,        //     Usage Page (Consumer)
    0x0A, 0x38, 0x02,  //     Usage (AC Pan)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x75, 0x08,        //     Report Size (8)
    0x95, 0x01,        //     Report Count (1)
    0x81, 0x06,        //     Input (Data, Var, Rel)
    0xC0,              //   End Collection
    0xC0,              // End Collection
};
#endif

static void sendReport(int8_t x, int8_t y, int8_t wheel, int8_t pan) {
#if TRACKPAD_OUTPUT_USB
  usbMouse.move(x, y, wheel, pan);
#else
  const uint8_t report[5] = {heldButtons, (uint8_t)x, (uint8_t)y, (uint8_t)wheel, (uint8_t)pan};
  hidInput->setValue(report, sizeof(report));
  // Send only to the PC. If iOS ever subscribed to the HID report, the phone would move its own pointer.
  for (uint16_t handle : server->getPeerDevices()) {
    if (handle == controllerHandle) continue;
    for (int attempt = 0; attempt < 5 && !hidInput->notify(report, sizeof(report), handle); attempt++) {
      vTaskDelay(pdMS_TO_TICKS(2)); // radio buffers full; wait for the next connection event
    }
  }
#endif
}

static void setButtons(uint8_t buttons) {
  if (buttons == heldButtons) return;
#if TRACKPAD_OUTPUT_USB
  for (uint8_t bit : {MOUSE_LEFT, MOUSE_RIGHT, MOUSE_MIDDLE}) {
    bool was = heldButtons & bit, now = buttons & bit;
    heldButtons = (heldButtons & ~bit) | (buttons & bit);
    if (was != now) now ? usbMouse.press(bit) : usbMouse.release(bit);
  }
#else
  heldButtons = buttons;
  sendReport(0, 0, 0, 0);
#endif
}

static int8_t takeChunk(int& value) {
  int chunk = constrain(value, -127, 127);
  value -= chunk;
  return (int8_t)chunk;
}

static void applyPacket(const Packet& p) {
  // Buttons first: motion in a packet happened with its button state already in effect.
  setButtons(p.buttons & 0x07);

  // Wheel arrives in 1/8 notches; HID wants whole notches, so carry the rest.
  wheelRemainder += p.wheel;
  panRemainder += p.hwheel;
  int wheel = wheelRemainder / kWheelUnitsPerNotch;
  int pan = panRemainder / kWheelUnitsPerNotch;
  wheelRemainder -= wheel * kWheelUnitsPerNotch;
  panRemainder -= pan * kWheelUnitsPerNotch;

  int dx = p.dx, dy = p.dy;
  while (dx || dy || wheel || pan) {
    int8_t cx = takeChunk(dx), cy = takeChunk(dy), cw = takeChunk(wheel), cp = takeChunk(pan);
    sendReport(cx, cy, cw, cp);
  }
}

// ---------------------------------------------------------------------------
// BLE

static bool decode(const uint8_t* b, size_t len, Packet& out) {
  if (len != 8 || b[0] != kPacketTypeMouse) return false;
  out.buttons = b[1];
  out.dx = (int16_t)(b[2] | (b[3] << 8));
  out.dy = (int16_t)(b[4] | (b[5] << 8));
  out.wheel = (int8_t)b[6];
  out.hwheel = (int8_t)b[7];
  return true;
}

class ControlCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    NimBLEAttValue value = c->getValue();
    Packet p;
    if (!decode(value.data(), value.size(), p)) return;
    controllerHandle = info.getConnHandle();
    xQueueSend(packets, &p, 0); // never block the BLE host task; a full queue drops motion
  }
};

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
    Serial.printf("connected: %s\n", info.getAddress().toString().c_str());
    // 7.5–15 ms interval keeps the pointer responsive.
    s->updateConnParams(info.getConnHandle(), 6, 12, 0, 400);
    if (s->getConnectedCount() < kMaxConnections) NimBLEDevice::startAdvertising();
  }

  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& info, int reason) override {
    Serial.printf("disconnected: %s (reason %d)\n", info.getAddress().toString().c_str(), reason);
    if (info.getConnHandle() == controllerHandle) {
      controllerHandle = BLE_HS_CONN_HANDLE_NONE;
      Packet release{};
      xQueueSend(packets, &release, 0); // drop any held button
    }
    NimBLEDevice::startAdvertising();
  }

  void onAuthenticationComplete(NimBLEConnInfo& info) override {
    if (!info.isEncrypted() || !info.isAuthenticated()) {
      Serial.println("pairing failed or not authenticated, dropping link");
      NimBLEDevice::getServer()->disconnect(info.getConnHandle());
      return;
    }
    Serial.printf("paired: %s\n", info.getAddress().toString().c_str());
  }
};

static void setupBle() {
  NimBLEDevice::init(TRACKPAD_DEVICE_NAME);
  NimBLEDevice::setPower(9);
  // Bonding + MITM + Secure Connections. The dongle "displays" a fixed PIN that
  // the phone (and PC) must type, so a stranger in range cannot pair.
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);
  NimBLEDevice::setSecurityPasskey(TRACKPAD_PASSKEY);

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  server->advertiseOnDisconnect(true);

  NimBLEService* control = server->createService(kControlService);
  NimBLECharacteristic* input = control->createCharacteristic(
      kControlInput, NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::WRITE_AUTHEN);
  input->setCallbacks(new ControlCallbacks());
  // The app reads this first; because it needs an authenticated link, iOS shows the PIN prompt.
  NimBLECharacteristic* info = control->createCharacteristic(
      kControlInfo, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::READ_AUTHEN);
  info->setValue(TRACKPAD_OUTPUT_USB ? "PhoneTrackpad dongle 1.0 usb" : "PhoneTrackpad dongle 1.0 ble");

  NimBLEAdvertisementData adv;
  adv.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  adv.addServiceUUID(NimBLEUUID(kControlService));

#if !TRACKPAD_OUTPUT_USB
  auto* hid = new NimBLEHIDDevice(server);
  hid->setManufacturer("PhoneTrackpad");
  hid->setPnp(0x02, 0xe502, 0xa111, 0x0100);
  hid->setHidInfo(0x00, 0x01);
  hid->setReportMap((uint8_t*)kReportMap, sizeof(kReportMap));
  hid->setBatteryLevel(100);
  hidInput = hid->getInputReport(1);
  adv.setAppearance(HID_MOUSE);
  adv.addServiceUUID(hid->getHidService()->getUUID());
#endif

  server->start();

  NimBLEAdvertisementData scanResponse;
  scanResponse.setName(TRACKPAD_DEVICE_NAME);
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->setAdvertisementData(adv);
  advertising->setScanResponseData(scanResponse);
  advertising->enableScanResponse(true);
  advertising->start();
}

// ---------------------------------------------------------------------------

void setup() {
  Serial.begin(115200);
  packets = xQueueCreate(64, sizeof(Packet));

#if TRACKPAD_OUTPUT_USB
  usbMouse.begin();
  USB.productName("PhoneTrackpad");
  USB.begin();
#endif

  setupBle();
  Serial.printf("%s ready, PIN %06d\n", TRACKPAD_DEVICE_NAME, TRACKPAD_PASSKEY);
}

void loop() {
  Packet p;
  if (xQueueReceive(packets, &p, pdMS_TO_TICKS(20)) != pdTRUE) return;

  // Merge queued motion that shares the same buttons, so a slow link sends fewer, larger reports.
  Packet next;
  while (xQueuePeek(packets, &next, 0) == pdTRUE && next.buttons == p.buttons) {
    int dx = p.dx + next.dx, dy = p.dy + next.dy, w = p.wheel + next.wheel, h = p.hwheel + next.hwheel;
    if (dx < INT16_MIN || dx > INT16_MAX || dy < INT16_MIN || dy > INT16_MAX ||
        w < INT8_MIN || w > INT8_MAX || h < INT8_MIN || h > INT8_MAX) break;
    xQueueReceive(packets, &next, 0);
    p.dx = dx; p.dy = dy; p.wheel = w; p.hwheel = h;
  }
  applyPacket(p);
}
