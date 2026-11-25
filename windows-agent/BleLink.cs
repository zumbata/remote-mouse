using System.Text;
using System.Text.Json;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Foundation;
using Windows.Storage.Streams;

namespace PhoneTrackpadAgent;

/// Finds a phone running PhoneTrackpad (Windows-agent mode), connects to it as a
/// BLE central, subscribes to its mouse packets and feeds them to the injector.
///
/// Every second it writes to the phone's ping characteristic. The phone uses the
/// pings to tell a live agent from a stale Windows link, and three failed pings
/// tell the agent the phone is gone, so it drops the link and scans again.
sealed class BleLink
{
    static readonly Guid ServiceUuid = Guid.Parse("7a1c0001-5b2e-4e8f-9c3d-2f6a8b1e4d70");
    static readonly Guid InputUuid = Guid.Parse("7a1c0002-5b2e-4e8f-9c3d-2f6a8b1e4d70");
    static readonly Guid InfoUuid = Guid.Parse("7a1c0003-5b2e-4e8f-9c3d-2f6a8b1e4d70");
    static readonly Guid PingUuid = Guid.Parse("7a1c0004-5b2e-4e8f-9c3d-2f6a8b1e4d70");

    static readonly TimeSpan PingInterval = TimeSpan.FromSeconds(1);
    static readonly TimeSpan PingTimeout = TimeSpan.FromSeconds(3);
    const int MaxPingFailures = 3;

    readonly MouseInjector _injector;
    readonly Approvals _approvals;
    readonly Func<Approvals.Phone, bool> _askUser;
    readonly bool _verbose;
    readonly BluetoothLEAdvertisementWatcher _watcher;
    readonly HashSet<ulong> _deniedAddresses = new();
    readonly object _gate = new();

    // Each connection attempt gets a generation; callbacks from an older one are ignored,
    // so a late disconnect event can never tear down the connection that replaced it.
    int _generation;
    bool _busy; // connecting or connected
    BluetoothLEDevice? _device;
    TypedEventHandler<BluetoothLEDevice, object>? _statusHandler;
    GattSession? _session;
    GattDeviceService? _service;
    GattCharacteristic? _input;
    CancellationTokenSource? _heartbeat;
    long _packets;

    public BleLink(MouseInjector injector, Approvals approvals, Func<Approvals.Phone, bool> askUser, bool verbose)
    {
        _injector = injector;
        _approvals = approvals;
        _askUser = askUser;
        _verbose = verbose;
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
        if (_verbose) _ = ReportStatsAsync();
    }

    public void Stop()
    {
        _watcher.Stop();
        lock (_gate) Teardown();
    }

    async void OnAdvertisement(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        int generation;
        lock (_gate)
        {
            if (_busy || _deniedAddresses.Contains(args.BluetoothAddress)) return;
            _busy = true;
            generation = ++_generation;
        }

        _watcher.Stop();
        try
        {
            await ConnectAsync(args.BluetoothAddress, generation);
        }
        catch (Exception ex)
        {
            Log($"Connection failed: {ex.Message}");
            Disconnected(generation);
        }
    }

    async Task ConnectAsync(ulong address, int generation)
    {
        Log($"Found phone {FormatAddress(address)}, connecting…");
        var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address)
                     ?? throw new InvalidOperationException("device not reachable");
        lock (_gate)
        {
            _device = device;
            _statusHandler = (d, _) =>
            {
                if (d.ConnectionStatus != BluetoothConnectionStatus.Disconnected) return;
                Log("Phone disconnected.");
                Disconnected(generation);
            };
            device.ConnectionStatusChanged += _statusHandler;
        }

