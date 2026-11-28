using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace HuaYaoPet;

/// <summary>Observes a known Doubao editor when it is in the foreground. No visible text leaves this process.</summary>
internal sealed class DoubaoTaskReader
{
    private sealed record Sample(IntPtr Window, string Editor, int Fingerprint);
    private Task<Sample?>? pending;
    private Sample? previous;
    private DateTimeOffset? lastChange;
    private bool streaming;

    public PetTask? Refresh(DateTimeOffset now)
    {
        if (pending is null) { pending = Task.Run(Observe); return null; }
        if (!pending.IsCompleted) return Current(now);
        var sample = pending.Status == TaskStatus.RanToCompletion ? pending.Result : null;
        pending = Task.Run(Observe);
        if (sample is null || GetForegroundWindow() != sample.Window)
        {
            previous = null;
            lastChange = null;
            streaming = false;
            return null;
        }
        if (previous?.Window != sample.Window || previous.Editor != sample.Editor)
        {
            streaming = false;
            lastChange = null;
        }
        else if (previous.Fingerprint != sample.Fingerprint)
        {
            streaming = lastChange.HasValue && now - lastChange.Value < TimeSpan.FromSeconds(7);
            lastChange = now;
        }
        previous = sample;
        return Current(now);
    }

    private PetTask? Current(DateTimeOffset now)
    {
        if (previous is null || GetForegroundWindow() != previous.Window) return null;
        var active = streaming && lastChange is { } change && now - change < TimeSpan.FromSeconds(7);
        return new PetTask("豆包", "foreground-editor", "普通对话", new PetStatus(
            active ? PetPhase.Working : PetPhase.Idle, active ? "正在回话" : "",
            lastChange?.ToUnixTimeMilliseconds() ?? 0));
    }

    private static Sample? Observe()
    {
        try
        {
            var window = GetForegroundWindow();
            if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out var pid) == 0) return null;
            using var app = Process.GetProcessById((int)pid);
            if (!new[] { "Doubao", "DoubaoDesktop", "doubao-desktop" }.Contains(app.ProcessName, StringComparer.OrdinalIgnoreCase))
                return null;
            var root = AutomationElement.FromHandle(window);
            if (root is null) return null;
            var editor = Walk(root, 240).FirstOrDefault(element =>
                element.Current.AutomationId == "doc_editor" || element.Current.Name == "doc_editor");
            if (editor is null) return null;
            var hash = new HashCode();
            int count = 0;
            foreach (var entry in Walk(editor, 300))
            {
                if (entry.Current.ControlType != ControlType.Text || entry.Current.IsOffscreen) continue;
                var text = entry.Current.Name;
                if (string.IsNullOrEmpty(text)) continue;
                hash.Add(text[..Math.Min(2048, text.Length)]);
                if (++count >= 40) break;
            }
            if (count == 0 || GetForegroundWindow() != window) return null;
            return new Sample(window, string.Join(",", editor.GetRuntimeId()), hash.ToHashCode());
        }
        catch (Exception error) when (error is InvalidOperationException or ArgumentException or
                                      ElementNotAvailableException or COMException or System.ComponentModel.Win32Exception)
        { return null; }
    }

    private static IEnumerable<AutomationElement> Walk(AutomationElement root, int limit)
    {
        var pending = new Queue<AutomationElement>();
        pending.Enqueue(root);
        int visited = 0;
        var walker = TreeWalker.ControlViewWalker;
        while (pending.TryDequeue(out var element) && visited < limit)
        {
            visited++;
            yield return element;
            for (var child = walker.GetFirstChild(element); child is not null && visited + pending.Count < limit;
                 child = walker.GetNextSibling(child)) pending.Enqueue(child);
        }
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
}
