using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace HuaYaoPet;

internal sealed partial class PetWindow
{
    private static readonly Dictionary<string, Dictionary<PetPhase, string>> StagePoses = new()
    {
        ["duo"] = new() { [PetPhase.Thinking] = "D02", [PetPhase.Working] = "D10", [PetPhase.Waiting] = "D11", [PetPhase.Done] = "D01", [PetPhase.Error] = "D16" },
        ["hua"] = new() { [PetPhase.Thinking] = "H02", [PetPhase.Working] = "H04", [PetPhase.Waiting] = "H09", [PetPhase.Done] = "H12", [PetPhase.Error] = "H10" },
        ["sheng"] = new() { [PetPhase.Thinking] = "S02", [PetPhase.Working] = "S03", [PetPhase.Waiting] = "S04", [PetPhase.Done] = "S01", [PetPhase.Error] = "S02" },
    };

    private readonly Dictionary<string, BitmapImage> sprites = new();
    private readonly Dictionary<PetCue, MediaPlayer> cuePlayers = new();
    private readonly ScaleTransform breath = new();
    private readonly ScaleTransform mirror = new();
    private readonly RotateTransform stageTilt = new();
    private readonly RotateTransform dragTilt = new();
    private readonly Image bubblePicture = new() { MaxHeight = 38, MaxWidth = 150, Margin = new Thickness(0, 0, 0, 2), Visibility = Visibility.Collapsed };
    private readonly Button bubbleLinkButton = new()
    {
        Content = "打开链接 ↗", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center,
        Cursor = System.Windows.Input.Cursors.Hand, Margin = new Thickness(0, 3, 0, 0)
    };
    private Uri? bubbleLink;
    private int tapBubbleIndex;
    private bool balanceLow;
    private readonly Dictionary<BubbleEvent, BitmapImage> customBubblePictures = new();
    private string? shownPose;
    private PetPhase? animatedPhase;

