using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace HuaYaoPet;

internal sealed partial class PetWindow
{
    private const string HarnessPlatform = "DeepSeek Harness";
    private readonly long tasksStartedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    private readonly List<PetTask> recentTasks = new();
    private readonly Dictionary<(string Platform, string Id), PetStatus> observedTasks = new();
    private IReadOnlyList<PetTask> visibleTasks = [];
    private IReadOnlyList<PetTask> companionTasks = [];
    private PetStatus? harnessStatus;

    private bool PlatformEnabled(string platform) => platform switch
    {
        HarnessPlatform => prefs.Link,
        "Codex" => prefs.CodexLink,
        "WorkBuddy" => prefs.WorkBuddyLink,
        "TRAE" => prefs.TraeLink,
        "Antigravity" => prefs.AntigravityLink,
        "豆包" => prefs.DoubaoLink,
        _ => false,
    };

    private bool IsTaskCleared(PetStatus status) =>
        status.Phase != PetPhase.Offline && prefs.TasksClearedAt > 0 && status.Activity <= prefs.TasksClearedAt;

    private static bool IsTaskResult(PetStatus status) => status.Phase is PetPhase.Done or PetPhase.Error or PetPhase.Cancelled;

    private static int TaskPriority(PetStatus status) => status.Phase switch
    {
        PetPhase.Waiting => 4,
        PetPhase.Thinking or PetPhase.Working => 3,
        PetPhase.Done or PetPhase.Error or PetPhase.Cancelled => 2,
        PetPhase.Idle => 1,
        _ => 0,
    };

    private void PresentTasks(bool notify)
    {
        var tasks = companionTasks.Where(task => PlatformEnabled(task.Platform)).ToList();
        if (prefs.Link && harnessStatus is { Phase: not PetPhase.Offline } status)
        {
            var name = string.Join(" · ", new[] { status.ProjectName, status.SessionTitle }.Where(part => !string.IsNullOrWhiteSpace(part)));
            tasks.Add(new PetTask(HarnessPlatform, status.SessionId ?? "current", name, status));
        }
        var visible = tasks.Where(task => !IsTaskCleared(task.Status)).ToArray();
        visibleTasks = visible.OrderByDescending(task => TaskPriority(task.Status))
            .ThenByDescending(task => task.Status.Activity).ToArray();

        var preferred = visibleTasks.FirstOrDefault();
        current = preferred?.Status ?? new PetStatus(PetPhase.Offline, "");
        if (current.Busy) pendingLyrics.Clear();
        var waiting = visible.Count(task => task.Status.Phase == PetPhase.Waiting);
        var running = visible.Count(task => task.Status.Phase is PetPhase.Thinking or PetPhase.Working);
        var counts = string.Join(" · ", new[]
        {
            running > 0 ? $"{running} 项进行中" : "",
            waiting > 0 ? $"{waiting} 项待确认" : "",
        }.Where(part => part.Length > 0));
        var label = counts.Length > 0 ? counts
            : preferred != null ? $"{preferred.Platform} · {TaskLabel(preferred)}"
            : !AnyLinkEnabled ? "AI 联动已关闭"
            : prefs.TasksClearedAt > 0 ? "等待新任务活动" : "AI 联动 · 等待会话";
        UpdateStatusDisplay(label, current.Phase);

        var recentCutoff = DateTimeOffset.UtcNow.AddMinutes(-30).ToUnixTimeMilliseconds();
        recentTasks.RemoveAll(task => task.Status.Activity < recentCutoff);
        var transition = visibleTasks.FirstOrDefault(IsTaskNotice);
        foreach (var task in visibleTasks)
        {
            var taskStatus = task.Status;
            observedTasks[(task.Platform, task.Id)] = taskStatus;
            if (IsTaskResult(taskStatus) && taskStatus.Activity >= recentCutoff &&
                !recentTasks.Any(result => result.Platform == task.Platform && result.Id == task.Id &&
                    result.Status.Activity == taskStatus.Activity && result.Status.Phase == taskStatus.Phase))
                recentTasks.Add(task);
        }

        // Keep recently seen task identities through brief reader outages to avoid repeating cues.
        foreach (var key in observedTasks.Where(item => item.Value.Activity < recentCutoff &&
            !visibleTasks.Any(task => (task.Platform, task.Id) == item.Key)).Select(item => item.Key).ToArray())
            observedTasks.Remove(key);
        if (recentTasks.Count > 64)
        {
            recentTasks.Sort((a, b) => b.Status.Activity.CompareTo(a.Status.Activity));
            recentTasks.RemoveRange(64, recentTasks.Count - 64);
        }

        if (notify && IsVisible && transition != null) NotifyTask(transition);
    }

