using System.Globalization;
using System.Text.Json;

namespace HuaYaoPet;

public enum HarnessWaitKind { Question, Approval }
public enum HarnessPricingPeriod { Peak, OffPeak, Unknown }

public sealed record HarnessUsageRound(
    string Id, DateTimeOffset CompletedAt, IReadOnlyList<string> Models,
    long Tokens, decimal? EstimatedCost, decimal KnownCost)
{
    internal IReadOnlyDictionary<string, HarnessUsageSlice> UsageByDay { get; init; } = new Dictionary<string, HarnessUsageSlice>();
}

internal readonly record struct HarnessUsageSlice(long Tokens, decimal KnownCost, bool Unpriced)
{
    internal HarnessUsageSlice Add(long tokens, decimal? cost) =>
        new(Tokens + tokens, KnownCost + (cost ?? 0), Unpriced || cost is null);
}

public sealed record HarnessUsageDay(string Day, long Tokens = 0, int RoundCount = 0, decimal KnownCost = 0, int UnpricedRoundCount = 0)
{
    internal HarnessUsageDay Add(HarnessUsageSlice slice) => this with
    {
        Tokens = Tokens + slice.Tokens,
        KnownCost = KnownCost + slice.KnownCost,
        UnpricedRoundCount = UnpricedRoundCount + (slice.Unpriced ? 1 : 0)
    };
}

