using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using Ellipse = System.Windows.Shapes.Ellipse;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace HuaYaoPet;

internal sealed partial class PetWindow : Window
{
    private sealed record Mode(string Id, string Name, string Default, string[] Titles);
    private static readonly Mode[] Modes =
    [
        new("duo", "双人", "D09", ["依怀小憩","相依倚榻","抚颊对望","并肩低语","双人相拥","背靠相携","倚肩相依","相拥斜卧","执手对望","携手回眸","背向相守","近身凝望","相拥入梦","双人卧花","倚榻双眠","垂眸相依","红袖偷笑","袖里藏花","花落谁头上","红袖偷笑·贴近","袖里藏花·惊讶"]),
        new("hua", "花旦单人", "H08", ["侧身坐姿","托腮正面","掩袖回望","展袖舒身","闭目手势","斜卧长袖","抬袖仰望","正面全身","坐姿飞袖","坐姿花枝","纱罩捧灯","侧身回眸","花间舞袖"]),
        new("sheng", "小生单人", "S03", ["青衣回眸","青衣倚坐","红衣敛袖","红衣执扇"]),
    ];

    private static readonly Dictionary<string, string[]> Lines = new()
    {
        ["duo"] = ["今日台子搭好了，你且坐。", "你看，水袖一拂，花就落了。", "这回的身段，可合你的眼？"],
        ["hua"] = ["且坐片刻，容我理一理水袖。", "这一袖风，替你把花吹过来。", "看官，你瞧见刚才落的花了吗？"],
        ["sheng"] = ["台前灯亮了，我把折扇备好。", "折扇一展，且听这一声锣。", "这位看官，且慢走。"],
    };

