# Task progress widget for Claude (Windows and macOS)

A small floating window that shows what Claude is working on. Each Claude session that's busy gets its own line with the session's title, a bar that fills as Claude works through its task list, and a rough estimate of the time left. A session that needs you (a permission prompt, or a question) turns amber. When a session finishes, its line turns green for a few seconds and then goes away.

![The widget with four made-up sessions: working, waiting for permission, a terminal session, and finished](docs/demo.gif)

> Unofficial. This is a community project and isn't made by, affiliated with, or endorsed by Anthropic. "Claude" is a trademark of Anthropic.

## Status

Early. It works on the computers it was built on and hasn't been tried on many others yet. Terminal Claude Code support is new: it has been tried in real terminal sessions, where the session showed up and finished correctly, but the filling bar and the permission prompt haven't been seen there yet. The Mac version is newer still. It has been tested on one Mac (macOS 26, Apple silicon) and built for Intel Macs too, but it hasn't been tried on an Intel Mac. If something doesn't work on yours, please open an issue and say what you see.

## Requirements

**Windows**

- Windows 10 or 11
- The Claude desktop app (Code tab), or Claude Code in a terminal
- Nothing else if you use the release download. Running from the source code needs Python 3 with tkinter, which the installer from [python.org](https://www.python.org/downloads/) includes with the default options.

**macOS**

- macOS 11 (Big Sur) or later, Apple silicon or Intel
- The Claude desktop app (Code tab), or Claude Code in a terminal
- Nothing else if you use the installer or the release ZIP. Installing from the source code builds the widget on your Mac, which needs Apple's command line tools (`xcode-select --install`). If you have `git`, you most likely have them already.

## Install on Windows

1. Download the Windows ZIP from the [latest release](https://github.com/OhMyGodItIsMe/task-progress-widget/releases/latest) and unzip it anywhere. It includes a ready-made `TaskProgressWidget.exe`, so you don't need Python.
2. Double-click `install.bat`. A console window shows each step and waits for a key press at the end.
3. Fully quit Claude and open it again. Closing the window isn't enough: right-click its icon in the taskbar or system tray and choose Quit. Terminal sessions you start after installing pick it up on their own.

The widget appears in the top-right corner of your main screen. It opens by itself when you sign in to Windows, and there's a **Claude Progress** shortcut on your desktop if you close it.

Windows may warn that the .exe is from an unknown publisher, because it isn't code-signed. Choose "More info", then "Run anyway", or use the source version with Python instead.

## Install on macOS

1. Download `Claude-Progress-….pkg` from the [latest release](https://github.com/OhMyGodItIsMe/task-progress-widget/releases/latest) and double-click it. It's signed and notarized by Apple, so macOS opens it without warnings. Follow the steps; it asks for your Mac password to put the app in Applications.
2. Claude loads the widget's mod when it starts, so if Claude is open, the installer asks whether to restart it now or later. Restarting stops anything Claude is working on at that moment. If you choose Later, fully quit Claude when it suits you (Claude menu > Quit Claude, or Command-Q; closing the window isn't enough) and open it again. Terminal sessions you start after installing pick it up on their own.

The widget appears in the top-right corner of your main screen, on every desktop (Space). It opens by itself when you log in, and macOS may show a "Background Items Added" notice for it. You can turn that off in System Settings > General > Login Items. If you close the widget, open **Claude Progress** from Applications, Launchpad, or Spotlight.

The installer sets Claude up for the person who runs it. Someone else on the same Mac can set it up for themselves by running this in Terminal:

```bash
bash "/Applications/Claude Progress.app/Contents/Resources/setup.sh"
```

**Without the installer.** The release also has a ZIP (`…-mac.zip`), or you can clone this repository; then `install.command` builds the app from source. Run it in Terminal: type `bash `, drag `install.command` into the window, and press Return. It puts the app in `~/Applications`, doesn't need your password, and asks about restarting Claude right there in Terminal. (macOS blocks double-clicking scripts downloaded from the internet, which is why it runs through `bash`.)

Release downloads are signed with a Developer ID and notarized by Apple. A copy built from source is signed only for your own Mac.

## Using it

- Click a line to jump to that session in the Claude app. (Terminal sessions, marked with ›, can't be opened this way.)
- Drag it anywhere to move it. It reopens where you left it.
- To resize it, drag the bottom-right corner. On Windows you can also hold Ctrl and scroll over it. On a Mac you can hold Command (or Control) and scroll, or pinch on a trackpad.
- Right-click it (on a Mac, Control-click works too) for settings: a sound when a session finishes or needs you, the theme (match the system, dark, or light), and resetting its size and position. The menu's last line shows the widget's version and opens this project's page.
- If Claude isn't using a task list for a job (quick questions, for example), the line shows a block sliding back and forth instead of a filling bar. In a terminal, Claude often skips the task list for small jobs, so expect the sliding block more often there.

When Claude controls your computer on Windows, the app minimizes other windows, this one included. The widget comes straight back, and for about a minute it ignores clicks and stays out of screen captures so it can't get in Claude's way. After that it behaves normally again. The Mac version does the same if it's ever hidden while Claude is in control. It never takes the keyboard from the app you're using.

## Uninstall

- **Windows:** double-click `uninstall.bat`, then restart Claude.
- **macOS:** run this in Terminal, then restart Claude. It asks for your Mac password to remove the app from Applications.

  ```bash
  bash "/Applications/Claude Progress.app/Contents/Resources/uninstall.command"
  ```

  If you used `install.command`, the app is in your own Applications folder instead: `bash ~/Applications/Claude\ Progress.app/Contents/Resources/uninstall.command`, or run `uninstall.command` from the folder you installed from.

## What the installer changes

**Windows**

- Copies `task-progress-bar` to `%USERPROFILE%\.claude\mods\task-progress-bar`.
- In `%USERPROFILE%\.claude\settings.json`, sets `CLAUDE_CODE_PLUGIN_DIRS` so the desktop app loads the mod, and adds hooks for terminal Claude Code. Your other settings and hooks are kept, and a backup of the old file is saved next to it first. If `CLAUDE_CODE_PLUGIN_DIRS` already points at a different folder, the installer leaves it alone and tells you what to add. Run `install.ps1 -NoTerminalHooks` to skip the hooks.
- Adds a desktop shortcut and a shortcut in the Windows Startup folder.

**macOS**

- Puts **Claude Progress.app** in `/Applications` (the installer) or `~/Applications` (`install.command`). The app carries everything else below.
- For the person installing, copies the mod, with the terminal hook, to `~/.claude/mods/task-progress-bar`.
- In `~/.claude/settings.json`, sets `CLAUDE_CODE_PLUGIN_DIRS` so the desktop app loads the mod, and adds hooks for terminal Claude Code. Your other settings, hooks, and the order of everything are kept, and a backup of the old file is saved next to it first. If `CLAUDE_CODE_PLUGIN_DIRS` already lists another mod folder, the installer keeps it and adds this one after it. Run `install.command` or `setup.sh` with `--no-terminal-hooks` to skip the hooks.
- Adds a launch agent, `~/Library/LaunchAgents/io.github.ohmygoditisme.claude-progress.plist`, which opens the widget when you log in. It also reopens the widget if it ever crashes. Closing it yourself keeps it closed. Run `install.command` or `setup.sh` with `--no-login-item` to skip it.

## How it works

There are three parts:

- **The mod** (`task-progress-bar/hooks/register.tsx`) runs inside the Claude desktop app, on Windows and macOS alike. It watches Claude's task-list updates and permission prompts, and writes a small JSON file per session to `~/.claude/task-progress`, refreshed about once a second while a turn is running.
- **The terminal hook** does the same for Claude Code in a terminal: `task-progress-bar/cli/progress-hook.ps1` on Windows, and `progress-hook` (built from `progress-hook.swift`) on macOS. Claude Code runs it in the background on events such as a new prompt, a task created or completed, a permission prompt, and the end of a turn. Desktop sessions are skipped there, since the mod covers them.
- **The widget** reads those files and draws one line per session. On Windows it's a tkinter window (`task-progress-bar/widget/progress_widget.py`, shipped as `TaskProgressWidget.exe`). On macOS it's a native app (`task-progress-bar/widget/ProgressWidget.swift`, shipped as `Claude Progress.app`). Both follow the same rules and look the same.

Session titles and the links for opening a session come from the Claude app's own session files. Those aren't a public format, so a future app update could change them. If that happens, lines fall back to the start of the message you sent, and clicking a line does nothing.

To build the release ZIPs yourself:

- **Windows:** install PyInstaller (`python -m pip install --user pyinstaller`) and run `make-release.ps1`.
- **macOS:** run `./make-release-mac.sh` for the installer (`.pkg`) and the ZIP. It needs Apple's command line tools. Add `--notarize <profile>` to sign them with your Developer ID Application and Installer certificates and have Apple notarize them; `<profile>` is a keychain profile made once with `xcrun notarytool store-credentials`. `mac/build.sh` alone builds the app for just your Mac, into `build/mac`.

## License

MIT. See [LICENSE](LICENSE).