public sealed record HarnessUsageSummary(
    string Day, long TodayTokens, int TodayRoundCount, decimal TodayKnownCost, int TodayUnpricedRoundCount,
    HarnessUsageRound? LatestRound, HarnessPricingPeriod PricingPeriod, DateTimeOffset? NextPricingChange,
    IReadOnlyList<HarnessUsageDay> History, IReadOnlyList<HarnessUsageRound> RecentRounds, bool ScanPending)
{
    internal static HarnessUsageSummary Make(IEnumerable<HarnessUsageRound> rounds, DateTimeOffset now, HarnessPricing? pricing, bool pending)
    {
        var days = new Dictionary<string, HarnessUsageDay>(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var recent = new List<HarnessUsageRound>();
        foreach (var round in rounds)
        {
            if (round.CompletedAt > now || !seen.Add(round.Id)) continue;
            var day = HarnessPricing.Day(round.CompletedAt);
            var completed = days.GetValueOrDefault(day) ?? new HarnessUsageDay(day);
            days[day] = completed with { RoundCount = completed.RoundCount + 1 };
            foreach (var (usageDay, slice) in round.UsageByDay)
                days[usageDay] = (days.GetValueOrDefault(usageDay) ?? new HarnessUsageDay(usageDay)).Add(slice);
            recent.Add(round);
        }
        var recentRounds = recent.OrderByDescending(round => round.CompletedAt)
            .ThenByDescending(round => round.Id, StringComparer.Ordinal).Take(30).ToArray();
        var today = HarnessPricing.Day(now);
        var row = days.GetValueOrDefault(today) ?? new HarnessUsageDay(today);
        return new HarnessUsageSummary(today, row.Tokens, row.RoundCount, row.KnownCost, row.UnpricedRoundCount,
            recentRounds.FirstOrDefault(), pricing?.Period(now) ?? HarnessPricingPeriod.Unknown, pricing?.NextChange(now),
            days.Values.OrderByDescending(value => value.Day, StringComparer.Ordinal).ToArray(), recentRounds, pending);
    }
}

internal sealed class HarnessPricing
{
    private sealed record Tariff(DateTimeOffset From, string[] Models, decimal[] OffPeak, decimal[] Peak);
    private sealed record Document(string CalendarThrough, string WeekendOffPeakFrom, string HolidayOffPeakFrom,
        int[][] PeakHours, string[][] HolidayRanges, string[] Providers, Tariff[] Tariffs);

    private static readonly TimeSpan Beijing = TimeSpan.FromHours(8);

    internal static HarnessPricing? Bundled { get; } = LoadBundled();

    private static HarnessPricing? LoadBundled()
    {
        using var stream = typeof(HarnessPricing).Assembly.GetManifestResourceStream("HuaYaoPet.HarnessPricing.json");
        if (stream is null) return null;
        try
        {
            var document = JsonSerializer.Deserialize<Document>(stream, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });
            return document is null ? null : new HarnessPricing(document);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private readonly Document rules;
    private readonly int[] transitions;

    private HarnessPricing(Document rules)
    {
        this.rules = rules;
        transitions = rules.PeakHours.SelectMany(range => range).Distinct().Order().ToArray();
    }

    internal static string Day(DateTimeOffset time) => time.ToOffset(Beijing).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    internal HarnessPricingPeriod Period(DateTimeOffset time)
    {
        var local = time.ToOffset(Beijing);
        var day = Day(time);
        if (Compare(day, "2026-08-17") < 0 || Compare(day, rules.CalendarThrough) > 0)
            return HarnessPricingPeriod.Unknown;
        if (Compare(day, rules.WeekendOffPeakFrom) >= 0 && local.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday)
            return HarnessPricingPeriod.OffPeak;
        if (Compare(day, rules.HolidayOffPeakFrom) >= 0 && rules.HolidayRanges.Any(range =>
            range.Length == 2 && Compare(day, range[0]) >= 0 && Compare(day, range[1]) <= 0))
            return HarnessPricingPeriod.OffPeak;
        return rules.PeakHours.Any(range => range.Length == 2 && local.Hour >= range[0] && local.Hour < range[1])
            ? HarnessPricingPeriod.Peak : HarnessPricingPeriod.OffPeak;
    }

    internal DateTimeOffset? NextChange(DateTimeOffset time)
    {
        var current = Period(time);
        if (current == HarnessPricingPeriod.Unknown) return null;
        var start = new DateTimeOffset(time.ToOffset(Beijing).Date, Beijing);
        for (var day = 0; day <= 14; day++)
        {
            foreach (var hour in transitions)
            {
                var candidate = start.AddDays(day).AddHours(hour);
                if (candidate <= time) continue;
                var period = Period(candidate);
                if (period == HarnessPricingPeriod.Unknown) return null;
                if (period != current) return candidate;
            }
        }
        return null;
    }

    internal decimal? Cost(string model, string provider, DateTimeOffset time, long cached, long input, long output)
    {
        if (!rules.Providers.Contains(provider, StringComparer.OrdinalIgnoreCase)) return null;
        var name = model.Split('/').Last();
        var tariff = rules.Tariffs.LastOrDefault(item => time >= item.From && item.Models.Contains(name, StringComparer.OrdinalIgnoreCase));
        if (tariff is null) return null;
        var period = Period(time);
        if (period == HarnessPricingPeriod.Unknown) return null;
        var rates = period == HarnessPricingPeriod.Peak ? tariff.Peak : tariff.OffPeak;
        return rates.Length == 3 ? (cached * rates[0] + input * rates[1] + output * rates[2]) / 1_000_000 : null;
    }

    private static int Compare(string left, string right) => string.CompareOrdinal(left, right);
}

/// <summary>Folds only token and model metadata. Message bodies and tool arguments never enter the ledger.</summary>
internal sealed class HarnessUsageFold(string sessionId, HarnessPricing? pricing)
{
    private sealed class Turn
    {
        public readonly HashSet<string> MessageIds = new(StringComparer.Ordinal);
        public readonly SortedSet<string> Models = new(StringComparer.Ordinal);
        public readonly Dictionary<string, HarnessUsageSlice> UsageByDay = new(StringComparer.Ordinal);
    }

    private readonly Dictionary<long, Turn> turns = [];
    private readonly List<HarnessUsageRound> rounds = [];
    internal IReadOnlyList<HarnessUsageRound> Rounds => rounds;

    internal void Accept(string type, JsonElement data, long sequence, long milliseconds)
    {
        var turnId = Number(data, "turn");
        if (turnId is null or < 0 || milliseconds is < 0 or > 253402271999000) return;
        var time = DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
        if (type == "turn/end")
        {
            if (!turns.Remove(turnId.Value, out var finished) || finished.MessageIds.Count == 0) return;
            var slices = finished.UsageByDay.Values;
            var knownCost = slices.Sum(slice => slice.KnownCost);
            rounds.Add(new HarnessUsageRound(FormattableString.Invariant($"{sessionId}:{turnId.Value}"), time,
                finished.Models.ToArray(), slices.Sum(slice => slice.Tokens),
                slices.Any(slice => slice.Unpriced) ? null : knownCost, knownCost)
                { UsageByDay = finished.UsageByDay });
            return;
        }
        if (type != "assistant/message") return;
        var usage = Child(data, "usage");
        var message = Child(data, "message");
        if (usage.ValueKind != JsonValueKind.Object || message.ValueKind != JsonValueKind.Object) return;

        var input = Counter(usage, "inputTokens", required: true);
        var output = Counter(usage, "outputTokens", required: true);
        var cached = Counter(usage, "cacheReadTokens");
        var cacheWrite = Counter(usage, "cacheWriteTokens");
        var reasoning = Counter(usage, "reasoningTokens");
        if (input is null || output is null || cached is null || cacheWrite is null || reasoning is null || reasoning > output)
            return;

        var source = Child(message, "source");
        var model = Text(source, "model");
        var provider = Text(source, "provider") ?? "";
        model = string.IsNullOrEmpty(model) ? "未知" : model[..Math.Min(model.Length, 128)];
        var messageId = Text(message, "id");
        var marker = string.IsNullOrEmpty(messageId) ? FormattableString.Invariant($"seq:{sequence}") : $"id:{messageId}";
        if (!turns.TryGetValue(turnId.Value, out var turn)) turns.Add(turnId.Value, turn = new Turn());
        if (!turn.MessageIds.Add(marker)) return;
        turn.Models.Add(model);

        // Harness excludes cache reads and writes from input and includes reasoning in output.
        var cost = pricing?.Cost(model, provider, time, cached.Value, input.Value + cacheWrite.Value, output.Value);
        var day = HarnessPricing.Day(time);
        turn.UsageByDay[day] = turn.UsageByDay.GetValueOrDefault(day).Add(
            input.Value + cached.Value + cacheWrite.Value + output.Value, cost);
    }

    private static long? Counter(JsonElement parent, string key, bool required = false)
    {
        var item = Child(parent, key);
        if (item.ValueKind == JsonValueKind.Undefined) return required ? null : 0;
        var number = Number(parent, key);
        return number is >= 0 and <= 1_000_000_000 ? number : null;
    }

    private static JsonElement Child(JsonElement item, string key) =>
        item.ValueKind == JsonValueKind.Object && item.TryGetProperty(key, out var value) ? value : default;
    private static string? Text(JsonElement item, string key) =>
        Child(item, key) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;
    private static long? Number(JsonElement item, string key) =>
        Child(item, key) is { ValueKind: JsonValueKind.Number } value && value.TryGetInt64(out var number) ? number : null;
}
