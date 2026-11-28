using System.Diagnostics;
using System.Text;
using System.Text.Json;
using ZstdSharp;
using ZstdSharp.Unsafe;

namespace HuaYaoPet;

public enum PetPhase { Offline, Idle, Thinking, Working, Waiting, Done, Cancelled, Error }

public sealed record PetStatus(PetPhase Phase, string Detail, long Activity = 0)
{
    public HarnessUsageSummary? Usage { get; init; }
    public HarnessWaitKind? WaitKind { get; init; }
    public string? SessionId { get; init; }
    public string? SessionTitle { get; init; }
    public string? ProjectName { get; init; }
    public bool Busy => Phase is PetPhase.Thinking or PetPhase.Working or PetPhase.Waiting;

    public string Label => Phase switch
    {
        PetPhase.Offline => $"Harness · {Detail}",
        PetPhase.Idle => string.IsNullOrEmpty(Detail) ? "空闲" : $"空闲 · {Detail}",
        PetPhase.Thinking => string.IsNullOrEmpty(Detail) ? "思考中" : $"思考中 · {Detail}",
        PetPhase.Working => $"干活中 · {Detail}",
        PetPhase.Waiting => WaitKind == HarnessWaitKind.Question ? "待回答 · 请回 Harness 回复" : "待确认 · 请回 Harness 确认",
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

    private const long MaxCompressedBytes = 64 * 1024 * 1024;

    private sealed class SessionLines(StreamReader reader)
    {
        private const int MaxCharacters = 32 * 1024 * 1024;
        private const int MaxLineCharacters = 2 * 1024 * 1024;
        private readonly char[] buffer = new char[8192];
        private readonly Stopwatch elapsed = Stopwatch.StartNew();
        private int index, length, total;

        public string? ReadLine()
        {
            var line = new StringBuilder();
            while (true)
            {
                if (elapsed.ElapsedMilliseconds >= 5000)
                    throw new InvalidDataException("Session read timed out.");
                if (index == length)
                {
                    index = 0;
                    length = reader.Read(buffer);
                    total += length;
                    if (total > MaxCharacters)
                        throw new InvalidDataException("Session exceeds the decoded size limit.");
                    if (length == 0) return line.Length == 0 ? null : line.ToString();
                }

                var remaining = buffer.AsSpan(index, length - index);
                int newline = remaining.IndexOf('\n');
                int count = newline < 0 ? remaining.Length : newline;
                if (line.Length + count > MaxLineCharacters)
                    throw new InvalidDataException("Session record exceeds the line length limit.");
                line.Append(remaining[..count]);
                index += count;
                if (newline >= 0)
                {
                    index++;
                    if (line.Length > 0 && line[^1] == '\r') line.Length--;
                    return line.ToString();
                }
            }
        }
    }

    private static readonly string[] FileNames = ["session.v4.jsonl.zstd", "session.v3.jsonl.zstd"];
    private static readonly StringComparer Paths = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
    private Stamp? current;
    private Cursor? cursor;
    private bool currentHasEvents;
    private readonly HashSet<string> childFiles = new(Paths);
    private readonly Dictionary<string, (Stamp Stamp, IReadOnlyList<HarnessUsageRound> Rounds)> usageFiles = new(Paths);
    private readonly Dictionary<string, (Stamp Stamp, DateTimeOffset After)> usageRetry = new(Paths);
    private PetStatus raw = new(PetPhase.Idle, "");
    private HarnessUsageSummary? usageSummary;
    private string model = "";
    private readonly List<(string Id, string Label, bool IsQuestion)> tools = [];
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
        RefreshUsage(candidates, now);

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
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or InvalidDataException or JsonException or ZstdException)
            {
                temporarilyUnreadable = true;
                if (current != null && Paths.Equals(file.Path, current.Path)) return Display(now);
            }
        }
        Reset();
        current = null;
        cursor = null;
        currentHasEvents = false;
        return new PetStatus(PetPhase.Offline, temporarilyUnreadable ? "会话暂时无法读取" : "暂无会话") { Usage = usageSummary };
    }

    private void RefreshUsage(Stamp[] files, DateTimeOffset now)
    {
        // Cap per-poll work so a large archive does not stall the task monitor on startup.
        var candidates = files.Take(512).ToArray();
        var paths = candidates.Select(file => file.Path).ToHashSet(Paths);
        foreach (var path in usageFiles.Keys.Where(path => !paths.Contains(path)).ToArray()) usageFiles.Remove(path);
        foreach (var path in usageRetry.Keys.Where(path => !paths.Contains(path)).ToArray()) usageRetry.Remove(path);
        var elapsed = Stopwatch.StartNew();
        int budget = 4;
        foreach (var file in candidates)
        {
            if (budget == 0 || elapsed.ElapsedMilliseconds >= 400) break;
            if (usageFiles.TryGetValue(file.Path, out var saved) && saved.Stamp == file) continue;
            if (usageRetry.TryGetValue(file.Path, out var retry) && retry.Stamp == file && retry.After > now) continue;
            budget--;
            try
            {
                usageFiles[file.Path] = (file, ReadUsage(file));
                usageRetry.Remove(file.Path);
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or InvalidDataException or JsonException or ZstdException)
            {
                usageRetry[file.Path] = (file, now.AddSeconds(30));
            }
        }
        var pending = candidates.Length < files.Length || candidates.Any(file => usageFiles.GetValueOrDefault(file.Path).Stamp != file);
        var rounds = candidates.SelectMany(file => usageFiles.GetValueOrDefault(file.Path).Rounds ?? []);
        usageSummary = HarnessUsageSummary.Make(rounds, now, HarnessPricing.Bundled, pending);
    }

    private static IReadOnlyList<HarnessUsageRound> ReadUsage(Stamp file)
    {
        using var input = OpenSnapshot(file);
        using var decoded = new DecompressionStream(input);
        decoded.SetParameter(ZSTD_dParameter.ZSTD_d_windowLogMax, 26);
        using var text = new StreamReader(decoded);
        var lines = new SessionLines(text);
        using var header = JsonDocument.Parse(lines.ReadLine() ?? throw new InvalidDataException("Missing header."));
        var h = header.RootElement;
        if (Text(h, "type") != "session") throw new InvalidDataException("Unexpected session header.");
        var fold = new HarnessUsageFold(Text(h, "id") ?? Path.GetDirectoryName(file.Path) ?? file.Path, HarnessPricing.Bundled);
        for (int count = 1; lines.ReadLine() is { } line; count++)
        {
            if (count >= 50_000) throw new InvalidDataException("Session exceeds the record limit.");
            if (line.Length == 0) continue;
            using var document = JsonDocument.Parse(line);
            var row = document.RootElement;
            if (Number(row, "seq") is long seq && Number(row, "time") is long time && Text(row, "type") is string type)
                fold.Accept(type, Child(row, "data"), seq, time);
        }
        if (file != Inspect(file.Path)) throw new IOException("Session was replaced while reading.");
        return fold.Rounds;
    }

    private static FileStream OpenSnapshot(Stamp file)
    {
        if (file.Bytes > MaxCompressedBytes) throw new InvalidDataException("Compressed session exceeds the size limit.");
        var input = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (input.Length <= MaxCompressedBytes) return input;
        input.Dispose();
        throw new InvalidDataException("Compressed session exceeds the size limit.");
    }

    private static string SessionFolder(string filename) => Path.GetFileName(Path.GetDirectoryName(filename)) ?? filename;

    private bool Read(Stamp file)
    {
        // Commit the scan only after the snapshot has been read and validated.
        using var input = OpenSnapshot(file);
        using var decoded = new DecompressionStream(input);
        decoded.SetParameter(ZSTD_dParameter.ZSTD_d_windowLogMax, 26);
        using var text = new StreamReader(decoded);
        var lines = new SessionLines(text);
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
        raw = raw with
        {
            SessionId = Text(h, "id") ?? SessionFolder(file.Path),
            ProjectName = Text(h, "cwd")?.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault()
        };
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
                raw = raw with { Phase = PetPhase.Idle, Detail = "", WaitKind = null };
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
        var hold = raw.Phase == PetPhase.Waiting ? 900_000 : raw.Busy ? 90_000 : 14_000;
        if (raw.Phase == PetPhase.Idle || age > hold)
            return raw with { Phase = PetPhase.Idle, Detail = model, WaitKind = null, Usage = usageSummary };
        return raw with { Usage = usageSummary };
    }

    private void Reduce(string type, long time, JsonElement data)
    {
        switch (type)
        {
            case "session/title":
                if (Text(data, "title") is string title) raw = raw with { SessionTitle = title };
                return;
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
                break;
            case "assistant/message":
                if (Text(Child(Child(data, "message"), "source"), "model") is { Length: > 0 } sourceModel)
                    model = sourceModel.Split('/')[^1];
                break;
            case "tool/call":
                var call = Text(data, "callId");
                if (!string.IsNullOrEmpty(call))
                {
                    tools.RemoveAll(tool => tool.Id == call);
                    var name = Text(data, "name");
                    tools.Add((call, ToolLabel(name), string.Equals(name, "ask_user_question", StringComparison.OrdinalIgnoreCase)));
                }
                break;
            case "tool/result":
                var result = Text(Child(data, "message"), "toolCallId");
                if (result != null) tools.RemoveAll(tool => tool.Id == result);
                else if (tools.Count > 0) tools.RemoveAt(0);
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
                raw = raw with { Phase = phase, Detail = "", Activity = time, WaitKind = null };
                return;
            default:
                return;
        }

        HarnessWaitKind? wait = approvals.Count > 0 ? HarnessWaitKind.Approval
            : tools.Any(tool => tool.IsQuestion) ? HarnessWaitKind.Question : null;
        raw = wait is not null ? raw with { Phase = PetPhase.Waiting, Detail = "", Activity = time, WaitKind = wait }
            : tools.Count > 0 ? raw with { Phase = PetPhase.Working, Detail = tools[^1].Label, Activity = time, WaitKind = null }
            : raw with { Phase = PetPhase.Thinking, Detail = model, Activity = time, WaitKind = null };
    }

    private static string ToolLabel(string? name) => name?.ToLowerInvariant() switch
    {
        "read" or "read_file" => "在翻文件",
        "write" or "write_file" => "在写字",
        "edit" or "edit_file" => "在改稿子",
        "bash" or "exec_command" => "她在敲命令",
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