    private static readonly Brush Paper = Paint("#FFF8EE"), Ink = Paint("#382822"), BorderInk = Paint("#D8BEB2");
    private readonly Preferences prefs = Preferences.Load();
    private readonly PetBilling billing = new();
    private readonly Image portrait = new() { Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TranslateTransform hop = new();
    private readonly TextBlock speech = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = Ink, FontSize = 14 };
    private readonly TextBlock statusLabel = new() { Foreground = Ink, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Ellipse statusDot = new() { Width = 7, Height = 7, Margin = new Thickness(0, 0, 6, 0) };
    private readonly Canvas petals = new() { IsHitTestVisible = false, ClipToBounds = true };
    private readonly StackPanel bubbleContents = new();
    private readonly Border speechPaper;
    private readonly DispatcherTimer speechTimer = new() { Interval = TimeSpan.FromSeconds(3.6) };
    private readonly DispatcherTimer idleTimer = new() { Interval = TimeSpan.FromSeconds(32) };
    private readonly DispatcherTimer scanTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Forms.NotifyIcon tray;
    private readonly System.Drawing.Icon trayIcon;
    private readonly Dictionary<string, BitmapImage> thumbnails = new();
    private static readonly string[] ThemeLyrics = LoadLines("ThemeLyrics");
    private static readonly string[] OperaScene = LoadLines("OperaScene");
    private HarnessReader? reader;
    private readonly CompanionTaskReader companionReader = CompanionTaskReader.ForCurrentUser();
    private PetStatus current = new(PetPhase.Offline, "暂无会话");
    private bool reading;
    private Point? pressAt;
    private bool closing;
    private readonly Queue<string> pendingLyrics = new();
    private bool manualLyrics;
    private bool closeOnBubbleTap;

    private Mode ActiveMode => Modes.FirstOrDefault(mode => mode.Id == prefs.Mode) ?? Modes[0];

    public PetWindow()
    {
        Title = "花妖桌宠";
        FontFamily = new FontFamily("Microsoft YaHei UI");
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = prefs.Top;
        WindowStartupLocation = WindowStartupLocation.Manual;
        prefs.Mode = ActiveMode.Id;
        prefs.Zoom = Math.Clamp(prefs.Zoom, .70, 1.55);
        InitializeInteraction();
        billing.RoundCompleted = ShowTurnCost;
        billing.BalanceWarning = SetBalanceWarning;
        billing.BudgetWarning = ShowBudgetWarning;

        var stage = new Grid { Margin = new Thickness(10, 5, 10, 5) };
        stage.RowDefinitions.Add(new RowDefinition { Height = new GridLength(69) });
        stage.RowDefinitions.Add(new RowDefinition());
        stage.RowDefinitions.Add(new RowDefinition { Height = new GridLength(33) });
        stage.Children.Add(petals);
        Grid.SetRowSpan(petals, 3);
        portrait.Cursor = Cursors.Hand;
        portrait.MouseLeftButtonDown += BeginPress;
        portrait.MouseMove += MovePress;
        portrait.MouseLeftButtonUp += EndPress;
        portrait.LostMouseCapture += (_, _) => pressAt = null;
        Place(stage, portrait, 1);

        ArrangeBubbleContents();
        speechPaper = Card(new ScrollViewer { Content = bubbleContents, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, 12, new Thickness(10, 6, 10, 6));
        speechPaper.Margin = new Thickness(8, 4, 8, 3);
        speechPaper.VerticalAlignment = VerticalAlignment.Bottom;
        speechPaper.Cursor = Cursors.Hand;
        speechPaper.MouseLeftButtonUp += (_, e) =>
        {
            if (closeOnBubbleTap)
            {
                speechTimer.Stop();
                speechPaper.Visibility = Visibility.Collapsed;
            }
            else TapPet();
            e.Handled = true;
        };
        speechPaper.Visibility = Visibility.Collapsed;
        Place(stage, speechPaper, 0);

        var statusRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        statusRow.Children.Add(statusDot);
        statusRow.Children.Add(statusLabel);
        var status = Card(statusRow, 15, new Thickness(9, 4, 9, 4));
        status.HorizontalAlignment = HorizontalAlignment.Center;
        status.VerticalAlignment = VerticalAlignment.Center;
        status.Cursor = Cursors.Hand;
        status.MouseLeftButtonUp += (_, e) => { OpenTaskMenu(status); e.Handled = true; };
        Place(stage, status, 2);
        Content = stage;
        var context = new ContextMenu();
        context.Opened += (_, _) => Populate(context);
        ContextMenu = context;

        trayIcon = new System.Drawing.Icon(Path.Combine(AppContext.BaseDirectory, "HuaYaoPet.ico"));
        tray = new Forms.NotifyIcon { Icon = trayIcon, Text = "花妖桌宠", Visible = true };
        var trayMenu = new Forms.ContextMenuStrip();
        trayMenu.Items.Add("显示桌宠", null, (_, _) => Dispatcher.Invoke(ShowPet));
        trayMenu.Items.Add("隐藏桌宠", null, (_, _) => Dispatcher.Invoke(Hide));
        trayMenu.Items.Add("移到右下角", null, (_, _) => Dispatcher.Invoke(() => { ShowPet(); MoveToCorner(); }));
        trayMenu.Items.Add("项目与任务", null, (_, _) => Dispatcher.Invoke(() => { ShowPet(); OpenTaskMenu(status); }));
        trayMenu.Items.Add("用量与余额…", null, (_, _) => Dispatcher.Invoke(() => { ShowPet(); billing.Open(this); }));
        trayMenu.Items.Add("退出桌宠", null, (_, _) => Dispatcher.Invoke(Close));
        tray.ContextMenuStrip = trayMenu;
        tray.MouseClick += (_, args) => { if (args.Button == Forms.MouseButtons.Left) Dispatcher.Invoke(ShowPet); };

        speechTimer.Tick += (_, _) =>
        {
            speechTimer.Stop();
            if ((prefs.AutoChat || manualLyrics) && IsVisible && !current.Busy && pendingLyrics.TryDequeue(out var next))
                ShowLine(next);
            else
            {
                pendingLyrics.Clear();
                manualLyrics = false;
                speechPaper.Visibility = Visibility.Collapsed;
            }
        };
        idleTimer.Tick += (_, _) => { if (prefs.AutoChat && IsVisible && !current.Busy) SayIdleLine(); };
        scanTimer.Tick += async (_, _) => await Scan();
        IsVisibleChanged += (_, _) => ApplyStage();
        Loaded += (_, _) =>
        {
            SetPose();
            RestorePosition();
            RenderPetals();
            SetLink();
            billing.Initialize();
            SaySomething();
            idleTimer.Start();
        };
        Closing += (_, _) =>
        {
            closing = true;
            billing.Dispose();
            foreach (var player in cuePlayers.Values) player.Close();
            RememberPosition();
            scanTimer.Stop();
            speechTimer.Stop();
            idleTimer.Stop();
            tray.Visible = false;
            tray.Dispose();
            trayMenu.Dispose();
            trayIcon.Dispose();
        };
    }

    private void Populate(ContextMenu menu)
    {
        menu.Items.Clear();
        var tasks = new MenuItem { Header = "项目与任务" };
        PopulateTasks(tasks.Items);
        menu.Items.Add(tasks);
        Add(menu, "用量与余额…", () => billing.Open(this));
        menu.Items.Add(new Separator());
        foreach (var mode in Modes)
        {
            var entry = Add(menu, mode.Name, () =>
            {
                if (prefs.Mode == mode.Id) return;
                speechTimer.Stop();
                pendingLyrics.Clear();
                manualLyrics = false;
                speechPaper.Visibility = Visibility.Collapsed;
                prefs.Mode = mode.Id;
                SetPose();
                prefs.Save();
            });
            entry.IsCheckable = true;
            entry.IsChecked = mode.Id == prefs.Mode;
        }

        var choices = new MenuItem { Header = "选择立绘" };
        var modeNow = ActiveMode;
        var selected = Selected(modeNow);
        for (var i = 0; i < modeNow.Titles.Length; i++)
        {
            var id = PoseId(modeNow, i);
            var entry = new MenuItem
            {
                Header = modeNow.Titles[i], IsCheckable = true, IsChecked = id == selected,
                Icon = new Image { Width = 25, Height = 29, Source = Thumbnail(id) },
            };
            entry.Click += (_, _) => { prefs.Poses[modeNow.Id] = id; SetPose(); prefs.Save(); };
            choices.Items.Add(entry);
        }
        menu.Items.Add(choices);
        Add(menu, "换一张立绘", () =>
        {
            var options = Enumerable.Range(0, modeNow.Titles.Length).Select(i => PoseId(modeNow, i)).Where(id => id != selected).ToArray();
            prefs.Poses[modeNow.Id] = options[Random.Shared.Next(options.Length)];
            SetPose();
            prefs.Save();
        });
        Add(menu, "说点什么", TapPet);
        Add(menu, "交互设置…", OpenInteractionSettings);
        menu.Items.Add(new Separator());
        Add(menu, "自动闲聊", () => { prefs.AutoChat = !prefs.AutoChat; prefs.Save(); }, prefs.AutoChat);
        Add(menu, "花瓣飘落", () => { prefs.Petals = !prefs.Petals; RenderPetals(); prefs.Save(); }, prefs.Petals);
        Add(menu, "联动 DeepSeek Harness", () => { prefs.Link = !prefs.Link; SetLink(); prefs.Save(); }, prefs.Link);
        Add(menu, "联动 Codex", () => { prefs.CodexLink = !prefs.CodexLink; RefreshLinks(); prefs.Save(); }, prefs.CodexLink);
        Add(menu, "联动 WorkBuddy", () => { prefs.WorkBuddyLink = !prefs.WorkBuddyLink; RefreshLinks(); prefs.Save(); }, prefs.WorkBuddyLink);
        AddAdditionalLinks(menu);
        Add(menu, "始终置顶", () => { prefs.Top = Topmost = !prefs.Top; prefs.Save(); }, prefs.Top);
        menu.Items.Add(new Separator());
        Add(menu, "放大", () => ResizePet(prefs.Zoom + .12));
        Add(menu, "缩小", () => ResizePet(prefs.Zoom - .12));
        Add(menu, "还原大小", () => ResizePet(1));
        Add(menu, "移到右下角", MoveToCorner);
        Add(menu, "隐藏桌宠", Hide);
        Add(menu, "退出桌宠", Close);
    }

    private static MenuItem Add(ContextMenu menu, string title, Action action, bool? isChecked = null)
    {
        var entry = new MenuItem { Header = title, IsCheckable = isChecked.HasValue, IsChecked = isChecked ?? false };
        entry.Click += (_, _) => action();
        menu.Items.Add(entry);
        return entry;
    }

    private static string PoseId(Mode mode, int index) => $"{char.ToUpperInvariant(mode.Id[0])}{index + 1:00}";

    private string Selected(Mode mode)
    {
        if (prefs.Poses.TryGetValue(mode.Id, out var id) &&
            Enumerable.Range(0, mode.Titles.Length).Any(index => PoseId(mode, index) == id)) return id;
        return mode.Default;
    }

    private static BitmapImage LoadImage(string id, int size)
    {
        var file = id[0] switch { 'D' => $"duo_{id}.png", 'H' => $"hua_{id}.png", _ => $"sheng_{id[1..]}.png" };
        var image = new BitmapImage();
        image.BeginInit();
        image.UriSource = new Uri(Path.Combine(AppContext.BaseDirectory, "Pets", file));
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.DecodePixelWidth = size;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private BitmapImage Thumbnail(string id)
    {
        if (!thumbnails.TryGetValue(id, out var image))
            thumbnails[id] = image = LoadImage(id, 48);
        return image;
    }

    private void SetPose()
    {
        ApplyStage();
        ResizePet(prefs.Zoom, remember: false);
    }

    private void ResizePet(double zoom, bool remember = true)
    {
        prefs.Zoom = Math.Clamp(zoom, .70, 1.55);
        var center = double.IsNaN(Left) || double.IsNaN(Width) ? (double?)null : Left + Width / 2;
        var bottom = double.IsNaN(Top) || double.IsNaN(Height) ? (double?)null : Top + Height;
        Width = Math.Max(230, 255 * prefs.Zoom);
        Height = 104 + (ActiveMode.Id == "duo" ? 180 : 161) * prefs.Zoom;
        if (center.HasValue) Left = center.Value - Width / 2;
        if (bottom.HasValue) Top = bottom.Value - Height;
        if (remember)
        {
            FitToMonitor(snap: false);
            RememberPosition();
        }
    }

    private void ShowPet()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
    }

    private void BeginPress(object sender, MouseButtonEventArgs e)
    {
        pressAt = e.GetPosition(this);
        portrait.CaptureMouse();
        e.Handled = true;
    }

    private void MovePress(object sender, MouseEventArgs e)
    {
        if (pressAt is not Point start || e.LeftButton != MouseButtonState.Pressed || (e.GetPosition(this) - start).Length < 5) return;
        pressAt = null;
        portrait.ReleaseMouseCapture();
        if (Mouse.LeftButton == MouseButtonState.Pressed)
        {
            if (SystemParameters.ClientAreaAnimation) dragTilt.Angle = 1.3;
            try { DragMove(); }
            catch (InvalidOperationException) when (Mouse.LeftButton != MouseButtonState.Pressed) { }
            finally { dragTilt.Angle = 0; }
        }
        FitToMonitor(snap: true);
        RememberPosition();
        AnimateResponse(landing: true);
        PlayCue(PetCue.Land);
    }

    private void EndPress(object sender, MouseButtonEventArgs e)
    {
        if (!pressAt.HasValue) return;
        pressAt = null;
        portrait.ReleaseMouseCapture();
        TapPet();
        e.Handled = true;
    }

    private void TapPet()
    {
        AnimateResponse();
        PlayCue(PetCue.Tap);
        billing.RefreshFromPet();
        if (!ShowCustomBubble(BubbleEvent.Tap))
        {
            if (current.Busy) SaySomething();
            else SayIdleLine(manual: true);
        }
    }

    private void SaySomething()
    {
        var options = Lines[ActiveMode.Id].Where(line => line != speech.Text).ToArray();
        Say(options[Random.Shared.Next(options.Length)]);
    }

    private void SayIdleLine(bool manual = false)
    {
        if (ThemeLyrics.Length < 2 || Random.Shared.Next(4) != 0)
        {
            if (manual || !ShowCustomBubble(BubbleEvent.Idle)) SaySomething();
            return;
        }
        if (ActiveMode.Id == "duo")
        {
            var coupletCount = ThemeLyrics.Length / 2;
            var choice = Random.Shared.Next(coupletCount + (OperaScene.Length > 0 ? 1 : 0));
            if (choice == coupletCount)
            {
                Say(OperaScene[0]);
                foreach (var line in OperaScene.Skip(1))
                    pendingLyrics.Enqueue(line);
            }
            else
            {
                var couplet = choice * 2;
                Say($"花旦 · {ThemeLyrics[couplet]}");
                pendingLyrics.Enqueue($"小生 · {ThemeLyrics[couplet + 1]}");
            }
        }
        else
        {
            Say(ThemeLyrics[Random.Shared.Next(ThemeLyrics.Length)]);
        }
        manualLyrics = manual;
    }

    private static string[] LoadLines(string name)
    {
        using var resource = typeof(PetWindow).Assembly.GetManifestResourceStream($"HuaYaoPet.{name}.txt");
        if (resource == null) return [];
        using var reader = new StreamReader(resource);
        return reader.ReadToEnd().Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
    }

    private void Say(string line)
    {
        pendingLyrics.Clear();
        manualLyrics = false;
        ShowLine(line);
    }

    private void ShowLine(string line, BitmapImage? picture = null, double seconds = 3.6, bool dismissOnClick = false, Uri? link = null)
    {
        speech.Text = line;
        bubblePicture.Source = picture;
        bubblePicture.Visibility = picture == null ? Visibility.Collapsed : Visibility.Visible;
        bubbleLink = link;
        bubbleLinkButton.Visibility = link is null ? Visibility.Collapsed : Visibility.Visible;
        speechPaper.Visibility = Visibility.Visible;
        speechTimer.Stop();
        closeOnBubbleTap = dismissOnClick || seconds == 0;
        if (seconds > 0)
        {
            speechTimer.Interval = TimeSpan.FromSeconds(seconds);
            speechTimer.Start();
        }
        idleTimer.Stop();
        idleTimer.Start();
    }

    private void RenderPetals()
    {
        petals.Children.Clear();
        if (!prefs.Petals || !SystemParameters.ClientAreaAnimation) return;
        for (var i = 0; i < 6; i++)
        {
            var flake = new Ellipse { Fill = Paint("#E89AB0"), Width = 5 + (i % 3), Height = 8, Opacity = .54 };
            Canvas.SetLeft(flake, 15 + (i * 37));
            var transform = new TranslateTransform();
            flake.RenderTransform = transform;
            petals.Children.Add(flake);
            transform.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-9, 400, TimeSpan.FromSeconds(6 + i * .38))
            {
                BeginTime = TimeSpan.FromMilliseconds(i * 370),
                RepeatBehavior = RepeatBehavior.Forever
            });
        }
    }

