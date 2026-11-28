using System.Text.Json;
using System.Text.Json.Nodes;
using HuaYaoPet;

internal static class CompanionHookChecks
{
    internal static void Run(string root, DateTimeOffset now)
    {
        var profile = Path.Combine(root, "hook-profile");
        var storage = Path.Combine(root, "hook-data");
        var hooks = new CompanionHooks(profile, storage);
        var executable = Path.Combine(root, "App With Spaces", "HuaYaoPet.exe");
        var traeConfig = Path.Combine(profile, ".trae-cn", "hooks.json");
        var antigravityConfig = Path.Combine(profile, ".gemini", "config", "hooks.json");
        const string existingTrae = """
            {"version":1,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-existing-hook"}]}]}}
            """;
        const string existingAntigravity = """{"my-hooks":{"enabled":true}}""";
        Directory.CreateDirectory(Path.GetDirectoryName(traeConfig)!);
        Directory.CreateDirectory(Path.GetDirectoryName(antigravityConfig)!);
        File.WriteAllText(traeConfig, existingTrae);
        File.WriteAllText(antigravityConfig, existingAntigravity);
        foreach (var platform in new[] { "TRAE", "Antigravity" })
        {
            var config = platform == "TRAE" ? traeConfig : antigravityConfig;
            var original = JsonNode.Parse(File.ReadAllText(config));
            hooks.Install(platform, executable);
            var installed = JsonNode.Parse(File.ReadAllText(config));
            Check(!JsonNode.DeepEquals(installed, original), $"install {platform}");
            hooks.Install(platform, executable);
            Check(JsonNode.DeepEquals(installed, JsonNode.Parse(File.ReadAllText(config))), $"reinstall {platform}");
            hooks.Uninstall(platform);
            hooks.Uninstall(platform);
            Check(JsonNode.DeepEquals(original, JsonNode.Parse(File.ReadAllText(config))), $"uninstall {platform} preserves existing hooks");
        }

        const string question = """{"session_id":"synthetic-trae","notification_type":"ask_user_question","prompt":"fixture-only text"}""";
        hooks.Observe("TRAE", "Notification", question, now);
        var task = hooks.Read("TRAE", now).Single();
        Check(task.Status is { Phase: PetPhase.Waiting, WaitKind: HarnessWaitKind.Question }, "TRAE question");
        var signals = Path.Combine(storage, "TaskSignals", "TRAE");
        Check(!File.ReadAllText(Directory.GetFiles(signals).Single()).Contains("fixture-only text"), "omit prompt");
        File.WriteAllText(Path.Combine(signals, "incomplete.json"),
            JsonSerializer.Serialize(new { Phase = PetPhase.Working, Activity = now.ToUnixTimeMilliseconds() }));
        Check(hooks.Read("TRAE", now).Count == 1, "skip incomplete persisted hook signal");
        hooks.Observe("TRAE", "Stop", question, now.AddSeconds(-1));
        Check(hooks.Read("TRAE", now).Single().Status.Phase == PetPhase.Waiting, "ignore late event");

        const string first = """{"conversationId":"d3282ead-d17e-4fb7-a376-e77fa542a0a4","workspacePaths":["P:\\work\\first"],"terminationReason":"model_stop"}""";
        const string second = """{"conversationId":"c45e7858-9416-4fb1-9fbd-f39ad0148605","workspacePaths":["P:\\work\\second"]}""";
        hooks.Observe("Antigravity", "PreInvocation", first, now);
        hooks.Observe("Antigravity", "PreToolUse", second, now);
        hooks.Observe("Antigravity", "Stop", first, now.AddSeconds(1));
        var tasks = hooks.Read("Antigravity", now.AddSeconds(2)).ToDictionary(item => item.Name);
        Check(tasks.Count == 2 && tasks["first"].Status.Phase == PetPhase.Done && tasks["second"].Status.Phase == PetPhase.Working,
            "independent Antigravity sessions");
        Console.WriteLine("PASS TRAE and Antigravity hook configuration, metadata, concurrency and incomplete signals");
    }

    private static void Check(bool valid, string label)
    {
        if (!valid) throw new Exception($"Companion hook check failed: {label}");
    }
}
