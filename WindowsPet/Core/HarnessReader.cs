using System.Text.Json;
using ZstdSharp;

namespace HuaYaoPet;

public enum PetPhase { Offline, Idle, Thinking, Working, Waiting, Done, Cancelled, Error }

public sealed record PetStatus(PetPhase Phase, string Detail, long Activity = 0)
{
    public bool Busy => Phase is PetPhase.Thinking or PetPhase.Working or PetPhase.Waiting;

    public string Label => Phase switch
    {
        PetPhase.Offline => $"Harness · {Detail}",
        PetPhase.Idle => string.IsNullOrEmpty(Detail) ? "空闲" : $"空闲 · {Detail}",
        PetPhase.Thinking => string.IsNullOrEmpty(Detail) ? "思考中" : $"思考中 · {Detail}",
        PetPhase.Working => $"干活中 · {Detail}",
        PetPhase.Waiting => "待确认 · 请回 Harness 确认",
        PetPhase.Done => "完成 · 刚忙完一轮",
        PetPhase.Cancelled => "已中止",
        PetPhase.Error => "出错 · 本轮遇到问题",
        _ => Detail
    };
}

public sealed class HarnessReader(string root)
{
    private record Stamp(string Path, DateTime Modified, DateTime Created, long Bytes);
    private record Cursor(long Seq, long Time, string Type);

    private static readonly string[] FileNames = ["session.v4.jsonl.zstd", "session.v3.jsonl.zstd"];
    private static readonly StringComparer Paths = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
    private Stamp? current;
    private Cursor? cursor;
    private bool currentHasEvents;
    private readonly HashSet<string> childFiles = new(Paths);
    private PetStatus raw = new(PetPhase.Idle, "");
    private string model = "";
    private readonly List<(string Id, string Label)> tools = [];
    private readonly HashSet<string> approvals = [];

    public static HarnessReader ForCurrentUser()
    {
        var home = Environment.GetEnvironmentVariable("DSH_HOME")?.Trim();
        if (string.IsNullOrEmpty(home))
            home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dsh");
        return new HarnessReader(Path.Combine(home, "sessions"));
    }

    public PetStatus Refresh(DateTimeOffset now)
    {
        var candidates = Folders(root)
            .SelectMany(workspace => Folders(workspace).Prepend(workspace))
            .Select(path => FileNames.Select(name => Inspect(Path.Combine(path, name))).FirstOrDefault(file => file != null))
            .OfType<Stamp>()
            .OrderByDescending(file => file.Modified)
            .ThenBy(file => file.Path, Paths)
            .ToArray();
        childFiles.IntersectWith(candidates.Select(file => file.Path));

        bool temporarilyUnreadable = false;
        foreach (var file in candidates)
        {
            if (childFiles.Contains(file.Path)) continue;
            if (file == current) return Display(now);
            try
            {
                if (!Read(file)) continue;
                return Display(now);
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or JsonException or ZstdException)
            {
                temporarilyUnreadable = true;
                if (current != null && Paths.Equals(file.Path, current.Path)) return Display(now);
            }
        }
        Reset();
        current = null;
        cursor = null;
        currentHasEvents = false;
        return new PetStatus(PetPhase.Offline, temporarilyUnreadable ? "会话暂时无法读取" : "暂无会话");
    }

    private bool Read(Stamp file)
    {
        // Commit the scan only after the snapshot has been read and validated.
        using var input = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var decoded = new DecompressionStream(input);
        using var lines = new StreamReader(decoded);
        using var header = JsonDocument.Parse(lines.ReadLine() ?? throw new InvalidDataException("Missing header."));
        var h = header.RootElement;
        if (Text(h, "type") != "session") throw new InvalidDataException("Unexpected session header.");
        if (Number(h, "delegationDepth") > 0 || Child(h, "parentSession").ValueKind is JsonValueKind.Object or JsonValueKind.String)
        {
            childFiles.Add(file.Path);
            return false;
        }

        var wasCurrent = current != null && Paths.Equals(current.Path, file.Path);
        var previousCursor = wasCurrent ? cursor : null;
        var previousHadEvents = wasCurrent && currentHasEvents;
        var oldRaw = raw;
        var oldModel = model;
        var oldTools = tools.ToArray();
        var oldApprovals = approvals.ToArray();
        var historical = !wasCurrent;
        var matched = previousCursor == null;

        // Rebuild from the file in one pass. The old sequence marker distinguishes replay from a new turn.
        Reset();
        Cursor? last = null;
        try
        {
            while (lines.ReadLine() is { } line)
            {
                if (line.Length == 0) continue;
                using var document = JsonDocument.Parse(line);
                var row = document.RootElement;
                var seq = Number(row, "seq");
                var time = Number(row, "time");
                var type = Text(row, "type");
                if (seq == null || time == null || string.IsNullOrEmpty(type)) continue;
                last = new Cursor(seq.Value, time.Value, type);
                if (last == previousCursor) matched = true;
                Reduce(type, time.Value, Child(row, "data"));
            }

            if (file != Inspect(file.Path)) throw new IOException("Session was replaced while reading.");
            historical |= previousHadEvents && !matched;
            if (historical && !raw.Busy)
                raw = raw with { Phase = PetPhase.Idle, Detail = "" };
            current = file;
            cursor = last;
            currentHasEvents = last != null;
            return true;
        }
        catch
        {
            raw = oldRaw;
            model = oldModel;
            tools.Clear();
            tools.AddRange(oldTools);
            approvals.Clear();
            approvals.UnionWith(oldApprovals);
            throw;
        }
    }

