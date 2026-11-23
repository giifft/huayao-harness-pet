using System;
using System.Threading;
using System.Windows;

namespace HuaYaoPet;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var instance = new Mutex(true, @"Local\HuaYaoPet.Desktop", out var first);
        if (!first) return;
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.Run(new PetWindow());
    }
}
