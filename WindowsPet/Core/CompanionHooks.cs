using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace HuaYaoPet;

/// <summary>Installs and receives read-only observation hooks. The child returns the host's normal allow/stop response.</summary>
public sealed partial class CompanionHooks(string profile, string storage)
{
    private sealed record Signal(string Id, string Project, PetPhase Phase, long Activity, HarnessWaitKind? WaitKind);
    private const string Marker = "--huayao-task-hook";
    private const string Group = "huayao-desktop-pet-status";
    private static readonly string[] TraeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification"];
    private static readonly string[] AntigravityEvents = ["SessionStart", "PreInvocation", "PreToolUse", "PostToolUse", "Stop"];

    public static CompanionHooks ForCurrentUser() => new(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HuaYaoPet"));

    private string Config(string platform) => platform == "TRAE"
        ? Path.Combine(profile, ".trae-cn", "hooks.json")
        : Path.Combine(profile, ".gemini", "config", "hooks.json");

    private string Events(string platform) => Path.Combine(storage, "TaskSignals", platform);

    private static bool Supported(string platform) => platform is "TRAE" or "Antigravity";

    public void Install(string platform, string executable)
    {
        if (!Supported(platform)) throw new ArgumentException("未知平台。", nameof(platform));
        if (!Path.IsPathFullyQualified(executable) || executable.IndexOfAny(['"', '%', '!', '\r', '\n', '`', '$']) >= 0)
            throw new IOException("桌宠路径含有 Hook shell 无法安全解析的字符，请移动应用再配置。");
        Edit(platform, root =>
        {
            if (platform == "TRAE")
            {
                if (root["hooks"] is null) root["hooks"] = new JsonObject();
                if (root["hooks"] is not JsonObject hooks) throw new JsonException("TRAE hooks 配置格式不受支持。");
                foreach (var name in TraeEvents)
                {
                    if (hooks[name] is null) hooks[name] = new JsonArray();
                    if (hooks[name] is not JsonArray groups) throw new JsonException("TRAE Hook 配置格式不受支持。");
                    RemoveTraeHandlers(groups);
                    var group = new JsonObject { ["hooks"] = new JsonArray(Handler(executable, platform, name)) };
                    if (name is "PreToolUse" or "PostToolUse" or "Notification") group["matcher"] = "*";
                    groups.Add(group);
                }
                if (root["version"] is null) root["version"] = 1;
                return true;
            }

            if (root[Group] is JsonNode installed && !HasAntigravityHandler(installed))
                throw new IOException("现有 Antigravity 同名 Hook 属于其他程序。");
            var definition = new JsonObject { ["enabled"] = true };
            foreach (var name in AntigravityEvents)
            {
                var handlers = new JsonArray(Handler(executable, platform, name));
                definition[name] = name is "PreToolUse" or "PostToolUse"
                    ? new JsonArray(new JsonObject { ["matcher"] = "*", ["hooks"] = handlers }) : handlers;
            }
            root[Group] = definition;
            return true;
        });
    }

    public void Uninstall(string platform)
    {
        if (!Supported(platform)) return;
        Edit(platform, root =>
        {
            if (platform == "Antigravity")
            {
                if (!HasAntigravityHandler(root[Group])) return false;
                return root.Remove(Group);
            }

            if (root["hooks"] is not JsonObject hooks) return false;
            var changed = false;
            foreach (var name in TraeEvents)
            {
                if (hooks[name] is not JsonArray groups || !RemoveTraeHandlers(groups)) continue;
                changed = true;
                if (groups.Count == 0) hooks.Remove(name);
            }
            return changed;
        });
    }

    private void Edit(string platform, Func<JsonObject, bool> apply)
    {
        using var mutex = new Mutex(false, @"Local\HuaYaoPet.HookConfiguration");
        Enter(mutex);
        try
        {
            var path = Config(platform);
            var root = File.Exists(path)
                ? JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? throw new JsonException("Hook 配置不是 JSON 对象。")
                : new JsonObject();
            if (apply(root)) WriteAtomic(path, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }
        finally { mutex.ReleaseMutex(); }
    }

    private static JsonObject Handler(string path, string platform, string name) => new()
    {
        ["type"] = "command", ["command"] = $"\"{path}\" {Marker} {platform} {name}", ["timeout"] = 5
    };

    private static bool OwnHandler(JsonNode? value, string platform) =>
        value is JsonObject item && item["command"] is JsonValue command &&
        command.TryGetValue<string>(out var text) && text.Contains($" {Marker} {platform} ", StringComparison.Ordinal);

    private static bool HasAntigravityHandler(JsonNode? node) =>
        node is JsonObject root && root["PreInvocation"] is JsonArray handlers &&
        handlers.Any(item => OwnHandler(item, "Antigravity"));

    private static bool RemoveTraeHandlers(JsonArray groups)
    {
        var changed = false;
        for (var index = groups.Count - 1; index >= 0; index--)
        {
            if (groups[index] is not JsonObject group || group["hooks"] is not JsonArray handlers) continue;
            var removed = false;
            for (var item = handlers.Count - 1; item >= 0; item--)
            {
                if (!OwnHandler(handlers[item], "TRAE")) continue;
                handlers.RemoveAt(item);
                removed = true;
            }
            if (!removed) continue;
            changed = true;
            if (handlers.Count == 0) groups.RemoveAt(index);
        }
        return changed;
    }

    public void Observe(string platform, string name, string input, DateTimeOffset now)
    {
        if (!Supported(platform)) return;
        // Older TRAE builds put the actual event in stdin even when the command ignores it.
        using var parsed = JsonDocument.Parse(input);
        var payload = parsed.RootElement;
        var id = Text(payload, platform == "TRAE" ? "session_id" : "conversationId");
        if (string.IsNullOrEmpty(id) || id.Length > 256) return;
        if (platform == "Antigravity" && !Guid.TryParse(id, out _)) return;
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id)))[..32];
        var path = Path.Combine(Events(platform), key + ".json");
        using var mutex = new Mutex(false, @"Local\HuaYaoPet.HookSignals." + key);
        Enter(mutex);
        try
        {
            var previous = ReadSignal(path);
            var timestamp = now.ToUnixTimeMilliseconds();
            if (previous?.Activity > timestamp) return;
            var phase = Transition(platform, name, payload, previous?.Phase);
            if (phase is null) return;
            var project = platform == "Antigravity" ? Project(payload) : "";
            var wait = phase == PetPhase.Waiting
                ? (Text(payload, "notification_type") == "ask_user_question" ? HarnessWaitKind.Question : HarnessWaitKind.Approval)
                : (HarnessWaitKind?)null;
            var item = new Signal(key, project.Length > 0 ? project : previous?.Project ?? "", phase.Value, timestamp, wait);
            WriteAtomic(path, JsonSerializer.Serialize(item));
            if (previous is null) Prune(Events(platform), now);
        }
        finally { mutex.ReleaseMutex(); }
    }

    private static PetPhase? Transition(string platform, string name, JsonElement payload, PetPhase? previous)
    {
        if (name == "SessionStart") return PetPhase.Idle;
        if (name == "PreToolUse") return PetPhase.Working;
        if (name == "PostToolUse") return previous is PetPhase.Done or PetPhase.Cancelled or PetPhase.Error ? null : PetPhase.Thinking;
        if (platform == "TRAE")
        {
            if (name == "UserPromptSubmit") return PetPhase.Thinking;
            if (name == "Stop") return PetPhase.Done;
            if (name != "Notification" || previous == PetPhase.Done) return null;
            return Text(payload, "notification_type") switch
            {
                "idle_prompt" => PetPhase.Done,
                "permission_prompt" or "ask_user_question" or "document_review" or "browser_interaction" => PetPhase.Waiting,
                _ => null
            };
        }

        if (name == "PreInvocation") return PetPhase.Thinking;
        if (name != "Stop") return null;
        if (Child(payload, "fullyIdle").ValueKind == JsonValueKind.False) return PetPhase.Working;
        if (!string.IsNullOrEmpty(Text(payload, "error"))) return PetPhase.Error;
        return Text(payload, "terminationReason") switch
        {
            "model_stop" => PetPhase.Done,
            "error" or "max_steps_exceeded" => PetPhase.Error,
            "cancelled" or "canceled" or "aborted" or "user_cancelled" => PetPhase.Cancelled,
            _ => PetPhase.Idle
        };
    }

    public IReadOnlyList<PetTask> Read(string platform, DateTimeOffset now)
    {
        if (!Supported(platform)) return [];
        var directory = Events(platform);
        if (!Directory.Exists(directory)) return [];
        try
        {
            var cutoff = now.AddMinutes(-30).ToUnixTimeMilliseconds();
            return Directory.EnumerateFiles(directory, "*.json").Select(path => new FileInfo(path))
                .Where(info => info.Length <= 16 * 1024 && info.LastWriteTimeUtc >= now.AddMinutes(-30).UtcDateTime)
                .OrderByDescending(info => info.LastWriteTimeUtc).Take(64).Select(info => ReadSignal(info.FullName))
                .Where(item => item is not null && item.Activity >= cutoff).Select(item =>
                {
                    var signal = item!;
                    var phase = signal.Phase;
                    var ttl = phase is PetPhase.Thinking or PetPhase.Working ? 90 : phase == PetPhase.Waiting ? 1800 : 15;
                    if (now.ToUnixTimeMilliseconds() - signal.Activity > ttl * 1000) phase = PetPhase.Idle;
                    var name = signal.Project.Length > 0 ? signal.Project : $"会话 {signal.Id[..Math.Min(8, signal.Id.Length)]}";
                    return new PetTask(platform, signal.Id, name, new PetStatus(phase,
                        phase == PetPhase.Working ? "在调用工具" : "", signal.Activity) { WaitKind = signal.WaitKind });
                }).ToArray();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return []; }
    }

    private static Signal? ReadSignal(string path)
    {
        try
        {
            if (new FileInfo(path).Length > 16 * 1024) return null;
            var signal = JsonSerializer.Deserialize<Signal>(File.ReadAllText(path));
            return signal is { Id.Length: 32, Project: not null } && Enum.IsDefined(signal.Phase) ? signal : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    private static void Prune(string directory, DateTimeOffset now)
    {
        try
        {
            foreach (var path in Directory.EnumerateFiles(directory, "*.json"))
                if (File.GetLastWriteTimeUtc(path) < now.AddDays(-7).UtcDateTime) File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private static string Project(JsonElement payload)
    {
        var paths = Child(payload, "workspacePaths");
        if (paths.ValueKind != JsonValueKind.Array) return "";
        foreach (var entry in paths.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.String || entry.GetString() is not { } path) continue;
            var parts = path.TrimEnd('/', '\\').Split('/', '\\');
            if (parts[^1].Length > 0)
                return Regex.Replace(parts[^1][..Math.Min(48, parts[^1].Length)], @"\s+", " ");
        }
        return "";
    }

    private static void Enter(Mutex mutex)
    {
        try
        {
            if (!mutex.WaitOne(TimeSpan.FromSeconds(1))) throw new IOException("Hook 正在写入，请稍后重试。");
        }
        catch (AbandonedMutexException) { }
    }

    private static void WriteAtomic(string path, string data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temp, data);
            File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    private static JsonElement Child(JsonElement item, string name) =>
        item.ValueKind == JsonValueKind.Object && item.TryGetProperty(name, out var value) ? value : default;
    private static string? Text(JsonElement item, string name) =>
        Child(item, name) is { ValueKind: JsonValueKind.String } field ? field.GetString() : null;
}