    private void InitializeInteraction()
    {
        var transforms = new TransformGroup();
        transforms.Children.Add(mirror);
        transforms.Children.Add(breath);
        transforms.Children.Add(stageTilt);
        transforms.Children.Add(dragTilt);
        transforms.Children.Add(hop);
        portrait.RenderTransform = transforms;
        portrait.RenderTransformOrigin = new Point(.5, 1600.0 / 1728.0);
        LoadBubblePictures();
        bubbleLinkButton.Click += (_, _) =>
        {
            if (bubbleLink is null) return;
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(bubbleLink.AbsoluteUri) { UseShellExecute = true });
            }
            catch (System.ComponentModel.Win32Exception)
            {
                System.Windows.MessageBox.Show(this, "无法打开默认浏览器。", "花妖桌宠");
            }
        };
    }

    private void OpenInteractionSettings()
    {
        if (new PetInteractionSettings(this, prefs).ShowDialog() != true) return;
        LoadBubblePictures();
        ArrangeBubbleContents();
        tapBubbleIndex = 0;
        FitToMonitor(snap: false);
        ApplyStage();
    }

    private void LoadBubblePictures()
    {
        customBubblePictures.Clear();
        foreach (var (kind, data) in prefs.BubblePictures)
            if (PetInteractionSettings.LoadBubblePicture(data) is { } picture)
                customBubblePictures[kind] = picture;
    }

    private void ArrangeBubbleContents()
    {
        bubbleContents.Children.Clear();
        if (prefs.BubbleImageAboveText)
        {
            bubbleContents.Children.Add(bubblePicture);
            bubbleContents.Children.Add(speech);
        }
        else
        {
            bubbleContents.Children.Add(speech);
            bubbleContents.Children.Add(bubblePicture);
        }
        bubbleContents.Children.Add(bubbleLinkButton);
    }

    private void UpdateMirror(bool atLeftEdge) =>
        mirror.ScaleX = atLeftEdge && prefs.Edges.MirrorAtLeft && ActiveMode.Id != "duo" ? -1 : 1;

    private void ApplyStage()
    {
        var mode = ActiveMode;
        var phase = IsTaskCleared(current) ? PetPhase.Idle : current.Phase;
        if (balanceLow && (phase is PetPhase.Idle or PetPhase.Offline)) phase = PetPhase.Error;
        var pose = prefs.StatePoses ? StagePoses[mode.Id].GetValueOrDefault(phase) ?? Selected(mode) : Selected(mode);
        if (shownPose != pose)
        {
            if (!sprites.TryGetValue(pose, out var sprite))
                sprites[pose] = sprite = LoadImage(pose, 520);
            portrait.Source = sprite;
            shownPose = pose;
        }
        UpdateStageMotion(phase);
    }

    private void UpdateStageMotion(PetPhase phase)
    {
        if (!IsVisible || !SystemParameters.ClientAreaAnimation)
        {
            breath.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            stageTilt.BeginAnimation(RotateTransform.AngleProperty, null);
            dragTilt.BeginAnimation(RotateTransform.AngleProperty, null);
            hop.BeginAnimation(TranslateTransform.YProperty, null);
            animatedPhase = null;
            return;
        }
        if (animatedPhase == phase) return;
        animatedPhase = phase;
        var rocking = phase == PetPhase.Waiting || phase == PetPhase.Thinking;
        stageTilt.BeginAnimation(RotateTransform.AngleProperty, rocking
            ? RepeatingMotion(-.75, .75, phase == PetPhase.Waiting ? .5 : .92)
            : null);
        breath.BeginAnimation(ScaleTransform.ScaleYProperty, RepeatingMotion(1, rocking ? 1.01 : 1.019, 2.1));
    }

    private static DoubleAnimation RepeatingMotion(double from, double to, double seconds) => new(from, to, TimeSpan.FromSeconds(seconds))
    {
        AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
    };

    private void AnimateResponse(double height = 8, bool landing = false)
    {
        if (!IsVisible || !SystemParameters.ClientAreaAnimation) return;
        var motion = new DoubleAnimationUsingKeyFrames { FillBehavior = FillBehavior.Stop };
        motion.KeyFrames.Add(new EasingDoubleKeyFrame(landing ? 3 : -height, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(140)), new SineEase { EasingMode = EasingMode.EaseOut }));
        motion.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(335)), new SineEase { EasingMode = EasingMode.EaseInOut }));
        hop.BeginAnimation(TranslateTransform.YProperty, motion);
    }

    internal static CueSettings CuePreference(Preferences prefs, PetCue cue)
    {
        var settings = prefs.Cues.GetValueOrDefault(cue == PetCue.Land ? PetCue.Tap : cue) ?? new();
        return settings with { Volume = double.IsFinite(settings.Volume) ? Math.Clamp(settings.Volume, 0, 1) : .45 };
    }

    private void PlayCue(PetCue cue)
    {
        if (!IsVisible) return;
        var settings = CuePreference(prefs, cue);
        if (!settings.Enabled || settings.Volume <= 0) return;
        if (!cuePlayers.TryGetValue(cue, out var player))
        {
            var name = cue.ToString().ToLowerInvariant() + ".wav";
            var path = Path.Combine(AppContext.BaseDirectory, "PetSounds", name);
            if (!File.Exists(path)) return;
            cuePlayers[cue] = player = new MediaPlayer();
            player.Open(new Uri(path));
        }
        else
        {
            player.Stop();
            player.Position = TimeSpan.Zero;
        }
        player.Volume = settings.Volume;
        player.Play();
    }

    private bool ShowCustomBubble(BubbleEvent kind, string? model = null, string? cost = null,
        string? task = null, string? balance = null, string? amount = null, string? fallback = null)
    {
        var choices = prefs.Bubbles.GetValueOrDefault(kind)?
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        customBubblePictures.TryGetValue(kind, out var picture);
        var link = PetInteractionSettings.WebLink(prefs.BubbleLinks.GetValueOrDefault(kind));
        if ((choices is null || choices.Length == 0) && picture is null && fallback is null && link is null) return false;
        var value = fallback ?? "";
        if (choices is { Length: > 0 })
        {
            var index = kind == BubbleEvent.Tap && !prefs.RandomTapBubble
                ? (int)((uint)tapBubbleIndex++ % (uint)choices.Length)
                : Random.Shared.Next(choices.Length);
            value = choices[index].Replace("{model}", model ?? "当前会话", StringComparison.Ordinal)
                .Replace("{cost}", cost ?? "费用暂无", StringComparison.Ordinal)
                .Replace("{task}", task ?? "当前任务", StringComparison.Ordinal)
                .Replace("{balance}", balance ?? "余额暂无", StringComparison.Ordinal)
                .Replace("{amount}", amount ?? "用量暂无", StringComparison.Ordinal);
        }
        pendingLyrics.Clear();
        ShowLine(value, picture, Math.Clamp(prefs.BubbleDurations.GetValueOrDefault(kind, 4), 0, 60),
            dismissOnClick: kind is not (BubbleEvent.Tap or BubbleEvent.Idle), link: link);
        return true;
    }

    private void ShowTurnCost(string cost, string model)
    {
        if (!IsVisible || current.Busy) return;
        ShowCustomBubble(BubbleEvent.Cost, model, cost,
            fallback: string.IsNullOrWhiteSpace(model) ? $"本轮用量 · {cost}" : $"{model} · 本轮 {cost}");
        PlayCue(PetCue.Cost);
        AnimateResponse(11);
    }

    private void SetBalanceWarning(bool low, string balance)
    {
        var newlyLow = low && !balanceLow;
        balanceLow = low;
        ApplyStage();
        if (newlyLow && IsVisible && !current.Busy)
        {
            ShowCustomBubble(BubbleEvent.Warning, balance: balance, fallback: $"DeepSeek 余额偏低 · {balance}");
            AnimateResponse(4);
        }
    }

    private void ShowBudgetWarning(string amount)
    {
        if (IsVisible && !current.Busy)
            ShowCustomBubble(BubbleEvent.Budget, amount: amount, fallback: $"今日用量已达预算 · {amount}");
    }
}
