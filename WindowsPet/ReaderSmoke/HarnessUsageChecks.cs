using System.Globalization;
using System.Text.Json;
using HuaYaoPet;
using ZstdSharp;

internal static class HarnessUsageChecks
{
    internal static void Run()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "HarnessUsage.json")));
        var source = fixture.RootElement;
        var now = DateTimeOffset.Parse(source.GetProperty("now").GetString()!, CultureInfo.InvariantCulture);
        var root = Path.Combine(Path.GetTempPath(), $"huayao-usage-{Guid.NewGuid()}");
        try
        {
            var main = Write(root, "workspace/main", source.GetProperty("main"), now);
            Write(root, "workspace/branch", source.GetProperty("child"), now.AddSeconds(1));
            Write(root, "backup/main", source.GetProperty("main"), now.AddSeconds(-1));

            var reader = new HarnessReader(root);
            AssertUsage(reader.Refresh(now), now);
            AssertUsage(reader.Refresh(now.AddSeconds(1)), now);
            AssertUsage(new HarnessReader(root).Refresh(now), now);

            File.WriteAllText(main, "incomplete frame");
            File.SetLastWriteTimeUtc(main, now.UtcDateTime.AddSeconds(3));
            AssertUsage(reader.Refresh(now.AddSeconds(3)), now, pending: true);
            Write(root, "workspace/main", source.GetProperty("main"), now.AddSeconds(4));
            AssertUsage(reader.Refresh(now.AddSeconds(4)), now);

            var weekend = new HarnessReader(root).Refresh(DateTimeOffset.Parse("2026-11-28T10:00:00+08:00"));
            Check(weekend.Usage?.PricingPeriod == HarnessPricingPeriod.OffPeak
                && weekend.Usage?.NextPricingChange == DateTimeOffset.Parse("2026-11-30T09:00:00+08:00"), "weekend countdown");
            var holiday = new HarnessReader(root).Refresh(DateTimeOffset.Parse("2027-06-09T10:00:00+08:00"));
            Check(holiday.Usage?.PricingPeriod == HarnessPricingPeriod.OffPeak
                && holiday.Usage?.NextPricingChange == DateTimeOffset.Parse("2027-06-10T09:00:00+08:00"), "2027 holiday countdown");
            Console.WriteLine("PASS Harness usage, duplicate and delegated sessions, restart, partial file, question, and peak calendar");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static string Write(string root, string session, JsonElement events, DateTimeOffset modifiedAt)
    {
        var path = Path.Combine(root, session, "session.v4.jsonl.zstd");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using (var file = File.Create(path))
        using (var compressed = new CompressionStream(file))
        using (var writer = new StreamWriter(compressed))
            foreach (var row in events.EnumerateArray()) writer.WriteLine(row.GetRawText());
        File.SetLastWriteTimeUtc(path, modifiedAt.UtcDateTime);
        return path;
    }

    private static void AssertUsage(PetStatus status, DateTimeOffset now, bool pending = false)
    {
        var usage = status.Usage ?? throw new Exception("Missing usage.");
        Check(status.Phase == PetPhase.Waiting && status.WaitKind == HarnessWaitKind.Question, "question phase");
        Check(status.SessionId == "main" && status.SessionTitle == "测试任务" && status.ProjectName == "花妖", "session identity");
        Check(usage.TodayRoundCount == 3 && usage.TodayTokens == 4571 && usage.TodayUnpricedRoundCount == 1, "today round and token totals");
        Check(usage.TodayKnownCost == 0.01041m, $"known cost {usage.TodayKnownCost}");
        Check(usage.LatestRound is { Id: "main:3", EstimatedCost: null, Tokens: 61 }, "unknown latest round");
        Check(usage.History.Count == 2 && usage.History[1].KnownCost == 0.00068m, "Beijing history boundary");
        Check(usage.PricingPeriod == HarnessPricingPeriod.Peak
            && usage.NextPricingChange == new DateTimeOffset(now.Date.AddHours(12), now.Offset), "peak countdown");
        Check(usage.ScanPending == pending, "scan pending state");
    }

    private static void Check(bool valid, string label)
    {
        if (!valid) throw new Exception($"Usage check failed: {label}");
    }
}
