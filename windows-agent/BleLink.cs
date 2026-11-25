using System.Text;
using System.Text.Json;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

namespace PhoneTrackpadAgent;

/// Finds a phone running PhoneTrackpad (Windows-agent mode), connects to it as a
/// BLE central, subscribes to its mouse packets and feeds them to the injector.
sealed class BleLink
{
    static readonly Guid ServiceUuid = Guid.Parse("7a1c0001-5b2e-4e8f-9c3d-2f6a8b1e4d70");
    static readonly Guid InputUuid = Guid.Parse("7a1c0002-5b2e-4e8f-9c3d-2f6a8b1e4d70");
    static readonly Guid InfoUuid = Guid.Parse("7a1c0003-5b2e-4e8f-9c3d-2f6a8b1e4d70");

    readonly MouseInjector _injector;
    readonly Approvals _approvals;
    readonly Func<Approvals.Phone, bool> _askUser;
    readonly BluetoothLEAdvertisementWatcher _watcher;
    readonly HashSet<ulong> _deniedAddresses = new();

    int _busy; // 1 while connecting or connected
    BluetoothLEDevice? _device;
    GattSession? _session;
    GattDeviceService? _service;
    GattCharacteristic? _input;

    public BleLink(MouseInjector injector, Approvals approvals, Func<Approvals.Phone, bool> askUser)
    {
        _injector = injector;
        _approvals = approvals;
        _askUser = askUser;
        _watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        _watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(ServiceUuid);
        _watcher.Received += OnAdvertisement;
        _watcher.Stopped += (_, e) =>
        {
            if (e.Error != BluetoothError.Success) Log($"Scanner stopped: {e.Error}");
        };
    }

    public void Start()
    {
        Log("Looking for a phone with PhoneTrackpad open (Windows agent mode)…");
        _watcher.Start();
    }

    public void Stop()
    {
        _watcher.Stop();
        Teardown();
    }

    async void OnAdvertisement(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        lock (_deniedAddresses)
            if (_deniedAddresses.Contains(args.BluetoothAddress)) return;
        if (Interlocked.CompareExchange(ref _busy, 1, 0) != 0) return;

        _watcher.Stop();
        try
        {
            await ConnectAsync(args.BluetoothAddress);
        }
        catch (Exception ex)
        {
            Log($"Connection failed: {ex.Message}");
            Disconnected();
        }
    }

    async Task ConnectAsync(ulong address)
    {
        Log($"Found phone {FormatAddress(address)}, connecting…");
        _device = await BluetoothLEDevice.FromBluetoothAddressAsync(address)
                  ?? throw new InvalidOperationException("device not reachable");
        _device.ConnectionStatusChanged += OnConnectionStatusChanged;

        // Keep the link up even while Windows has no pending GATT operations.
        _session = await GattSession.FromDeviceIdAsync(_device.BluetoothDeviceId);
        _session.MaintainConnection = true;

        // iPhones change their GATT table between apps, so never trust the cache.
        var services = await _device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached);
        if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            throw new InvalidOperationException($"PhoneTrackpad service not found ({services.Status})");
        _service = services.Services[0];

        var chars = await _service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
        if (chars.Status != GattCommunicationStatus.Success)
            throw new InvalidOperationException($"characteristics unavailable ({chars.Status})");
        _input = chars.Characteristics.FirstOrDefault(c => c.Uuid == InputUuid)
                 ?? throw new InvalidOperationException("input characteristic missing");
        var info = chars.Characteristics.FirstOrDefault(c => c.Uuid == InfoUuid)
                   ?? throw new InvalidOperationException("info characteristic missing");

        var phone = await ReadPhoneInfoAsync(info);
        if (!_approvals.IsApproved(phone.Id))
        {
            if (!_askUser(phone))
            {
                lock (_deniedAddresses) _deniedAddresses.Add(address);
                Log($"Ignoring \"{phone.Name}\" until the agent restarts.");
                Disconnected();
                return;
            }
            _approvals.Approve(phone);
        }

        _input.ValueChanged += OnInput;
        var status = await _input.WriteClientCharacteristicConfigurationDescriptorAsync(
            GattClientCharacteristicConfigurationDescriptorValue.Notify);
        if (status != GattCommunicationStatus.Success)
            throw new InvalidOperationException($"subscribe failed ({status})");

        Log($"Connected to \"{phone.Name}\". Move your finger on the phone.");
    }

    static async Task<Approvals.Phone> ReadPhoneInfoAsync(GattCharacteristic info)
    {
        var read = await info.ReadValueAsync(BluetoothCacheMode.Uncached);
        if (read.Status != GattCommunicationStatus.Success)
            throw new InvalidOperationException($"could not read phone info ({read.Status})");
        var json = Encoding.UTF8.GetString(ToBytes(read.Value));
        using var doc = JsonDocument.Parse(json);
        var id = doc.RootElement.GetProperty("id").GetString() ?? throw new InvalidDataException("no id");
        var name = doc.RootElement.TryGetProperty("name", out var n) ? n.GetString() ?? "iPhone" : "iPhone";
        return new Approvals.Phone(id, name);
    }

    void OnInput(GattCharacteristic sender, GattValueChangedEventArgs args) =>
        _injector.Apply(ToBytes(args.CharacteristicValue));

    void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        if (sender.ConnectionStatus == BluetoothConnectionStatus.Disconnected && _input != null)
        {
            Log("Phone disconnected.");
            Disconnected();
        }
    }

    void Disconnected()
    {
        _injector.ReleaseAll();
        Teardown();
        Interlocked.Exchange(ref _busy, 0);
        try { _watcher.Start(); } catch (Exception ex) { Log($"Could not restart scanning: {ex.Message}"); }
    }

    void Teardown()
    {
        if (_input != null) _input.ValueChanged -= OnInput;
        if (_device != null) _device.ConnectionStatusChanged -= OnConnectionStatusChanged;
        _input = null;
        _service?.Dispose();
        _service = null;
        _session?.Dispose();
        _session = null;
        _device?.Dispose();
        _device = null;
    }

    static byte[] ToBytes(IBuffer buffer)
    {
        var bytes = new byte[buffer.Length];
        using var reader = DataReader.FromBuffer(buffer);
        reader.ReadBytes(bytes);
        return bytes;
    }

    static string FormatAddress(ulong a) =>
        string.Join(":", BitConverter.GetBytes(a).Take(6).Reverse().Select(b => b.ToString("X2")));

    static void Log(string message) => Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {message}");
}
