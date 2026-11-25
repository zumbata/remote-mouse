using Windows.Devices.Bluetooth;

namespace PhoneTrackpadAgent;

static class Program
{
    static readonly object ConsoleGate = new();

    static async Task<int> Main(string[] args)
    {
        Console.Title = "PhoneTrackpad Agent";
        var approvals = new Approvals();

        if (args.Contains("--reset"))
        {
            approvals.Reset();
            Console.WriteLine("Forgot all approved phones.");
            return 0;
        }

        var adapter = await BluetoothAdapter.GetDefaultAsync();
        if (adapter == null || !adapter.IsLowEnergySupported)
        {
            Console.Error.WriteLine("No Bluetooth LE adapter found. Turn Bluetooth on, or plug in a BLE 4.0+ dongle.");
            return 1;
        }

        Console.WriteLine("PhoneTrackpad Agent — Ctrl+C to quit, --reset to forget approved phones.");
        Console.WriteLine($"Approved phones: {approvals.FilePath}");

        var link = new BleLink(new MouseInjector(), approvals, AskUser);
        var quit = new TaskCompletionSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; quit.TrySetResult(); };

        link.Start();
        await quit.Task;
        link.Stop();
        return 0;
    }

    /// First connection from an unknown phone: only a person at this PC can allow it.
    static bool AskUser(Approvals.Phone phone)
    {
        lock (ConsoleGate)
        {
            Console.WriteLine();
            Console.Write($"\"{phone.Name}\" wants to control this mouse. Allow? [y/N] ");
            var answer = Console.ReadLine()?.Trim().ToLowerInvariant();
            return answer is "y" or "yes";
        }
    }
}
