# PowerShellFN

The first ever **100% PowerShell** (OGFN) OG Fortnite launcher. No compiled EXEs, no external dependencies — just `.ps1` scripts.

Both a CLI and GUI version are included. Same features, same injection engine, pick your style.

## Features

- **Client Launch** — full Fortnite client with fake EAC (suspended companion processes), log-based login detection, automatic DLL injection
- **Host (GameServer)** — headless game server launch (`-nullrhi -nosplash -nosound`) with separate account support
- **Build Management** — add/remove Fortnite builds, auto-detect version and CL from folder names
- **DLL Injection** — embedded C# P/Invoke injector (CreateRemoteThread + LoadLibraryA), no external tools needed
- **DLL Downloader** — auto-downloads Tellurium (auth), ErbiumClient, and ErbiumGS from upstream
- **Account System** — separate client and host accounts, stored locally
- **Backend Settings** — configurable backend host/port, embedded backend support (start/stop), connection testing
- **Settings Persistence** — JSON config at `%APPDATA%\PowerShellFN\`

## Versions

### CLI (`Launcher\Launcher.ps1`)
Classic terminal-based launcher with colored output, arrow-key-free numbered menus, and ASCII banner.

### GUI (`Launcher\Launcher GUI.ps1`)
WPF-based dark theme GUI built entirely in PowerShell using `PresentationFramework`. Same engine under the hood.

## How to Run

1. Right-click `Launcher.ps1` or `Launcher GUI.ps1` > **Run with PowerShell**
2. Or double-click (if execution policy allows)
3. On first run, DLLs are downloaded automatically

> Requires Windows PowerShell 5.1. If launched under PowerShell 7+, it auto-relaunches under 5.1.

## File Structure

```
PowerShellFN/
  Launcher/
    Launcher.ps1          # CLI version
    Launcher GUI.ps1      # GUI version (WPF)
    Launch.bat            # Quick launcher shortcut
    LauncherIcon.ico      # Window icon
  Readme.md
```

## Data Files

All stored in `%APPDATA%\PowerShellFN\`:

| File | Purpose |
|------|---------|
| `builds.txt` | Registered builds (pipe-delimited) |
| `account.txt` | Client email + password |
| `host_account.txt` | Host/GS email + password |
| `settings.json` | Backend mode, host, port, etc. |
| `dlls/` | Cached DLLs (Tellurium, ErbiumClient, ErbiumGS) |

## Credits

Made by **Ducki67**
