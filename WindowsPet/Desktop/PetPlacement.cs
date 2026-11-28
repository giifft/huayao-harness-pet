using System;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using Forms = System.Windows.Forms;

namespace HuaYaoPet;

internal sealed partial class PetWindow
{
    private IntPtr NativeHandle => new WindowInteropHelper(this).Handle;

    private Rectangle? WindowPixels()
    {
        var handle = NativeHandle;
        if (handle == IntPtr.Zero || !GetWindowRect(handle, out var rect)) return null;
        return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
    }

    private void PlacePixels(int left, int top)
    {
        var handle = NativeHandle;
        if (handle != IntPtr.Zero)
            SetWindowPos(handle, IntPtr.Zero, left, top, 0, 0, 0x0001 | 0x0004 | 0x0010);
    }

    private int ToPixels(double logicalDistance)
    {
        var dpi = GetDpiForWindow(NativeHandle);
        return (int)Math.Round(logicalDistance * (dpi == 0 ? 1 : dpi / 96.0));
    }

    private void FitToMonitor(bool snap)
    {
        if (WindowPixels() is not Rectangle frame) return;
        var area = Forms.Screen.FromRectangle(frame).WorkingArea;
        var maxLeft = Math.Max(area.Left, area.Right - frame.Width);
        var maxTop = Math.Max(area.Top, area.Bottom - frame.Height);
        var left = Math.Clamp(frame.Left, area.Left, maxLeft);
        var top = Math.Clamp(frame.Top, area.Top, maxTop);
        if (snap)
        {
            left = SnapCoordinate(left, area.Left, maxLeft, prefs.Edges.Left, prefs.Edges.Right);
            top = SnapCoordinate(top, area.Top, maxTop, prefs.Edges.Top, prefs.Edges.Bottom);
        }
        if (left != frame.Left || top != frame.Top) PlacePixels(left, top);
        UpdateMirror(left == area.Left);
    }

    private int SnapCoordinate(int value, int start, int end, int startDistance, int endDistance)
    {
        var fromStart = value - start;
        var fromEnd = end - value;
        var nearStart = startDistance > 0 && fromStart <= ToPixels(Math.Min(startDistance, 120));
        var nearEnd = endDistance > 0 && fromEnd <= ToPixels(Math.Min(endDistance, 120));
        if (nearStart && (!nearEnd || fromStart <= fromEnd)) return start;
        return nearEnd ? end : value;
    }

    private void MoveToCorner()
    {
        if (WindowPixels() is not Rectangle frame) return;
        var area = Forms.Screen.FromRectangle(frame).WorkingArea;
        PlacePixels(Math.Max(area.Left, area.Right - frame.Width - ToPixels(22)),
                    Math.Max(area.Top, area.Bottom - frame.Height - ToPixels(18)));
        UpdateMirror(false);
        RememberPosition();
    }

    private void RestorePosition()
    {
        if (WindowPixels() is not Rectangle frame) return;
        if (prefs.ScreenPixelLeft is int x && prefs.ScreenPixelTop is int y)
        {
            var saved = new Rectangle(x, y, frame.Width, frame.Height);
            if (Forms.Screen.AllScreens.Any(screen => screen.WorkingArea.IntersectsWith(saved)))
            {
                PlacePixels(x, y);
                FitToMonitor(snap: false);
                return;
            }
        }
        else if (prefs.Left is double left && double.IsFinite(left) &&
                 prefs.TopPosition is double top && double.IsFinite(top))
        {
            Left = left;
            Top = top;
            if (WindowPixels() is Rectangle previous &&
                Forms.Screen.AllScreens.Any(screen => screen.WorkingArea.IntersectsWith(previous)))
            {
                FitToMonitor(snap: false);
                return;
            }
        }
        MoveToCorner();
    }

    private void RememberPosition()
    {
        if (WindowPixels() is Rectangle frame)
        {
            prefs.ScreenPixelLeft = frame.Left;
            prefs.ScreenPixelTop = frame.Top;
        }
        if (double.IsFinite(Left) && double.IsFinite(Top))
        {
            prefs.Left = Left;
            prefs.TopPosition = Top;
        }
        prefs.Save();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
}
