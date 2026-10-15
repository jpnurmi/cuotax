# CuotaX

A minimal GNOME Shell extension, native macOS menu-bar app, and native Windows
notification-area app that show Codex or Claude quota usage. The menu shows each
quota with local reset times. Enable either or both providers in the menu.

| GNOME                                                                                            | macOS                                                                                           | Windows                                                                                                        |
| ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [![CuotaX in the GNOME top panel](.github/screenshots/gnome.png)](.github/screenshots/gnome.png) | [![CuotaX in the macOS menu bar](.github/screenshots/macos.png)](.github/screenshots/macos.png) | [![CuotaX in the Windows notification area](.github/screenshots/windows.png)](.github/screenshots/windows.png) |

Usage refreshes every five minutes and at known reset times without consuming
model quota. CuotaX sends desktop notifications when a quota window resets.

## Requirements

- Codex CLI or Claude Code
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
- Windows: The app registers itself to start with Windows when it launches.
