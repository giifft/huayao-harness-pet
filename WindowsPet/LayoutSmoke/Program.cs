using System;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using HuaYaoPet;

internal static class Program
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

    [STAThread]
    private static void Main()
    {
        _ = new Application();
        var petType = Assembly.Load("HuaYaoPet").GetType("HuaYaoPet.PetWindow", throwOnError: true)!;
        var pet = (Window)Activator.CreateInstance(petType)!;
        var portrait = (Image)petType.GetField("portrait", Private)!.GetValue(pet)!;
        var prefs = petType.GetField("prefs", Private)!.GetValue(pet)!;
        foreach (var flag in new[] { "Link", "CodexLink", "WorkBuddyLink", "AutoChat", "Petals" })
            prefs.GetType().GetProperty(flag)!.SetValue(prefs, false);

        ContextMenu Menu()
        {
            var menu = new ContextMenu();
            petType.GetMethod("Populate", Private)!.Invoke(pet, [menu]);
            return menu;
        }

        static MenuItem Item(ContextMenu menu, string title) =>
            menu.Items.OfType<MenuItem>().Single(item => Equals(item.Header, title));

        static void Click(MenuItem item) => item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));

        var modes = new[]
        {
            (Title: "双人", Prefix: "duo_D", Working: "duo_D10", Count: 21),
            (Title: "花旦单人", Prefix: "hua_H", Working: "hua_H04", Count: 13),
            (Title: "小生单人", Prefix: "sheng_", Working: "sheng_03", Count: 4)
        };

        Rect Measure(string expectedFile)
        {
            pet.UpdateLayout();
            var image = (BitmapImage)portrait.Source;
            var file = image.UriSource.LocalPath;
            if (!file.EndsWith(expectedFile + ".png", StringComparison.OrdinalIgnoreCase) ||
                image.PixelWidth != 520 || image.PixelHeight != 520)
                throw new InvalidOperationException($"Unexpected WPF image for {expectedFile}: {file}");

            var position = portrait.TranslatePoint(new Point(0, 0), pet);
            return new Rect(position, portrait.RenderSize);
        }

        pet.Show();
        try
        {
            var current = petType.GetField("current", Private)!;
            var apply = petType.GetMethod("ApplyStage", Private)!;
            var breath = (System.Windows.Media.ScaleTransform)petType.GetField("breath", Private)!.GetValue(pet)!;
            foreach (var zoom in new[] { .70, 1.0, 1.55 })
            {
                petType.GetMethod("ResizePet", Private)!.Invoke(pet, [zoom, false]);
                Rect? common = null;
                void Verify(string expectedFile)
                {
                    // Stop the idle animation so the measurement describes the stage layout.
                    breath.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleYProperty, (AnimationTimeline?)null);
                    var frame = Measure(expectedFile);
                    common ??= frame;
                    if (Math.Abs(frame.Width - 300 * zoom) > .1 ||
                        Math.Abs(frame.Height - frame.Width) > .1 || frame != common.Value)
                        throw new InvalidOperationException($"{expectedFile} changed the WPF stage at zoom {zoom}: {frame}.");
                }

                foreach (var mode in modes)
                {
                    current.SetValue(pet, new PetStatus(PetPhase.Idle, ""));
                    Click(Item(Menu(), mode.Title));
                    var poses = Item(Menu(), "选择立绘").Items.OfType<MenuItem>().ToArray();
                    if (poses.Length != mode.Count)
                        throw new InvalidOperationException($"{mode.Title} has {poses.Length} poses.");
                    for (var i = 0; i < poses.Length; i++)
                    {
                        Click(poses[i]);
                        Verify($"{mode.Prefix}{i + 1:00}");
                    }

                    current.SetValue(pet, new PetStatus(PetPhase.Working, ""));
                    apply.Invoke(pet, null);
                    Verify(mode.Working);
                }
            }
        }
        finally
        {
            pet.Close();
        }

        Console.WriteLine("WPF rendered all 38 selected poses and each working pose at three zoom levels.");
    }
}
