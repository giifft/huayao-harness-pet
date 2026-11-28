using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace HuaYaoPet;

public sealed record PetTask(string Platform, string Id, string Name, PetStatus Status);

/// <summary>Read only local task metadata. Utterances and tool arguments are discarded.</summary>
public sealed class CompanionTaskReader(string codexHome, string userHome)
{
    private sealed record FileStamp(long Length, DateTime Modified);
    private readonly Dictionary<string, (FileStamp Stamp, PetTask Task)> codexCache = new(StringComparer.OrdinalIgnoreCase);
    private IReadOnlyDictionary<string, string> titles = new Dictionary<string, string>();
    private FileStamp? titleStamp;
    private static readonly UTF8Encoding Utf8 = new(false, false);

    public static CompanionTaskReader ForCurrentUser()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var configured = Environment.GetEnvironmentVariable("CODEX_HOME");
        return new CompanionTaskReader(string.IsNullOrWhiteSpace(configured) ? Path.Combine(home, ".codex") : configured, home);
    }

    public IReadOnlyList<PetTask> Refresh(DateTimeOffset now, bool codex, bool workBuddy)
    {
        var tasks = new List<PetTask>();
        if (codex) tasks.AddRange(ReadCodex(now));
        if (workBuddy && OperatingSystem.IsWindows()) tasks.AddRange(ReadWorkBuddy(now));
        return tasks;
    }

    private IEnumerable<PetTask> ReadCodex(DateTimeOffset now)
    {
        var sessions = Path.Combine(codexHome, "sessions");
        var candidates = new List<(string Path, FileStamp Stamp)>();
        // Date folders are local to Codex. Include both clocks and look back over midnight.
        var days = new[] { now.Date, now.UtcDateTime.Date, now.LocalDateTime.Date }
            .SelectMany(day => new[] { day, day.AddDays(-1) }).Distinct();
        foreach (var day in days)
        {
            var directory = Path.Combine(sessions, day.ToString("yyyy", CultureInfo.InvariantCulture),
                day.ToString("MM", CultureInfo.InvariantCulture), day.ToString("dd", CultureInfo.InvariantCulture));
            try
            {
                foreach (var path in Directory.EnumerateFiles(directory, "rollout-*.jsonl"))
                {
                    if (Stamp(path) is { } stamp) candidates.Add((path, stamp));
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        var indexPath = Path.Combine(codexHome, "session_index.jsonl");
        var stampNow = Stamp(indexPath);
        if (stampNow != titleStamp)
        {
            titleStamp = stampNow;
            titles = stampNow is null ? new Dictionary<string, string>() : ReadTitles(indexPath);
        }

        var recent = candidates.OrderByDescending(entry => entry.Stamp.Modified).ThenBy(entry => entry.Path)
            .Take(64).ToArray();
        var retained = recent.Select(entry => entry.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var old in codexCache.Keys.Where(key => !retained.Contains(key)).ToArray()) codexCache.Remove(old);
        var seen = new HashSet<string>();
        foreach (var entry in recent)
        {
            if (seen.Count == 32 || now.UtcDateTime - entry.Stamp.Modified > TimeSpan.FromMinutes(15)) break;
            if (!codexCache.TryGetValue(entry.Path, out var result) || result.Stamp != entry.Stamp)
            {
                if (ReadCodexFile(entry.Path, entry.Stamp) is { } task)
                    codexCache[entry.Path] = result = (entry.Stamp, task);
            }
            if (result.Task is not { } item || !seen.Add(item.Id)) continue;
            var name = titles.TryGetValue(item.Id, out var title) && title.Length > 0 ? $"{item.Name} · {title}" : item.Name;
            yield return item with { Name = name, Status = Expire(item.Status, now, 90, 1800) };
        }
    }

    private static PetTask? ReadCodexFile(string path, FileStamp stamp)
    {
        try
        {
            using var stream = Open(path);
            var header = ReadPrefix(stream, Math.Min((int)Math.Min(stamp.Length, int.MaxValue), 256 * 1024));
            var lineEnd = header.IndexOf('\n');
            if (lineEnd < 0) return null;
            using var row = JsonDocument.Parse(header.AsMemory(0, lineEnd));
            if (Text(row.RootElement, "type") != "session_meta") return null;
            var meta = Child(row.RootElement, "payload");
            var source = Child(meta, "source");
            if (Child(source, "subagent").ValueKind != JsonValueKind.Undefined ||
                Child(source, "sub_agent").ValueKind != JsonValueKind.Undefined) return null;
            var suffix = Path.GetFileNameWithoutExtension(path);
            var id = Text(meta, "id") ?? Text(meta, "session_id") ?? suffix[^Math.Min(36, suffix.Length)..];
            var cwd = Text(meta, "cwd")?.TrimEnd('/', '\\') ?? "";
            var project = Label(cwd.Split('/', '\\').LastOrDefault()) ?? $"会话 {id[..Math.Min(8, id.Length)]}";
            var calls = new Dictionary<string, (string Label, bool Question)>();
            var status = new PetStatus(PetPhase.Idle, "");
            long timestamp = 0;
            foreach (var line in TailLines(stream, 1024 * 1024))
            {
                try
                {
                    using var parsed = JsonDocument.Parse(line);
                    var root = parsed.RootElement;
                    var kind = Text(root, "type");
                    var payload = Child(root, "payload");
                    var type = Text(payload, "type");
                    var phase = status.Phase;
                    if (kind == "event_msg")
                    {
                        switch (type)
                        {
                            case "task_started": case "turn_started": case "user_message":
                                calls.Clear(); phase = PetPhase.Thinking; break;
                            case "task_complete": case "turn_completed":
                                calls.Clear(); phase = PetPhase.Done; break;
                            case "turn_aborted":
                                calls.Clear(); phase = PetPhase.Cancelled; break;
                            case "error" when Child(payload, "will_retry").ValueKind != JsonValueKind.True:
                                calls.Clear(); phase = PetPhase.Error; break;
                            case "token_count" or "item_completed" when status.Busy: break;
                            default: continue;
                        }
                    }
                    else if (kind == "response_item")
                    {
                        var call = Text(payload, "call_id") ?? Text(payload, "id");
                        switch (type)
                        {
                            case "function_call" or "custom_tool_call" or "web_search_call":
                                var name = type == "web_search_call" ? "web_search" : Text(payload, "name");
                                if (call is not null) calls[call] = (ToolLabel(name), name == "request_user_input");
                                phase = calls.Values.Any(x => x.Question) ? PetPhase.Waiting : PetPhase.Working;
                                break;
                            case "function_call_output" or "custom_tool_call_output" when status.Busy:
                                if (call is not null) calls.Remove(call);
                                phase = calls.Values.Any(x => x.Question) ? PetPhase.Waiting :
                                    calls.Count > 0 ? PetPhase.Working : PetPhase.Thinking;
                                break;
                            case "reasoning" when phase == PetPhase.Idle || status.Busy:
                                if (phase == PetPhase.Idle) phase = PetPhase.Thinking;
                                break;
                            default: continue;
                        }
                    }
                    else continue;
                    if (DateTimeOffset.TryParse(Text(root, "timestamp"), CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal, out var date)) timestamp = date.ToUnixTimeMilliseconds();
                    var detail = phase == PetPhase.Working && calls.Count > 0 ? calls.Values.Last().Label : "";
                    status = new PetStatus(phase, detail, timestamp)
                    { WaitKind = phase == PetPhase.Waiting ? HarnessWaitKind.Question : null };
                }
                catch (JsonException) { }
            }
            return new PetTask("Codex", id, project, status);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    private static IReadOnlyDictionary<string, string> ReadTitles(string path)
    {
        var found = new Dictionary<string, string>();
        try
        {
            using var stream = Open(path);
            foreach (var line in TailLines(stream, 512 * 1024))
            {
                try
                {
                    using var item = JsonDocument.Parse(line);
                    var id = Text(item.RootElement, "id");
                    if (id != null && Label(Text(item.RootElement, "thread_name")) is { } name) found[id] = name;
                }
                catch (JsonException) { }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return found;
    }

    private IEnumerable<PetTask> ReadWorkBuddy(DateTimeOffset now)
    {
        foreach (var name in new[] { ".workbuddy", ".ygsoftworkbuddy" })
        {
            var path = Path.Combine(userHome, name, "workbuddy.db");
            if (!File.Exists(path)) continue;
            foreach (var (id, phase, time) in WorkBuddyDatabase.Read(path, now.AddMinutes(-30).ToUnixTimeMilliseconds()))
            {
                var status = Expire(new PetStatus(phase, phase == PetPhase.Working ? "正在处理任务" : "", time), now, 600, 1800);
                yield return new PetTask("WorkBuddy", $"{name}/{id}", $"本地任务 {id[..Math.Min(id.Length, 8)]}", status);
            }
        }
    }

    private static PetStatus Expire(PetStatus status, DateTimeOffset now, int activeSeconds, int waitingSeconds)
    {
        var age = now.ToUnixTimeMilliseconds() - status.Activity;
        var threshold = status.Phase == PetPhase.Waiting ? waitingSeconds : status.Busy ? activeSeconds : 15;
        return age > threshold * 1000 ? status with { Phase = PetPhase.Idle, Detail = "" } : status;
    }

    private static FileStamp? Stamp(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? new FileStamp(info.Length, info.LastWriteTimeUtc) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    private static FileStream Open(string path) => new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);

    private static string ReadPrefix(FileStream stream, int limit)
    {
        var bytes = new byte[limit];
        return Utf8.GetString(bytes.AsSpan(0, stream.ReadAtLeast(bytes, limit, false)));
    }

    private static IEnumerable<string> TailLines(FileStream stream, int limit)
    {
        var offset = Math.Max(0, stream.Length - limit);
        stream.Position = offset;
        var fields = ReadPrefix(stream, limit).Split('\n');
        // Skip partial records at both ends, including a record still being written.
        return fields.Skip(offset == 0 ? 0 : 1).Take(Math.Max(0, fields.Length - (offset == 0 ? 1 : 2)));
    }

    private static JsonElement Child(JsonElement item, string name) =>
        item.ValueKind == JsonValueKind.Object && item.TryGetProperty(name, out var value) ? value : default;
    private static string? Text(JsonElement item, string name) =>
        Child(item, name) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;
    private static string? Label(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var result = string.Join(' ', text[..Math.Min(text.Length, 120)].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return result[..Math.Min(result.Length, 48)];
    }

    private static string ToolLabel(string? name) => name switch
    {
        "exec_command" or "write_stdin" or "shell" or "shell_command" => "她在敲命令",
        "apply_patch" or "write_file" or "edit_file" => "在修改文件",
        "read_file" or "list_dir" => "在读文件",
        "web_search" or "web_fetch" => "在查资料",
        _ => "在调用工具"
    };
}

internal static class WorkBuddyDatabase
{
    private const string Library = "winsqlite3";
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string query, int size,
        out IntPtr statement, IntPtr tail);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr statement, int index);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr statement, int index);

    internal static IReadOnlyList<(string Id, PetPhase Phase, long Time)> Read(string path, long since)
    {
        var tasks = new List<(string, PetPhase, long)>();
        IntPtr db = IntPtr.Zero;
        IntPtr statement = IntPtr.Zero;
        try
        {
            if (sqlite3_open_v2(path, out db, 1, IntPtr.Zero) != 0) return tasks;
            sqlite3_busy_timeout(db, 150);
            const string query = """
                SELECT rowid, status, COALESCE(NULLIF(last_activity_at, 0), updated_at) FROM sessions
                WHERE deleted_at IS NULL AND updated_at >= ?1
                ORDER BY updated_at DESC LIMIT 32
                """;
            if (sqlite3_prepare_v2(db, query, -1, out statement, IntPtr.Zero) != 0) return tasks;
            sqlite3_bind_int64(statement, 1, since);
            int result;
            while ((result = sqlite3_step(statement)) == 100)
            {
                var id = sqlite3_column_int64(statement, 0).ToString(CultureInfo.InvariantCulture);
                var phase = Marshal.PtrToStringUTF8(sqlite3_column_text(statement, 1))?.ToLowerInvariant() switch
                {
                    "pending" or "awaiting_input" or "waiting" => PetPhase.Waiting,
                    "planning" or "thinking" => PetPhase.Thinking,
                    "working" or "running" or "active" or "stopping" or "in_progress" => PetPhase.Working,
                    "completed" => PetPhase.Done,
                    "terminated" or "cancelled" => PetPhase.Cancelled,
                    "error" or "failed" => PetPhase.Error,
                    _ => PetPhase.Idle
                };
                tasks.Add((id, phase, sqlite3_column_int64(statement, 2)));
            }
            if (result != 101) tasks.Clear();
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { }
        finally
        {
            if (statement != IntPtr.Zero) sqlite3_finalize(statement);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
        return tasks;
    }
}
