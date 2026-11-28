using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace HuaYaoPet;

internal enum PetCue { Tap, Cost, Question, Approval, Land }
internal enum BubbleEvent { Tap, Idle, Cost, Question, Approval, Warning, Budget }
internal sealed record CueSettings(bool Enabled = false, double Volume = .45);

internal sealed class EdgeSettings
{
    public int Left { get; set; } = 22;
    public int Right { get; set; } = 22;
    public int Top { get; set; } = 22;
    public int Bottom { get; set; } = 22;
    public bool MirrorAtLeft { get; set; }
}

internal sealed class PetInteractionSettings : Window
{
    private readonly Dictionary<BubbleEvent, TextBox> bubbleFields = new();
    private readonly Dictionary<BubbleEvent, Slider> bubbleDurations = new();
    private readonly Dictionary<BubbleEvent, TextBox> bubbleLinks = new();
    private readonly Dictionary<PetCue, (CheckBox Enabled, Slider Volume)> cueFields = new();
    private readonly Dictionary<BubbleEvent, byte[]> pictures;

    public PetInteractionSettings(Window owner, Preferences prefs)
    {
        Owner = owner;
        pictures = new Dictionary<BubbleEvent, byte[]>(prefs.BubblePictures);
        Title = "花妖桌宠 · 交互设置";
        Width = 500;
        Height = 460;
        MinWidth = 410;
        MinHeight = 350;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Background = SystemColors.WindowBrush;

        var root = new DockPanel { Margin = new Thickness(16) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var save = new Button { Content = "保存", IsDefault = true, MinWidth = 72, Padding = new Thickness(12, 5, 12, 5) };
        var cancel = new Button { Content = "取消", IsCancel = true, MinWidth = 72, Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(8, 0, 0, 0) };
        buttons.Children.Add(save);
        buttons.Children.Add(cancel);
        DockPanel.SetDock(buttons, Dock.Bottom);
        root.Children.Add(buttons);
        var tabs = new TabControl();
        root.Children.Add(tabs);
        Content = root;

        var edges = Panel();
        tabs.Items.Add(Tab("摆放", edges));
        edges.Children.Add(new TextBlock { Text = "拖动松手时，桌宠会吸附到距离内的屏幕边缘。设为 0 可关闭对应边缘。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });
        var left = SliderRow(edges, "左边", prefs.Edges.Left, 120);
        var right = SliderRow(edges, "右边", prefs.Edges.Right, 120);
        var top = SliderRow(edges, "上边", prefs.Edges.Top, 120);
        var bottom = SliderRow(edges, "下边", prefs.Edges.Bottom, 120);
        var mirror = Check(edges, "贴左显示镜像", prefs.Edges.MirrorAtLeft);
        var poses = Check(edges, "根据任务状态临时换姿", prefs.StatePoses);

        var sounds = Panel();
        tabs.Items.Add(Tab("音效", sounds));
        foreach (var (cue, name) in new[] { (PetCue.Tap, "点击／落地"), (PetCue.Cost, "本轮结束"), (PetCue.Question, "待回答"), (PetCue.Approval, "待授权") })
        {
            var settings = PetWindow.CuePreference(prefs, cue);
            var enabled = Check(sounds, name, settings.Enabled);
            var volume = SliderRow(sounds, "音量", Math.Round(settings.Volume * 100), 100, "%");
            cueFields.Add(cue, (enabled, volume));
        }

        var bubbles = Panel();
        tabs.Items.Add(Tab("气泡", bubbles));
        bubbles.Children.Add(new TextBlock
        {
            Text = "一行一句。留空使用内置台词。可用 {task}、{model}、{cost}、{balance} 和 {amount} 显示事件数据。",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12)
        });
        var random = Check(bubbles, "随机播放点击台词", prefs.RandomTapBubble);
        foreach (var (bubbleEvent, name) in new[] { (BubbleEvent.Tap, "点击"), (BubbleEvent.Idle, "闲聊"), (BubbleEvent.Cost, "本轮结束"), (BubbleEvent.Question, "待回答"), (BubbleEvent.Approval, "待授权"), (BubbleEvent.Warning, "余额预警"), (BubbleEvent.Budget, "预算提醒") })
        {
            var field = new TextBox
            {
                Text = prefs.Bubbles.GetValueOrDefault(bubbleEvent) ?? "",
                AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxLength = 3000,
                Height = 53, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Margin = new Thickness(0, 2, 0, 8),
            };
            bubbles.Children.Add(new Label { Content = name, Target = field, Padding = new Thickness(0) });
            bubbles.Children.Add(field);
            bubbleFields.Add(bubbleEvent, field);
            AddPicturePicker(bubbles, bubbleEvent);
            var duration = SliderRow(bubbles, "关闭秒数", prefs.BubbleDurations.GetValueOrDefault(bubbleEvent, 4), 60, " 秒");
            duration.ToolTip = "设为 0 时点击气泡关闭";
            bubbleDurations.Add(bubbleEvent, duration);
            var link = new TextBox { Text = prefs.BubbleLinks.GetValueOrDefault(bubbleEvent) ?? "", MaxLength = 2048 };
            bubbles.Children.Add(new Label { Content = "配套 HTTPS 链接（可选）", Target = link, Padding = new Thickness(0) });
            bubbles.Children.Add(link);
            bubbleLinks.Add(bubbleEvent, link);
        }
        var imageAbove = Check(bubbles, "配图置于文字上方", prefs.BubbleImageAboveText);

        save.Click += (_, _) =>
        {
            foreach (var link in bubbleLinks.Values)
            {
                if (string.IsNullOrWhiteSpace(link.Text) || WebLink(link.Text) is not null) continue;
                MessageBox.Show(this, "气泡链接须使用 HTTPS。", "链接格式无效");
                link.Focus();
                return;
            }
            prefs.Edges = new EdgeSettings
            {
                Left = (int)left.Value, Right = (int)right.Value, Top = (int)top.Value, Bottom = (int)bottom.Value,
                MirrorAtLeft = mirror.IsChecked == true,
            };
            prefs.StatePoses = poses.IsChecked == true;
            prefs.RandomTapBubble = random.IsChecked == true;
            prefs.BubblePictures = pictures;
            prefs.BubbleImageAboveText = imageAbove.IsChecked == true;
            foreach (var (ev, field) in bubbleFields) prefs.Bubbles[ev] = field.Text;
            foreach (var (ev, slider) in bubbleDurations) prefs.BubbleDurations[ev] = (int)slider.Value;
            foreach (var (ev, field) in bubbleLinks) prefs.BubbleLinks[ev] = field.Text.Trim();
            foreach (var (cue, fields) in cueFields) prefs.Cues[cue] = new CueSettings(fields.Enabled.IsChecked == true, fields.Volume.Value / 100);
            prefs.Save();
            DialogResult = true;
        };
    }

    internal static Uri? WebLink(string? value) =>
        Uri.TryCreate(value?.Trim(), UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps &&
        uri.Host.Length > 0 && uri.UserInfo.Length == 0 ? uri : null;

    private void AddPicturePicker(Panel panel, BubbleEvent kind)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        var status = new TextBlock { Text = PictureLabel(), Margin = new Thickness(8, 4, 0, 0) };
        var select = new Button { Content = "选择配图…", Margin = new Thickness(0, 0, 6, 0) };
        var remove = new Button { Content = "移除配图" };
        select.Click += (_, _) =>
        {
            var picker = new OpenFileDialog { Title = "选择自定义气泡配图", Filter = "图片|*.png;*.jpg;*.jpeg;*.bmp;*.gif" };
            if (picker.ShowDialog(this) != true) return;
            var image = LoadBubbleImage(picker.FileName);
            if (image is null)
            {
                MessageBox.Show(this, "请选用可读取且不超过 8 MB 的图片。", "无法读取配图");
                return;
            }
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(image));
            using var data = new MemoryStream();
            encoder.Save(data);
            pictures[kind] = data.ToArray();
            status.Text = PictureLabel();
        };
        remove.Click += (_, _) => { pictures.Remove(kind); status.Text = PictureLabel(); };
        row.Children.Add(select);
        row.Children.Add(remove);
        row.Children.Add(status);
        panel.Children.Add(row);

        string PictureLabel() => pictures.ContainsKey(kind) ? "已附加图片" : "未附加图片";
    }

    public static BitmapImage? LoadBubblePicture(byte[]? data)
    {
        if (data is null || data.Length == 0 || data.Length > 8 * 1024 * 1024) return null;
        try
        {
            using var stream = new MemoryStream(data);
            var image = new BitmapImage();
            image.BeginInit();
            image.StreamSource = stream;
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception error) when (error is IOException or NotSupportedException or ArgumentException or InvalidOperationException)
        { return null; }
    }

    public static BitmapImage? LoadBubbleImage(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            using var file = File.OpenRead(path);
            if (file.Length > 8 * 1024 * 1024) return null;
            var image = new BitmapImage();
            image.BeginInit();
            image.StreamSource = file;
            image.DecodePixelWidth = 280;
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception problem) when (problem is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or FormatException or InvalidOperationException)
        {
            return null;
        }
    }

    private static StackPanel Panel() => new() { Margin = new Thickness(14) };

    private static TabItem Tab(string title, StackPanel panel) => new()
    {
        Header = title, Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }
    };

    private static CheckBox Check(Panel panel, string label, bool value)
    {
        var control = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 5, 0, 5) };
        panel.Children.Add(control);
        return control;
    }

    private static Slider SliderRow(Panel panel, string label, double value, double max, string unit = "")
    {
        var row = new DockPanel { Margin = new Thickness(0, 1, 0, 7) };
        var slider = new Slider { Minimum = 0, Maximum = max, Value = Math.Clamp(value, 0, max), TickFrequency = 1, IsSnapToTickEnabled = true };
        var name = new Label { Content = label, Target = slider, Padding = new Thickness(0), Width = 54 };
        var number = new TextBlock { Text = $"{slider.Value:0}{unit}", Width = 46, Margin = new Thickness(8, 0, 0, 0) };
        slider.ValueChanged += (_, _) => number.Text = $"{slider.Value:0}{unit}";
        DockPanel.SetDock(number, Dock.Right);
        row.Children.Add(name);
        row.Children.Add(number);
        row.Children.Add(slider);
        panel.Children.Add(row);
        return slider;
    }
}
