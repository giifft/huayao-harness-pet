using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace HuaYaoPet;

internal sealed class PetBilling : IDisposable
{
    private sealed record BalanceDay(decimal Opening, DateTimeOffset First, decimal Closing, DateTimeOffset Last,
        decimal Decrease = 0, decimal Increase = 0, decimal? PostedCredits = null, decimal? OtherDebits = null,
        decimal? CorrectedAmount = null, decimal? DecreaseAtCorrection = null)
    {
        public decimal Observed => CorrectedAmount is decimal amount && DecreaseAtCorrection is decimal decrease
            ? amount + Decrease - decrease : Decrease;
        public bool NeedsReview => Increase > (PostedCredits ?? 0);
        public bool StartedLate => First.ToOffset(TimeSpan.FromHours(8)).TimeOfDay > TimeSpan.FromMinutes(10);
    }

    private sealed record BillingFile(decimal Low = 5, decimal Budget = 10,
        Dictionary<string, Dictionary<string, BalanceDay>>? Books = null);
    private sealed record BalanceWallet(string currency, string total_balance);
    private sealed record BalanceResponse(BalanceWallet[] balance_infos);

    private static readonly string DataFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HuaYaoPet", "balance-history.json");
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
    private readonly HttpClient client = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
    {
        Timeout = TimeSpan.FromSeconds(12)
    };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(60) };
    private readonly DateTimeOffset started = DateTimeOffset.UtcNow;
    private Dictionary<string, Dictionary<string, BalanceDay>> books = new();
    private decimal lowLimit = 5;
    private decimal budget = 10;
    private string? key;
    private string? account;
    private string? wallet;
    private readonly HashSet<string> announcedRounds = new(StringComparer.Ordinal);
    private string? warnedDay;
    private DateTimeOffset lastAttempt;
    private CancellationTokenSource? request;
    private HarnessUsageSummary? usage;
    private string status = "";
    private Window? panel;
    private TextBlock? overview;
    private TextBox? history;
    private bool disposed;

    public Action<string, string>? RoundCompleted { get; set; }
    public Action<bool, string>? BalanceWarning { get; set; }
    public Action<string>? BudgetWarning { get; set; }

    public void Initialize()
    {
        key = BillingCredential.Read();
        try
        {
            var file = JsonSerializer.Deserialize<BillingFile>(File.ReadAllText(DataFile));
            books = file?.Books ?? new();
            lowLimit = file?.Low ?? 5;
            budget = file?.Budget ?? 10;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }

        timer.Tick += (_, _) => Refresh();
        timer.Start();
        Refresh();
    }

    public void Observe(HarnessUsageSummary? summary)
    {
        if (summary is null) return;
        usage = summary;
        if (summary.LatestRound is { } round && round.CompletedAt >= started && announcedRounds.Add(round.Id))
        {
            RoundCompleted?.Invoke(round.EstimatedCost is decimal cost ? $"约 ¥{Format(cost)}" : "缺少适用单价",
                string.Join("、", round.Models));
        }
        CheckBudget();
        Render();
    }

    public void RefreshFromPet()
    {
        if (DateTimeOffset.UtcNow - lastAttempt >= TimeSpan.FromSeconds(5)) Refresh();
    }

    private async void Refresh()
    {
        if (disposed || key is null || request != null) { Render(); return; }
        var credential = key;
        using var operation = new CancellationTokenSource();
        request = operation;
        lastAttempt = DateTimeOffset.UtcNow;
        status = "正在查询 DeepSeek 余额…";
        Render();
        try
        {
            using var query = new HttpRequestMessage(HttpMethod.Get, "https://api.deepseek.com/user/balance");
            query.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential);
            using var response = await client.SendAsync(query, operation.Token);
            if (disposed || operation.IsCancellationRequested) return;
            if (!response.IsSuccessStatusCode)
            {
                status = "余额查询失败，请检查 API 密钥与账户状态。";
                return;
            }
            var bytes = await response.Content.ReadAsByteArrayAsync(operation.Token);
            var valid = JsonSerializer.Deserialize<BalanceResponse>(bytes)?.balance_infos?
                .Where(wallet => wallet.currency is "CNY" or "USD").ToArray() ?? [];
            var item = valid.FirstOrDefault(wallet => wallet.currency == "CNY") ?? valid.FirstOrDefault();
            if (item is null || !TryAmount(item.total_balance, out var amount))
            {
                status = "DeepSeek 暂未返回可用余额。";
                return;
            }
            wallet = item.currency;
            var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(credential))).ToLowerInvariant();
            account = $"{hash}-{wallet}";
            Record(amount, DateTimeOffset.UtcNow);
            BalanceWarning?.Invoke(lowLimit > 0 && amount < lowLimit, Money(amount, wallet));
            CheckBudget();
            status = $"余额已更新 · {DateTime.Now:t}";
        }
        catch (Exception error) when (error is HttpRequestException or JsonException or OperationCanceledException or FormatException)
        {
            if (!disposed && !operation.IsCancellationRequested) status = "余额查询失败，请稍后重试。";
        }
        finally
        {
            if (ReferenceEquals(request, operation))
            {
                request = null;
                if (!disposed) Render();
            }
        }
    }

    private void Record(decimal amount, DateTimeOffset timestamp)
    {
        if (account is null) return;
        if (!books.TryGetValue(account, out var book)) books[account] = book = new();
        var day = Day(timestamp);
        if (!book.TryGetValue(day, out var row)) row = new(amount, timestamp, amount, timestamp);
        if (timestamp < row.Last) return;
        var delta = row.Closing - amount;
        book[day] = row with
        {
            Closing = amount, Last = timestamp,
            Decrease = row.Decrease + Math.Max(0, delta),
            Increase = row.Increase + Math.Max(0, -delta)
        };
        Save();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(DataFile)!);
            var temp = DataFile + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(new BillingFile(lowLimit, budget, books)));
            File.Move(temp, DataFile, true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private void CheckBudget()
    {
        if (budget <= 0) return;
        var day = Day(DateTimeOffset.UtcNow);
        var observed = wallet == "CNY" && account != null && books[account].TryGetValue(day, out var row) ? row.Observed : (decimal?)null;
        decimal? estimate = usage?.Day == day ? usage.TodayKnownCost : null;
        if (warnedDay == day || (observed ?? estimate) is not decimal spend || spend < budget) return;
        warnedDay = day;
        BudgetWarning?.Invoke(Money(spend, "CNY"));
    }

    public void Open(Window owner)
    {
        if (panel is null)
        {
            overview = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) };
            var buttons = new WrapPanel { Margin = new Thickness(0, 0, 0, 12) };
            buttons.Children.Add(Button("刷新", RefreshFromPet));
            buttons.Children.Add(Button("API 密钥…", ConfigureCredential));
            buttons.Children.Add(Button("提醒设置…", ConfigureLimits));
            buttons.Children.Add(Button("余额校正…", Reconcile));
            buttons.Children.Add(Button("DeepSeek 用量", () =>
                Process.Start(new ProcessStartInfo("https://platform.deepseek.com/usage") { UseShellExecute = true })));
            buttons.Children.Add(Button("复制账本", CopyLedger));
            history = new TextBox
            {
                IsReadOnly = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto
            };
            var content = new DockPanel { Margin = new Thickness(17) };
            DockPanel.SetDock(overview, Dock.Top);
            DockPanel.SetDock(buttons, Dock.Top);
            content.Children.Add(overview);
            content.Children.Add(buttons);
            content.Children.Add(history);
            panel = new Window
            {
                Title = "花妖 · 用量与余额", Content = content, Width = 570, Height = 410, MinWidth = 540, MinHeight = 330,
                Owner = owner, WindowStartupLocation = WindowStartupLocation.CenterScreen
            };
            panel.Closed += (_, _) => { panel = null; overview = null; history = null; };
            panel.Show();
        }
        panel.Activate();
        Render();
        RefreshFromPet();
    }

    private void CopyLedger()
    {
        if (history is null) return;
        try
        {
            System.Windows.Clipboard.SetText(history.Text);
            status = "已复制账本。";
        }
        catch (ExternalException) { status = "剪贴板暂不可用，请重试。"; }
        Render();
    }

    private void ConfigureCredential()
    {
        var input = new PasswordBox();
        var body = DialogBody("API 密钥存入本机凭据管理器，查询时仅发往 api.deepseek.com。照常使用 Harness 不需要填写密钥。");
        AddField(body, "DeepSeek API 密钥", input);
        var choice = ShowDialog("DeepSeek 余额查询", body, "保存并查询", "移除密钥");
        if (choice is null) return;
        var replacement = choice.Value ? input.Password.Trim() : null;
        if (choice.Value && (replacement is null || !Regex.IsMatch(replacement, @"\A[A-Za-z0-9._-]{1,256}\z")))
        { status = "请输入有效的 DeepSeek API 密钥。"; Render(); return; }
        if (!BillingCredential.Write(replacement)) { status = "无法更新凭据管理器。"; Render(); return; }
        request?.Cancel();
        request = null;
        key = replacement;
        account = null;
        wallet = null;
        status = "";
        BalanceWarning?.Invoke(false, "");
        Refresh();
    }

    private void ConfigureLimits()
    {
        var body = DialogBody("余额预警使用账户币种；每日预算使用 CNY。填 0 可关闭相应提醒。");
        var low = new TextBox { Text = Format(lowLimit) };
        var daily = new TextBox { Text = Format(budget) };
        AddField(body, "低余额预警", low);
        AddField(body, "每日预算（CNY）", daily);
        if (ShowDialog("余额预警与每日预算", body, "保存") != true) return;
        if (!TryAmount(low.Text, out var lowValue) || !TryAmount(daily.Text, out var dailyValue))
        { status = "请输入有效的非负金额。"; Render(); return; }
        lowLimit = lowValue;
        budget = dailyValue;
        warnedDay = null;
        Save();
        CheckBudget();
        Refresh();
    }

    private void Reconcile()
    {
        if (account is null || wallet is null) { status = "连接账户后可校正观测账本。"; Render(); return; }
        var book = books[account];
        var body = DialogBody("校正后消费＝期初余额－当前余额＋到账－其他扣减。请填写该观测区间内发生的金额。");
        var day = new ComboBox { ItemsSource = book.Keys.OrderDescending().ToArray(), SelectedIndex = 0 };
        var credits = new TextBox { Text = "0" };
        var debits = new TextBox { Text = "0" };
        AddField(body, "观测日期（北京时间）", day);
        AddField(body, "到账金额", credits);
        AddField(body, "其他扣减", debits);
        if (ShowDialog("校正观测账本", body, "保存校正") != true) return;
        if (day.SelectedItem is not string date || !book.TryGetValue(date, out var row) ||
            !TryAmount(credits.Text, out var credit) || !TryAmount(debits.Text, out var debit) ||
            row.Opening - row.Closing + credit - debit < 0)
        { status = "该日没有余额观测，或金额无法对账。"; Render(); return; }
        if (account is null || !ReferenceEquals(books[account], book)) return;
        row = row with
        {
            PostedCredits = credit, OtherDebits = debit, CorrectedAmount = row.Opening - row.Closing + credit - debit,
            DecreaseAtCorrection = row.Decrease
        };
        book[date] = row;
        Save();
        status = $"{date} 已校正为 {Money(row.Observed, wallet)}。";
        CheckBudget();
        Render();
    }

    private static StackPanel DialogBody(string help)
    {
        var body = new StackPanel { Margin = new Thickness(18), Width = 390 };
        body.Children.Add(new TextBlock { Text = help, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) });
        return body;
    }

    private static void AddField(Panel body, string label, Control control)
    {
        body.Children.Add(new Label { Content = label, Target = control });
        body.Children.Add(control);
    }

    private bool? ShowDialog(string title, StackPanel body, string confirm, string? alternate = null)
    {
        bool? choice = null;
        var dialog = new Window
        {
            Title = title, Owner = panel, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize, Content = body
        };
        var buttons = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        var accept = Button(confirm, () => { choice = true; dialog.Close(); });
        accept.IsDefault = true;
        buttons.Children.Add(accept);
        var cancel = Button("取消", () => dialog.Close());
        cancel.IsCancel = true;
        buttons.Children.Add(cancel);
        if (alternate != null) buttons.Children.Add(Button(alternate, () => { choice = false; dialog.Close(); }));
        body.Children.Add(buttons);
        dialog.ShowDialog();
        return choice;
    }

    private void Render()
    {
        if (overview is null || history is null) return;
        var day = Day(DateTimeOffset.UtcNow);
        var book = account != null ? books[account] : null;
        var row = book?.GetValueOrDefault(day);
        var currency = wallet ?? "CNY";
        var balance = row is null ? "—" : Money(row.Closing, currency);
        var observed = row is null ? "—" : Money(row.Observed, currency) +
            (row.NeedsReview ? "（待核对）" : row.StartedLate ? "（部分时段）" : "");
        var lines = new List<string> { $"DeepSeek 余额  {balance}　今日已观测消费  {observed}" };
        if (usage is not null)
        {
            lines.Add($"今日 Harness 已观测 {usage.TodayRoundCount} 轮 · {usage.TodayTokens} tokens · 已有单价约 ¥{Format(usage.TodayKnownCost)}");
            if (usage.TodayUnpricedRoundCount > 0) lines.Add($"{usage.TodayUnpricedRoundCount} 轮包含尚无适用单价的用量。");
            if (usage.LatestRound is { } round)
            {
                var cost = round.EstimatedCost is decimal price ? $"约 ¥{Format(price)}" : "缺少适用单价";
                lines.Add($"最近一轮  {cost} · {round.Tokens} tokens · {string.Join("、", round.Models)}");
            }
            var countdown = usage.NextPricingChange is DateTimeOffset next
                ? $" · 约 {Math.Max(0, (int)(next - DateTimeOffset.UtcNow).TotalMinutes)} 分钟后切换" : "";
            var period = usage.PricingPeriod.ToString() switch { "Peak" => "高峰时段", "OffPeak" => "空闲时段", _ => "时段待核实" };
            lines.Add($"DeepSeek {period}{countdown}（北京时间）");
            if (usage.ScanPending) lines.Add("尚有会话待汇总。");
        }
        else lines.Add("今日 Harness 用量  —");
        lines.Add(string.IsNullOrEmpty(status) ? (key is null ? "添加密钥后每 60 秒刷新；点击立绘可手动查询。" : "等待余额查询。") : status);
        overview.Text = string.Join(Environment.NewLine, lines);
        var rows = new List<string> { "DeepSeek 余额观测（北京时间）" };
        if (books.Count == 0) rows.Add("连接 DeepSeek 后显示余额观测账本。");
        foreach (var entry in books.OrderBy(item => item.Key == account ? "" : item.Key, StringComparer.Ordinal))
        {
            if (entry.Key.Length < 8) continue;
            var bookCurrency = entry.Key[^3..];
            rows.Add(entry.Key == account ? $"当前账户 · {bookCurrency}" : $"历史账户 · {entry.Key[..8]} · {bookCurrency}");
            rows.AddRange(entry.Value.OrderByDescending(item => item.Key).Select(item =>
            {
                var tag = item.Value.NeedsReview ? "待核对" : item.Value.PostedCredits.HasValue ? "已校正" : "余额观测";
                return $"{item.Key}  {Money(item.Value.Observed, bookCurrency)}  {tag}  {item.Value.First.ToOffset(TimeSpan.FromHours(8)):HH:mm}–{item.Value.Last.ToOffset(TimeSpan.FromHours(8)):HH:mm}";
            }));
        }
        if (usage is not null && usage.History.Any())
        {
            rows.Add("");
            rows.Add("Harness 本地用量估算");
            rows.AddRange(usage.History.Select(item =>
                $"{item.Day}  {item.RoundCount} 轮  {item.Tokens} tokens  约 ¥{Format(item.KnownCost)}" +
                (item.UnpricedRoundCount == 0 ? "" : $"  · {item.UnpricedRoundCount} 轮单价未知")));
            rows.Add("");
            rows.Add("最近各轮");
            rows.AddRange(usage.RecentRounds.Select(round =>
                $"{round.CompletedAt.ToOffset(TimeSpan.FromHours(8)):yyyy-MM-dd HH:mm}  {round.Tokens} tokens  " +
                (round.EstimatedCost is decimal cost ? $"约 ¥{Format(cost)}" : "单价未知") +
                $"  {string.Join("、", round.Models)}"));
        }
        history.Text = string.Join(Environment.NewLine, rows);
    }

    private static Button Button(string label, Action action)
    {
        var button = new Button { Content = label, Margin = new Thickness(0, 0, 6, 3), Padding = new Thickness(8, 4, 8, 4) };
        button.Click += (_, _) => action();
        return button;
    }

    private static bool TryAmount(string value, out decimal amount) =>
        decimal.TryParse(value.Trim(), NumberStyles.AllowDecimalPoint, Invariant, out amount) && amount is >= 0 and <= 1_000_000_000 &&
        Regex.IsMatch(value.Trim(), @"\A\d+(?:\.\d{1,8})?\z");
    private static string Format(decimal amount) => amount.ToString("0.########", Invariant);
    private static string Money(decimal amount, string currency) => (currency == "CNY" ? "¥" : "USD ") + Format(amount);
    private static string Day(DateTimeOffset date) => date.ToOffset(TimeSpan.FromHours(8)).ToString("yyyy-MM-dd", Invariant);

    public void Dispose()
    {
        disposed = true;
        timer.Stop();
        request?.Cancel();
        client.Dispose();
        panel?.Close();
    }
}

