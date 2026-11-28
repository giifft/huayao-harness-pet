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
    public bool CodexLink { get; set; } = true;
    public bool WorkBuddyLink { get; set; } = true;
    public bool TraeLink { get; set; }
    public bool AntigravityLink { get; set; }
    public bool DoubaoLink { get; set; }
    public bool Top { get; set; } = true;
    public double Zoom { get; set; } = 1;
    public double? Left { get; set; }
    public double? TopPosition { get; set; }
    public int? ScreenPixelLeft { get; set; }
    public int? ScreenPixelTop { get; set; }
    public long TasksClearedAt { get; set; }
    public EdgeSettings Edges { get; set; } = new();
    public bool StatePoses { get; set; } = true;
    public Dictionary<PetCue, CueSettings> Cues { get; set; } = new();
    public Dictionary<BubbleEvent, string> Bubbles { get; set; } = new();
    public Dictionary<BubbleEvent, byte[]> BubblePictures { get; set; } = new();
    public Dictionary<BubbleEvent, int> BubbleDurations { get; set; } = new();
    public Dictionary<BubbleEvent, string> BubbleLinks { get; set; } = new();
    public bool RandomTapBubble { get; set; }
    public bool BubbleImageAboveText { get; set; }

    public static Preferences Load()
    {
        try
        {
            var prefs = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(SettingsFile)) ?? new Preferences();
            prefs.Poses ??= new();
            prefs.Edges ??= new();
            prefs.Cues ??= new();
            prefs.Bubbles ??= new();
            prefs.BubblePictures ??= new();
            prefs.BubbleDurations ??= new();
            prefs.BubbleLinks ??= new();
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
