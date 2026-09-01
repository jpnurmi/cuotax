# CuotaX

A minimal GNOME Shell extension, native macOS menu-bar app, and native Windows
notification-area app that show the highest active Codex quota percentage. The
menu shows the 5-hour and weekly quotas with local reset times.

| GNOME                                                                                            | macOS                                                                                           | Windows                                                                                                        |
| ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [![CuotaX in the GNOME top panel](.github/screenshots/gnome.png)](.github/screenshots/gnome.png) | [![CuotaX in the macOS menu bar](.github/screenshots/macos.png)](.github/screenshots/macos.png) | [![CuotaX in the Windows notification area](.github/screenshots/windows.png)](.github/screenshots/windows.png) |

Every five minutes and at known reset times, CuotaX reads
`account/rateLimits/read` from the experimental Codex app-server interface using
`codex app-server --stdio`. This does not start a model turn or consume quota.
CuotaX sends a desktop notification when a known 5-hour or weekly quota window
resets.

## Requirements

- Codex CLI, logged in with ChatGPT
- GNOME Shell: GNOME Shell 50, `gnome-extensions`, Node.js, and npm
- macOS: macOS 13 or newer and Swift 6.0 or newer
- Windows: .NET 10 SDK

## Usage

```sh
make install
make uninstall
```

Run `make help` to see all available commands.

## Notes

- GNOME Shell: After the first installation on Wayland, log out and back in,
  then run `make enable`.
- macOS: The app has no Dock icon and registers itself as a login item when it
  launches.
- Windows: The app registers itself to start with Windows when it launches. The
  tray icon shows the highest active quota as a two-digit overlay. Exhausted
  quota is shown as a deep-red `×`, while backend or authentication failures use
  a distinct `!` icon.

The protocol and rate-limit fields are documented in the
[Codex App Server documentation](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).