internal static class BillingCredential
{
    private const string Target = "HuaYaoPet.DeepSeekBalance";
    private const uint Generic = 1;
    private const int NotFound = 1168;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags, Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias, UserName;
    }

    [DllImport("advapi32", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadNative(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteNative(ref Credential credential, uint flags);

    [DllImport("advapi32", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteNative(string target, uint type, uint flags);

    [DllImport("advapi32", EntryPoint = "CredFree")]
    private static extern void FreeNative(IntPtr credential);

    internal static string? Read()
    {
        if (!ReadNative(Target, Generic, 0, out var pointer)) return null;
        try
        {
            var item = Marshal.PtrToStructure<Credential>(pointer);
            return item.CredentialBlobSize is > 0 and <= 2560
                ? Marshal.PtrToStringUni(item.CredentialBlob, (int)item.CredentialBlobSize / sizeof(char)) : null;
        }
        finally { FreeNative(pointer); }
    }

    internal static bool Write(string? key)
    {
        if (key is null) return DeleteNative(Target, Generic, 0) || Marshal.GetLastPInvokeError() == NotFound;
        if (key.Length > 1280) return false;
        var pointer = Marshal.StringToCoTaskMemUni(key);
        try
        {
            var item = new Credential
            {
                Type = Generic, TargetName = Target, CredentialBlobSize = (uint)(key.Length * sizeof(char)),
                CredentialBlob = pointer, Persist = 2, UserName = "DeepSeek API"
            };
            return WriteNative(ref item, 0);
        }
        finally { Marshal.ZeroFreeCoTaskMemUnicode(pointer); }
    }
}
