using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Windows;

namespace HuaYaoPet;

internal static class Program
{
    private const string InstanceName = @"Local\HuaYaoPet.Desktop";

    [STAThread]
    private static void Main(string[] args)
    {
        if (args is ["--huayao-task-hook", var platform, var eventName])
        {
            ReceiveHook(platform, eventName);
            return;
        }
        using var instance = new Mutex(true, InstanceName, out var first);
        if (!first) return;
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.Run(new PetWindow());
    }

    private static void ReceiveHook(string platform, string eventName)
    {
        try
        {
            if (!Mutex.TryOpenExisting(InstanceName, out var instance)) return;
            using (instance)
            {
                var input = new char[256 * 1024 + 1];
                var size = Console.In.ReadBlock(input, 0, input.Length);
                if (size > 0 && size < input.Length)
                    CompanionHooks.ForCurrentUser().Observe(platform, eventName, new string(input, 0, size), DateTimeOffset.UtcNow);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        finally
        {
            var result = (platform, eventName) switch
            {
                ("Antigravity", "PreToolUse") => "{\"decision\":\"allow\"}",
                ("Antigravity", "Stop") => "{\"decision\":\"stop\"}",
                _ => "{}"
            };
            Console.WriteLine(result);
        }
    }
}
