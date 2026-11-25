using System.Text.Json;

namespace PhoneTrackpadAgent;

/// Phones the user has allowed to control this PC, stored in %APPDATA%\PhoneTrackpad\approved.json.
sealed class Approvals
{
    public sealed record Phone(string Id, string Name);

    readonly string _path;
    readonly List<Phone> _phones;
    readonly object _gate = new();

    public Approvals()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PhoneTrackpad");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "approved.json");
        _phones = File.Exists(_path)
            ? JsonSerializer.Deserialize<List<Phone>>(File.ReadAllText(_path)) ?? new()
            : new();
    }

    public bool IsApproved(string id)
    {
        lock (_gate) return _phones.Any(p => p.Id == id);
    }

    public void Approve(Phone phone)
    {
        lock (_gate)
        {
            _phones.RemoveAll(p => p.Id == phone.Id);
            _phones.Add(phone);
            File.WriteAllText(_path, JsonSerializer.Serialize(_phones, new JsonSerializerOptions { WriteIndented = true }));
        }
    }

    public void Reset()
    {
        lock (_gate)
        {
            _phones.Clear();
            if (File.Exists(_path)) File.Delete(_path);
        }
    }

    public string FilePath => _path;
}