    private void Reset()
    {
        raw = new PetStatus(PetPhase.Idle, "");
        tools.Clear();
        approvals.Clear();
        model = "";
    }

    private PetStatus Display(DateTimeOffset now)
    {
        var age = now.ToUnixTimeMilliseconds() - raw.Activity;
        if (raw.Phase == PetPhase.Idle || age > (raw.Busy ? 90_000 : 14_000))
            return new PetStatus(PetPhase.Idle, model, raw.Activity);
        return raw;
    }

    private void Reduce(string type, long time, JsonElement data)
    {
        switch (type)
        {
            case "model/selection":
            case "request/context":
                if (Text(data, "model") is { Length: > 0 } id)
                    model = id.Split('/')[^1];
                if (raw.Phase == PetPhase.Thinking)
                    raw = raw with { Detail = model };
                return;
            case "turn/start":
                tools.Clear();
                approvals.Clear();
                break;
            case "step/start":
            case "assistant/attempt":
            case "assistant/message":
                break;
            case "tool/call":
                var call = Text(data, "callId");
                if (!string.IsNullOrEmpty(call))
                {
                    tools.RemoveAll(tool => tool.Id == call);
                    tools.Add((call, ToolLabel(Text(data, "name"))));
                }
                break;
            case "tool/result":
                var result = Text(Child(data, "message"), "toolCallId");
                if (result != null) tools.RemoveAll(tool => tool.Id == result);
                break;
            case "approval/asked":
                approvals.Add(Text(data, "id") ?? "");
                break;
            case "approval/decided":
                approvals.Remove(Text(data, "id") ?? "");
                break;
            case "turn/end":
                var phase = Text(Child(data, "reason"), "kind") switch
                {
                    "error" => PetPhase.Error,
                    "aborted" or "cancelled" => PetPhase.Cancelled,
                    _ => PetPhase.Done
                };
                tools.Clear();
                approvals.Clear();
                raw = new PetStatus(phase, "", time);
                return;
            default:
                return;
        }

        raw = approvals.Count > 0 ? new PetStatus(PetPhase.Waiting, "", time)
            : tools.Count > 0 ? new PetStatus(PetPhase.Working, tools[^1].Label, time)
            : new PetStatus(PetPhase.Thinking, model, time);
    }

    private static string ToolLabel(string? name) => name?.ToLowerInvariant() switch
    {
        "read" or "read_file" => "在翻文件",
        "write" or "write_file" => "在写字",
        "edit" or "edit_file" => "在改稿子",
        "bash" or "exec_command" => "在跑命令",
        "glob" => "在找文件",
        "grep" => "在查字句",
        "web_search" => "在查资料",
        "web_fetch" => "在看网页",
        _ => "在调用工具"
    };

    private static JsonElement Child(JsonElement item, string key) =>
        item.ValueKind == JsonValueKind.Object && item.TryGetProperty(key, out var value) ? value : default;
    private static string? Text(JsonElement item, string key) =>
        Child(item, key) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;
    private static long? Number(JsonElement item, string key) =>
        Child(item, key) is { ValueKind: JsonValueKind.Number } value && value.TryGetInt64(out var n) ? n : null;

    private static string[] Folders(string path)
    {
        try { return Directory.GetDirectories(path); }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { return []; }
    }

    private static Stamp? Inspect(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? new Stamp(path, info.LastWriteTimeUtc, info.CreationTimeUtc, info.Length) : null;
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { return null; }
    }
}
