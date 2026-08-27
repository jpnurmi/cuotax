// SPDX-License-Identifier: MIT

using Microsoft.Win32;

namespace CuotaX;

internal static class StartupRegistration
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "CuotaX";

    internal static void Register()
    {
        if (Environment.ProcessPath is not { } executable)
        {
            return;
        }

        var command = $"\"{executable}\" --startup";
        using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
        key.SetValue(ValueName, command);
    }

    internal static void Unregister()
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true);
        key?.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