    private void SetLink()
    {
        reader = prefs.Link ? HarnessReader.ForCurrentUser() : null;
        harnessStatus = null;
        RefreshLinks();
    }

    private void RefreshLinks()
    {
        if (AnyLinkEnabled) scanTimer.Start();
        else scanTimer.Stop();
        PresentTasks(notify: false);
    }

    private async Task Scan()
    {
        if (reading || closing) return;
        var active = reader;
        var codex = prefs.CodexLink;
        var workBuddy = prefs.WorkBuddyLink;
        var trae = prefs.TraeLink;
        var antigravity = prefs.AntigravityLink;
        var doubao = prefs.DoubaoLink ? doubaoReader : null;
        reading = true;
        try
        {
            var now = DateTimeOffset.UtcNow;
            var result = await Task.Run(() =>
            {
                var tasks = companionReader.Refresh(now, codex, workBuddy).ToList();
                if (trae) tasks.AddRange(hooks.Read("TRAE", now));
                if (antigravity) tasks.AddRange(hooks.Read("Antigravity", now));
                if (doubao?.Refresh(now) is { } chat) tasks.Add(chat);
                return (Harness: active?.Refresh(now), Tasks: tasks);
            });
            if (closing) return;
            companionTasks = result.Tasks;
            if (ReferenceEquals(active, reader)) harnessStatus = result.Harness;
            PresentTasks(notify: true);
            if (prefs.Link) billing.Observe(harnessStatus?.Usage);
        }
        finally
        {
            reading = false;
        }
    }

    private void UpdateStatusDisplay(string label, PetPhase phase)
    {
        statusLabel.Text = label;
        statusDot.Fill = Paint(phase switch
        {
            PetPhase.Idle => "#497D69",
            PetPhase.Thinking or PetPhase.Waiting => "#A77429",
            PetPhase.Working or PetPhase.Error => "#A94353",
            PetPhase.Done => "#32834E",
            _ => "#887E75"
        });
        if (tray != null) tray.Text = label.Length <= 59 ? $"花妖 · {label}" : "花妖桌宠";
        ApplyStage();
    }

    private static void Place(Grid target, UIElement item, int row)
    {
        Grid.SetRow(item, row);
        target.Children.Add(item);
    }

    private static Border Card(UIElement child, double radius, Thickness padding) => new()
    {
        Background = Paper, BorderBrush = BorderInk, BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(radius), Child = child, Padding = padding
    };

    private static Brush Paint(string hex)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        return brush;
    }
}
