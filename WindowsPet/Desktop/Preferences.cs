using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace HuaYaoPet;

internal sealed class Preferences
{
    private static readonly string SettingsFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HuaYaoPet", "settings.json");

    public string Mode { get; set; } = "duo";
    public Dictionary<string, string> Poses { get; set; } = new();
    public bool Petals { get; set; } = true;
    public bool AutoChat { get; set; } = true;
    public bool Link { get; set; } = true;
    public bool Top { get; set; } = true;
    public double Zoom { get; set; } = 1;
    public double? Left { get; set; }
    public double? TopPosition { get; set; }

    public static Preferences Load()
    {
        try
        {
            var prefs = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(SettingsFile)) ?? new Preferences();
            prefs.Poses ??= new();
            return prefs;
        }
        catch (Exception problem) when (problem is IOException or JsonException or UnauthorizedAccessException)
        {
            return new Preferences();
        }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsFile)!);
            var temp = SettingsFile + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this));
            File.Move(temp, SettingsFile, true);
        }
        catch (Exception problem) when (problem is IOException or UnauthorizedAccessException)
        {
            // Keep the current session's settings even if the profile is read-only.
        }
    }
}
