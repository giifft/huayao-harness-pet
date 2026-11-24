using System.Text.Json;
using HuaYaoPet;
using ZstdSharp;

var root = Path.Combine(Path.GetTempPath(), $"huayao-reader-{Guid.NewGuid()}");
var main = Path.Combine(root, "workspace", "main", "session.v4.jsonl.zstd");
var child = Path.Combine(root, "workspace", "child", "session.v4.jsonl.zstd");
var legacy = Path.Combine(root, "other", "main", "session.v3.jsonl.zstd");
var now = DateTimeOffset.UtcNow;
var baseMs = now.ToUnixTimeMilliseconds() - 1_000;
var events = new List<object>();
var reader = new HarnessReader(root);

void Add(string name, object? data = null) =>
    events.Add(new { type = name, seq = events.Count, time = baseMs + events.Count, data });

void Write(string path, int depth = 0, int newerBy = 0)
{
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var staged = path + ".tmp";
    using (var file = File.Create(staged))
    using (var compressed = new CompressionStream(file))
    using (var writer = new StreamWriter(compressed))
    {
        writer.WriteLine(JsonSerializer.Serialize(new { type = "session", delegationDepth = depth }));
        foreach (var row in events) writer.WriteLine(JsonSerializer.Serialize(row));
    }
    File.Move(staged, path, true);
    File.SetLastWriteTimeUtc(path, now.UtcDateTime.AddSeconds(newerBy));
}

void Check(PetPhase expected, string test, int later = 0, string? detail = null)
{
    var actual = reader.Refresh(now.AddSeconds(later));
    if (actual.Phase != expected || detail != null && actual.Detail != detail)
        throw new Exception($"{test}: expected {expected}, got {actual}");
    Console.WriteLine($"PASS {test}");
}

try
{
    Check(PetPhase.Offline, "No session");
    Write(main);
    Check(PetPhase.Idle, "New session header");
    Add("turn/start");
    Add("request/context", new { model = "test/deepseek-demo" });
    Write(main, newerBy: 1);
    Check(PetPhase.Thinking, "Atomic replacement", detail: "deepseek-demo");
    Add("tool/call", new { callId = "a", name = "read", arguments = "dummy secret" });
    Add("tool/call", new { callId = "b", name = "grep" });
    Add("tool/result", new { message = new { toolCallId = "b" } });
    Write(main, newerBy: 2);
    Check(PetPhase.Working, "Parallel tools, opaque arguments", detail: "在翻文件");
    Add("approval/asked", new { id = "ask" });
    Write(main, newerBy: 3);
    Check(PetPhase.Waiting, "Approval takes precedence");
    File.WriteAllText(main, "invalid frame");
    File.SetLastWriteTimeUtc(main, now.UtcDateTime.AddSeconds(4));
    Check(PetPhase.Waiting, "Partial replacement keeps prior status");
    using (var file = File.Create(main))
    using (var compressed = new CompressionStream(file))
    using (var writer = new StreamWriter(compressed))
        writer.WriteLine();
    File.SetLastWriteTimeUtc(main, now.UtcDateTime.AddSeconds(4.5));
    Check(PetPhase.Waiting, "Empty session keeps prior status");
    Add("approval/decided", new { id = "ask" });
    Add("turn/end", new { reason = new { kind = "completed" } });
    Write(main, newerBy: 5);
    Check(PetPhase.Done, "Completion");
    Check(PetPhase.Idle, "Completion expires", later: 20);
    if (new HarnessReader(root).Refresh(now).Phase != PetPhase.Idle) throw new Exception("Completion replayed on launch");
    Add("turn/start");
    Add("turn/end", new { reason = new { kind = "aborted" } });
    Write(main, newerBy: 6);
    Check(PetPhase.Cancelled, "Aborted turn");
    events.Clear();
    Add("turn/start");
    Write(child, depth: 1, newerBy: 7);
    Check(PetPhase.Cancelled, "Child session skipped");
    Write(legacy, newerBy: 8);
    Check(PetPhase.Thinking, "New active v3 session");
    Check(PetPhase.Idle, "Stale work expires", later: 95);
    if (args.Length == 1 && new HarnessReader(args[0]).Refresh(DateTimeOffset.UtcNow).Phase == PetPhase.Offline)
        throw new Exception("The installed Harness session could not be read.");
}
finally
{
    if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
}