        // Keep the link up even while Windows has no pending GATT operations.
        _session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId);
        _session.MaintainConnection = true;

        // iPhones change their GATT table between apps, so never trust the cache.
        var services = await device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached);
        if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            throw new InvalidOperationException($"PhoneTrackpad service not found ({services.Status})");
        _service = services.Services[0];

        var chars = await _service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
        if (chars.Status != GattCommunicationStatus.Success)
            throw new InvalidOperationException($"characteristics unavailable ({chars.Status})");
        var input = chars.Characteristics.FirstOrDefault(c => c.Uuid == InputUuid)
                    ?? throw new InvalidOperationException("input characteristic missing");
        var info = chars.Characteristics.FirstOrDefault(c => c.Uuid == InfoUuid)
                   ?? throw new InvalidOperationException("info characteristic missing");
        var ping = chars.Characteristics.FirstOrDefault(c => c.Uuid == PingUuid)
                   ?? throw new InvalidOperationException("ping characteristic missing — update the iPhone app");

        var phone = await ReadPhoneInfoAsync(info);
        if (!_approvals.IsApproved(phone.Id))
        {
            if (!_askUser(phone))
            {
                lock (_gate) _deniedAddresses.Add(address);
                Log($"Ignoring \"{phone.Name}\" until the agent restarts.");
                Disconnected(generation);
                return;
            }
            _approvals.Approve(phone);
        }

        lock (_gate)
        {
            if (generation != _generation) return; // replaced while we were waiting
            _input = input;
            _input.ValueChanged += OnInput;
        }
        var status = await input.WriteClientCharacteristicConfigurationDescriptorAsync(
            GattClientCharacteristicConfigurationDescriptorValue.Notify);
        if (status != GattCommunicationStatus.Success)
            throw new InvalidOperationException($"subscribe failed ({status})");

        var heartbeat = new CancellationTokenSource();
        lock (_gate) _heartbeat = heartbeat;
        _ = HeartbeatAsync(ping, generation, heartbeat.Token);

        Log($"Connected to \"{phone.Name}\". Move your finger on the phone.");
    }

    async Task HeartbeatAsync(GattCharacteristic ping, int generation, CancellationToken ct)
    {
        int failures = 0;
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(PingInterval, ct); }
            catch (OperationCanceledException) { return; }

            var ok = false;
            try
            {
                using var writer = new DataWriter();
                writer.WriteByte(0);
                var result = await ping.WriteValueAsync(writer.DetachBuffer(), GattWriteOption.WriteWithResponse)
                                       .AsTask(ct).WaitAsync(PingTimeout, ct);
                ok = result == GattCommunicationStatus.Success;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception ex)
            {
                if (_verbose) Log($"ping error: {ex.Message}");
            }

            if (ok) { failures = 0; continue; }
            if (++failures < MaxPingFailures) continue;
            Log("Phone stopped answering, reconnecting…");
            Disconnected(generation);
            return;
        }
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

    void OnInput(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        Interlocked.Increment(ref _packets);
        _injector.Apply(ToBytes(args.CharacteristicValue));
    }

    void Disconnected(int generation)
    {
        lock (_gate)
        {
            if (generation != _generation || !_busy) return;
            Teardown();
            _busy = false;
        }
        _injector.ReleaseAll();
        try { _watcher.Start(); } catch (Exception ex) { Log($"Could not restart scanning: {ex.Message}"); }
    }

    // Caller holds _gate.
    void Teardown()
    {
        _heartbeat?.Cancel();
        _heartbeat?.Dispose();
        _heartbeat = null;
        if (_input != null) _input.ValueChanged -= OnInput;
        if (_device != null && _statusHandler != null) _device.ConnectionStatusChanged -= _statusHandler;
        _statusHandler = null;
        _input = null;
        _service?.Dispose();
        _service = null;
        _session?.Dispose();
        _session = null;
        _device?.Dispose();
        _device = null;
    }

    async Task ReportStatsAsync()
    {
        while (true)
        {
            await Task.Delay(TimeSpan.FromSeconds(5));
            var n = Interlocked.Exchange(ref _packets, 0);
            if (n > 0) Log($"{n} packets in the last 5 s");
        }
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
