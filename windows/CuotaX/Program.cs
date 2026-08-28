// SPDX-License-Identifier: MIT

namespace CuotaX;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var screenshotIndex = Array.IndexOf(args, "--screenshot");
        if (screenshotIndex >= 0 && screenshotIndex + 1 < args.Length)
        {
            ApplicationConfiguration.Initialize();
            ScreenshotRenderer.Save(args[screenshotIndex + 1]);
            return;
        }

        if (args.Contains("--unregister", StringComparer.Ordinal))
        {
            StartupRegistration.Unregister();
            return;
        }

        using var mutex = new Mutex(initiallyOwned: true, @"Local\CuotaX", out var isFirstInstance);
        if (!isFirstInstance)
        {
            return;
        }

        ApplicationConfiguration.Initialize();
        using var context = new TrayApplicationContext(
            registerStartup: !args.Contains("--no-register", StringComparer.Ordinal)
        );
        Application.Run(context);
    }
}
