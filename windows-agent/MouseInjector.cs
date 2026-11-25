using System.Buffers.Binary;
using System.Runtime.InteropServices;

namespace PhoneTrackpadAgent;

/// Replays PhoneTrackpad packets as real mouse input through SendInput.
/// Packet layout is documented in the repo README and ios/PhoneTrackpad/MouseProtocol.swift.
sealed class MouseInjector
{
    const int PacketLength = 8;
    const byte PacketTypeMouse = 0x01;
    const int WheelDelta = 120;     // one notch in Windows units
    const int WheelUnitsPerNotch = 8; // packet wheel values are 1/8 notch

    byte _buttons;
    readonly object _gate = new();

    public void Apply(ReadOnlySpan<byte> p)
    {
        if (p.Length < PacketLength || p[0] != PacketTypeMouse) return;

        byte buttons = p[1];
        short dx = BinaryPrimitives.ReadInt16LittleEndian(p[2..]);
        short dy = BinaryPrimitives.ReadInt16LittleEndian(p[4..]);
        sbyte wheel = unchecked((sbyte)p[6]);
        sbyte hwheel = unchecked((sbyte)p[7]);

        var inputs = new List<INPUT>(6);
        lock (_gate)
        {
            // Buttons first: motion in a packet happened with its button state already in effect.
            AddButton(inputs, buttons, 0x01, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
            AddButton(inputs, buttons, 0x02, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
            AddButton(inputs, buttons, 0x04, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP);
            _buttons = buttons;
        }

        if (dx != 0 || dy != 0)
            inputs.Add(Mouse(MOUSEEVENTF_MOVE, dx, dy, 0));
        // Partial notches give smooth scrolling in apps that support it (browsers, Office, VS Code).
        if (wheel != 0)
            inputs.Add(Mouse(MOUSEEVENTF_WHEEL, 0, 0, wheel * WheelDelta / WheelUnitsPerNotch));
        if (hwheel != 0)
            inputs.Add(Mouse(MOUSEEVENTF_HWHEEL, 0, 0, hwheel * WheelDelta / WheelUnitsPerNotch));

        Send(inputs);
    }

    /// Releases any held button, e.g. when the phone disconnects mid-drag.
    public void ReleaseAll() => Apply(new byte[] { PacketTypeMouse, 0, 0, 0, 0, 0, 0, 0 });

    void AddButton(List<INPUT> inputs, byte next, byte mask, uint down, uint up)
    {
        bool was = (_buttons & mask) != 0, now = (next & mask) != 0;
        if (was != now) inputs.Add(Mouse(now ? down : up, 0, 0, 0));
    }

    static INPUT Mouse(uint flags, int dx, int dy, int data) => new()
    {
        type = INPUT_MOUSE,
        U = new InputUnion { mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = unchecked((uint)data), dwFlags = flags } },
    };

    static void Send(List<INPUT> inputs)
    {
        if (inputs.Count == 0) return;
        var arr = inputs.ToArray();
        uint sent = SendInput((uint)arr.Length, arr, Marshal.SizeOf<INPUT>());
        if (sent != arr.Length)
            Console.Error.WriteLine($"SendInput dropped input (error {Marshal.GetLastWin32Error()}). " +
                                    "Input into elevated windows needs the agent to run as administrator.");
    }

    const uint INPUT_MOUSE = 0;
    const uint MOUSEEVENTF_MOVE = 0x0001;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;
    const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    const uint MOUSEEVENTF_WHEEL = 0x0800;
    const uint MOUSEEVENTF_HWHEEL = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    // MOUSEINPUT is the largest member of the native union, so it alone sets the size.
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
}
