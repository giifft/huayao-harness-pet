using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Windows;
using System.Windows.Controls;

namespace HuaYaoPet;

internal sealed partial class PetWindow
{
    private readonly CompanionHooks hooks = CompanionHooks.ForCurrentUser();
    private DoubaoTaskReader doubaoReader = new();
    private bool AnyLinkEnabled => prefs.Link || prefs.CodexLink || prefs.WorkBuddyLink ||
        prefs.TraeLink || prefs.AntigravityLink || prefs.DoubaoLink;

    private void AddAdditionalLinks(ContextMenu menu)
    {
        Add(menu, prefs.TraeLink ? "移除 TRAE 联动…" : "配置 TRAE 联动…", () => ConfigureHook("TRAE", prefs.TraeLink));
        Add(menu, prefs.AntigravityLink ? "移除 Antigravity 联动…" : "配置 Antigravity 联动…",
            () => ConfigureHook("Antigravity", prefs.AntigravityLink));
        Add(menu, "联动豆包", ToggleDoubao, prefs.DoubaoLink);
    }

    private void ConfigureHook(string platform, bool remove)
    {
        if (!remove && System.Windows.MessageBox.Show(this,
                $"在 {platform} 的用户配置中添加花妖桌宠的任务状态 Hook。现有其他 Hook 会保留。",
                $"配置 {platform} 联动", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;
        try
        {
            if (remove) hooks.Uninstall(platform);
            else hooks.Install(platform, Environment.ProcessPath ?? throw new IOException("找不到桌宠程序路径。"));
            if (platform == "TRAE") prefs.TraeLink = !remove;
            else prefs.AntigravityLink = !remove;
            prefs.Save();
            RefreshLinks();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            System.Windows.MessageBox.Show(this, error.Message, $"无法更新 {platform} 联动", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void ToggleDoubao()
    {
        if (!prefs.DoubaoLink && System.Windows.MessageBox.Show(this,
                "豆包在前台时，花妖桌宠使用 Windows UI 自动化读取已识别的普通对话。可见文本仅在本机用于对比变化，桌宠只显示是否正在回话。",
                "开启豆包联动", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;
        prefs.DoubaoLink = !prefs.DoubaoLink;
        if (!prefs.DoubaoLink) Interlocked.Exchange(ref doubaoReader, new DoubaoTaskReader());
        prefs.Save();
        RefreshLinks();
    }
}