    private bool IsTaskNotice(PetTask task)
    {
        observedTasks.TryGetValue((task.Platform, task.Id), out var previous);
        var status = task.Status;
        if (status.Phase == PetPhase.Waiting)
            return previous?.Phase != PetPhase.Waiting || previous.WaitKind != status.WaitKind;

        var isRecentResult = IsTaskResult(status) && status.Activity >= tasksStartedAt;
        return isRecentResult &&
            !(previous?.Phase == status.Phase && previous.Activity == status.Activity);
    }

    private void NotifyTask(PetTask task)
    {
        var status = task.Status;
        if (status.Phase == PetPhase.Waiting)
        {
            var question = status.WaitKind == HarnessWaitKind.Question;
            ShowCustomBubble(question ? BubbleEvent.Question : BubbleEvent.Approval, task: task.Name,
                fallback: question ? $"那边有话问你，回 {task.Platform} 看一眼罢。" : $"那边等你点头呢，回 {task.Platform} 看一眼罢。");
            PlayCue(question ? PetCue.Question : PetCue.Approval);
        }
        else if (status.Phase == PetPhase.Done)
        {
            // Harness replaces this fallback with a billed amount once its usage pipeline publishes settlement.
            var line = ActiveMode.Id == "duo" ? "这一轮忙完了，咱们递杯茶去？" : "这一轮忙完了，且歇片刻。";
            ShowCustomBubble(BubbleEvent.Cost, fallback: $"{task.Platform} · {line}");
            AnimateResponse(11);
            if (task.Platform != HarnessPlatform || status.Usage?.LatestRound is not { } round ||
                round.CompletedAt.ToUnixTimeMilliseconds() != status.Activity)
                PlayCue(PetCue.Cost);
        }
        else
        {
            Say(status.Phase == PetPhase.Error ? $"{task.Platform} · 这一轮遇到些问题。" : $"{task.Platform} · 这一轮已中止。");
        }
    }

    private void OpenTaskMenu(FrameworkElement target)
    {
        var menu = new ContextMenu { PlacementTarget = target, Placement = PlacementMode.Top };
        PopulateTasks(menu.Items);
        menu.IsOpen = true;
    }

    private void PopulateTasks(ItemCollection items)
    {
        items.Clear();
        var running = visibleTasks.Where(task => !IsTaskResult(task.Status)).ToArray();
        if (running.Length > 0)
        {
            items.Add(new MenuItem { Header = "当前会话", IsEnabled = false });
            foreach (var task in running) items.Add(TaskMenuRow(task));
        }

        var cutoff = DateTimeOffset.UtcNow.AddMinutes(-30).ToUnixTimeMilliseconds();
        var results = recentTasks.Where(task => PlatformEnabled(task.Platform) && task.Status.Activity >= cutoff)
            .OrderByDescending(task => task.Status.Activity).ToArray();
        if (results.Length > 0)
        {
            if (running.Length > 0) items.Add(new Separator());
            items.Add(new MenuItem { Header = "最近结果", IsEnabled = false });
            foreach (var task in results) items.Add(TaskMenuRow(task));
        }
        if (running.Length == 0 && results.Length == 0)
            items.Add(new MenuItem { Header = "暂无任务活动", IsEnabled = false });

        items.Add(new Separator());
        var clear = new MenuItem { Header = "清空任务状态", IsEnabled = running.Length > 0 || results.Length > 0 };
        clear.Click += (_, _) =>
        {
            prefs.TasksClearedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            prefs.Save();
            recentTasks.Clear();
            speechTimer.Stop();
            pendingLyrics.Clear();
            speechPaper.Visibility = Visibility.Collapsed;
            PresentTasks(notify: false);
        };
        items.Add(clear);
    }

    private static string TaskLabel(PetTask task) => task.Status.Phase == PetPhase.Waiting
        ? task.Status.WaitKind == HarnessWaitKind.Question ? "待回答" : "待确认"
        : task.Status.Label;

    private static MenuItem TaskMenuRow(PetTask task)
    {
        var identity = string.IsNullOrWhiteSpace(task.Name) ? task.Platform : $"{task.Platform} · {task.Name}";
        var timestamp = task.Status.Activity is > 0 and <= 253402300799999
            ? DateTimeOffset.FromUnixTimeMilliseconds(task.Status.Activity).ToLocalTime().ToString("HH:mm") : "";
        return new MenuItem
        {
            Header = $"{TaskLabel(task)} · {identity}",
            ToolTip = string.Join(" · ", new[] { identity, timestamp }.Where(part => part.Length > 0)),
            IsEnabled = false,
        };
    }
}
