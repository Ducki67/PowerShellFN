<#
    PowerShellFN Launcher - The first ever 100% PowerShell OGFN Launcher
    Made by Ducki67

    Features:
    - Full CLI menu system (RebooterV2 style)
    - Build management (add/list/remove with auto-detection)
    - Account management (email/password)
    - DLL injection via embedded C# P/Invoke
    - DLL downloader (Tellurium, ErbiumClient)
    - Client launch with stdout login detection
    - Backend settings (local/embedded)
    - Configurations system
    - Settings persistence (JSON)

    100% single-file. No external EXE or DLL for logic.
    Right-click > Run with PowerShell, or double-click to launch.
#>

# ============================================================================
# SELF-LAUNCHER: Makes the .ps1 runnable directly (handles execution policy)
# ============================================================================

# If execution policy is blocking us, relaunch with bypass
if ($MyInvocation.Line -notmatch '-ExecutionPolicy') {
    $relaunch = $false

    # Check if we're running with restricted policy
    try {
        $policy = Get-ExecutionPolicy -Scope Process
        if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') { $relaunch = $true }
    } catch { $relaunch = $true }

    if ($relaunch) {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
}

# Force Windows PowerShell 5.1 (PS7 has no WPF, and quirks with Add-Type)
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# Keep window open on crash so user can read errors
$ErrorActionPreference = "Stop"
trap {
    Write-Host "`n[FATAL] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Read-Host "`nPress Enter to exit"
    exit 1
}

# Prevent window from closing when script ends normally
$Host.UI.RawUI.WindowTitle = "PowerShellFN Launcher"

# ============================================================================
# EMBEDDED C# INJECTOR ENGINE
# ============================================================================

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Runtime.InteropServices;

public class PSFNInjector
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint a, bool b, uint c);
    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    static extern IntPtr VirtualAllocEx(IntPtr a, IntPtr b, uint c, uint d, uint e);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteProcessMemory(IntPtr a, IntPtr b, byte[] c, uint d, out UIntPtr e);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateRemoteThread(IntPtr a, IntPtr b, uint c, IntPtr d, IntPtr e, uint f, out uint g);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr h, string n);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)] static extern IntPtr GetModuleHandle(string n);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);

    // Thread suspension APIs (for fake EAC)
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);
    [DllImport("kernel32.dll")]
    static extern bool Thread32First(IntPtr hSnapshot, ref THREADENTRY32 lpte);
    [DllImport("kernel32.dll")]
    static extern bool Thread32Next(IntPtr hSnapshot, ref THREADENTRY32 lpte);
    [DllImport("kernel32.dll")]
    static extern IntPtr OpenThread(uint dwDesiredAccess, bool bInheritHandle, uint dwThreadId);
    [DllImport("kernel32.dll")]
    static extern uint SuspendThread(IntPtr hThread);

    [StructLayout(LayoutKind.Sequential)]
    struct THREADENTRY32
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ThreadID;
        public uint th32OwnerProcessID;
        public int tpBasePri;
        public int tpDeltaPri;
        public uint dwFlags;
    }

    const uint TH32CS_SNAPTHREAD = 0x00000004;
    const uint THREAD_SUSPEND_RESUME = 0x0002;

    // Spawn a process and immediately suspend all its threads (fake EAC/launcher)
    public static int SpawnSuspended(string exePath, string args)
    {
        if (!File.Exists(exePath)) return 0;
        var psi = new ProcessStartInfo
        {
            FileName = exePath,
            Arguments = args ?? "",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(exePath) ?? ""
        };
        var proc = Process.Start(psi);
        if (proc == null || proc.HasExited) return 0;
        int pid = proc.Id;

        // Suspend all threads
        IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snap != IntPtr.Zero)
        {
            THREADENTRY32 te = new THREADENTRY32();
            te.dwSize = (uint)Marshal.SizeOf(typeof(THREADENTRY32));
            if (Thread32First(snap, ref te))
            {
                do
                {
                    if (te.th32OwnerProcessID == (uint)pid)
                    {
                        IntPtr hThread = OpenThread(THREAD_SUSPEND_RESUME, false, te.th32ThreadID);
                        if (hThread != IntPtr.Zero)
                        {
                            SuspendThread(hThread);
                            CloseHandle(hThread);
                        }
                    }
                } while (Thread32Next(snap, ref te));
            }
            CloseHandle(snap);
        }
        proc.Dispose();
        return pid;
    }

    public static string Inject(uint processId, string dllPath)
    {
        if (!File.Exists(dllPath))
            return "FAIL: File not found: " + dllPath;

        IntPtr hProc = OpenProcess(0x1F0FFF, false, processId);
        if (hProc == IntPtr.Zero)
            return "FAIL: OpenProcess error " + Marshal.GetLastWin32Error();

        byte[] bytes = Encoding.ASCII.GetBytes(dllPath + "\0");
        IntPtr mem = VirtualAllocEx(hProc, IntPtr.Zero, (uint)bytes.Length, 0x3000, 0x04);
        if (mem == IntPtr.Zero) { CloseHandle(hProc); return "FAIL: VirtualAllocEx error " + Marshal.GetLastWin32Error(); }

        UIntPtr written;
        if (!WriteProcessMemory(hProc, mem, bytes, (uint)bytes.Length, out written))
        { CloseHandle(hProc); return "FAIL: WriteProcessMemory error " + Marshal.GetLastWin32Error(); }

        IntPtr loadLib = GetProcAddress(GetModuleHandle("kernel32.dll"), "LoadLibraryA");
        if (loadLib == IntPtr.Zero) { CloseHandle(hProc); return "FAIL: LoadLibraryA not found"; }

        uint tid;
        IntPtr hThread = CreateRemoteThread(hProc, IntPtr.Zero, 0, loadLib, mem, 0, out tid);
        if (hThread == IntPtr.Zero) { CloseHandle(hProc); return "FAIL: CreateRemoteThread error " + Marshal.GetLastWin32Error(); }

        WaitForSingleObject(hThread, 10000);
        CloseHandle(hThread);
        CloseHandle(hProc);
        return "OK";
    }

    public static string InjectWithRetry(uint processId, string dllPath, int retries, int intervalMs)
    {
        for (int i = 0; i < retries; i++)
        {
            string result = Inject(processId, dllPath);
            if (result == "OK") return "OK";
            Thread.Sleep(intervalMs);
        }
        return "FAIL: Max retries exceeded";
    }
}
"@ -Language CSharp -ErrorAction Stop

# ============================================================================
# PATHS & APPDATA
# ============================================================================

$script:AppData = Join-Path $env:APPDATA "PowerShellFN"
$script:BuildsFile = Join-Path $script:AppData "builds.txt"
$script:AccountFile = Join-Path $script:AppData "account.txt"
$script:HostAccountFile = Join-Path $script:AppData "host_account.txt"
$script:SettingsFile = Join-Path $script:AppData "settings.json"
$script:DLLFolder = Join-Path $script:AppData "dlls"

if (-not (Test-Path $script:AppData)) { New-Item -Path $script:AppData -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $script:DLLFolder)) { New-Item -Path $script:DLLFolder -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $script:BuildsFile)) { New-Item -Path $script:BuildsFile -ItemType File -Force | Out-Null }

# ============================================================================
# DLL URLS (placeholder - user will provide final links)
# ============================================================================

$script:DLLUrls = @{
    "Tellurium.dll"    = "http://r2.ploosh.dev/Tellurium.dll"
    "ErbiumClient.dll" = "https://nightly.link/plooshi/Erbium/workflows/Build/main/ErbiumClient.zip"
    "ErbiumGS.dll"     = "https://nightly.link/plooshi/Erbium/workflows/Build/main/Erbium.zip"
}

# ============================================================================
# SETTINGS (JSON persistence)
# ============================================================================

$script:DefaultSettings = @{
    BackendMode    = "local"        # local or embedded
    BackendHost    = "127.0.0.1"
    BackendPort    = 3551
    EmbeddedCmd    = ""
    EmbeddedWorkDir = ""
    EmbeddedVisible = $false
    LastBuild      = ""
}

$script:Settings = @{}

function Load-Settings {
    if (Test-Path $script:SettingsFile) {
        try {
            $json = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            $script:Settings = @{}
            foreach ($key in $script:DefaultSettings.Keys) {
                $val = $json.PSObject.Properties[$key]
                if ($val) { $script:Settings[$key] = $val.Value }
                else { $script:Settings[$key] = $script:DefaultSettings[$key] }
            }
        } catch {
            $script:Settings = $script:DefaultSettings.Clone()
        }
    } else {
        $script:Settings = $script:DefaultSettings.Clone()
    }
}

function Save-Settings {
    $script:Settings | ConvertTo-Json -Depth 5 | Set-Content $script:SettingsFile -Encoding UTF8
}

# ============================================================================
# LOGGER
# ============================================================================

function Log-Info([string]$msg)    { Write-Host "  [" -NoNewline -ForegroundColor DarkGray; Write-Host "*" -NoNewline -ForegroundColor Cyan; Write-Host "] " -NoNewline -ForegroundColor DarkGray; Write-Host $msg -ForegroundColor White }
function Log-Success([string]$msg) { Write-Host "  [" -NoNewline -ForegroundColor DarkGray; Write-Host "+" -NoNewline -ForegroundColor Green; Write-Host "] " -NoNewline -ForegroundColor DarkGray; Write-Host $msg -ForegroundColor Green }
function Log-Warn([string]$msg)    { Write-Host "  [" -NoNewline -ForegroundColor DarkGray; Write-Host "~" -NoNewline -ForegroundColor Yellow; Write-Host "] " -NoNewline -ForegroundColor DarkGray; Write-Host $msg -ForegroundColor Yellow }
function Log-Error([string]$msg)   { Write-Host "  [" -NoNewline -ForegroundColor DarkGray; Write-Host "-" -NoNewline -ForegroundColor Red; Write-Host "] " -NoNewline -ForegroundColor DarkGray; Write-Host $msg -ForegroundColor Red }
function Log-Debug([string]$msg)   { Write-Host "  [" -NoNewline -ForegroundColor DarkGray; Write-Host "?" -NoNewline -ForegroundColor DarkCyan; Write-Host "] " -NoNewline -ForegroundColor DarkGray; Write-Host $msg -ForegroundColor DarkGray }
function Log-Blank { Write-Host "" }

function Draw-Line([string]$color = "DarkGray") {
    Write-Host "  $("=" * 56)" -ForegroundColor $color
}

function Draw-Header([string]$title) {
    Write-Host ""
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "  $("-" * $title.Length)" -ForegroundColor DarkCyan
    Write-Host ""
}

function Draw-MenuItem([string]$key, [string]$label, [string]$hint = "") {
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "$key" -NoNewline -ForegroundColor Cyan
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host "$label" -NoNewline -ForegroundColor White
    if ($hint) { Write-Host " $hint" -ForegroundColor DarkGray } else { Write-Host "" }
}

function Draw-MenuBack([string]$key = "0") {
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "$key" -NoNewline -ForegroundColor DarkYellow
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host "Back" -ForegroundColor DarkGray
}

function Draw-Prompt {
    Write-Host ""
    Write-Host "  > " -NoNewline -ForegroundColor Magenta
}

# ============================================================================
# BANNER
# ============================================================================

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ____                        ____  _          _ _ _____ _   _ " -ForegroundColor Blue
    Write-Host " |  _ \ _____      _____ _ __/ ___|| |__   ___| | |  ___| \ | |" -ForegroundColor Blue
    Write-Host " | |_) / _ \ \ /\ / / _ \ '__\___ \| '_ \ / _ \ | | |_  |  \| |" -ForegroundColor DarkCyan
    Write-Host " |  __/ (_) \ V  V /  __/ |   ___) | | | |  __/ | |  _| | |\  |" -ForegroundColor Cyan
    Write-Host " |_|   \___/ \_/\_/ \___|_|  |____/|_| |_|\___|_|_|_|   |_| \_|" -ForegroundColor White
    Write-Host ""
    Write-Host "         The first ever " -NoNewline -ForegroundColor DarkGray
    Write-Host "100% PowerShell" -NoNewline -ForegroundColor Cyan
    Write-Host " OGFN Launcher" -ForegroundColor DarkGray
    Write-Host "                    Made by " -NoNewline -ForegroundColor DarkGray
    Write-Host "Ducki67 (@ducki67 on discord)" -ForegroundColor Magenta
    Write-Host ""
    Draw-Line "DarkCyan"
    Write-Host ""
}

# ============================================================================
# BUILD DETECTION (CL / UE version from build files)
# ============================================================================

function Detect-BuildInfo([string]$fortnitePath) {
    $build = "Unknown"
    $cl = "Unknown"

    # First try: extract from folder name (most reliable for OGFN builds)
    # Patterns: "28.30-CL-31511038", "9.00", "4.5.1-CL-4166199", "4.5-CL-4166199"
    $folderName = Split-Path $fortnitePath -Leaf
    # Also check parent folder in case selected subfolder
    $parentName = Split-Path (Split-Path $fortnitePath -Parent) -Leaf

    foreach ($name in @($folderName, $parentName)) {
        # Match version like 28.30, 9.00, 4.5.1, etc.
        if ($name -match '(\d+\.\d+(?:\.\d+)?)') {
            $build = $Matches[1]
        }
        # Match CL from folder name like "-CL-31511038"
        if ($name -match 'CL[- ](\d+)') {
            $cl = $Matches[1]
        }
        if ($build -ne "Unknown") { break }
    }

    # Fallback: get CL from Build.version if not found in folder name
    if ($cl -eq "Unknown") {
        $versionFiles = @(
            (Join-Path $fortnitePath "FortniteGame\Build.version"),
            (Join-Path $fortnitePath "Engine\Build\Build.version")
        )
        foreach ($vf in $versionFiles) {
            if (Test-Path $vf) {
                $txt = Get-Content $vf -Raw -ErrorAction SilentlyContinue
                if ($txt -and $txt -match 'Changelist"?\s*[:=]\s*(\d+)') {
                    $cl = $Matches[1]
                    break
                }
            }
        }
    }

    return @{ Build = $build; CL = $cl }
}

# ============================================================================
# BUILD MANAGEMENT
# ============================================================================

function Get-Builds {
    if (-not (Test-Path $script:BuildsFile)) { return @() }
    $lines = @(Get-Content $script:BuildsFile | Where-Object { $_ -match '\|' })
    if ($lines.Count -eq 0) { return @() }

    [System.Collections.ArrayList]$builds = @()
    foreach ($line in $lines) {
        $parts = $line.Split('|')
        [void]$builds.Add([PSCustomObject]@{
            Name    = $parts[0]
            Path    = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            Version = if ($parts.Count -gt 2) { $parts[2] } else { "?" }
            CL      = if ($parts.Count -gt 3) { $parts[3] } else { "?" }
        })
    }
    return @($builds)
}

function Find-GameExe([string]$rootPath) {
    $exeName = "FortniteClient-Win64-Shipping.exe"

    # Direct
    $direct = Join-Path $rootPath $exeName
    if (Test-Path $direct) { return $direct }

    # Standard subfolder
    $standard = Join-Path $rootPath "FortniteGame\Binaries\Win64\$exeName"
    if (Test-Path $standard) { return $standard }

    # Recursive (max 5 levels)
    $found = Get-ChildItem -Path $rootPath -Filter $exeName -Recurse -Depth 5 -EA SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }

    return $null
}

function Menu-AddBuild {
    Show-Banner
    Draw-Header "Add Build"

    # Use folder browser instead of typing paths
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select your Fortnite build folder"
    $dialog.ShowNewFolderButton = $false

    Log-Info "Opening folder picker..."
    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Log-Warn "Cancelled."
        Start-Sleep 1
        return
    }

    $path = $dialog.SelectedPath
    Log-Info "Selected: $path"

    # Find the exe
    $exePath = Find-GameExe $path
    if (-not $exePath) {
        Log-Error "Could not find FortniteClient-Win64-Shipping.exe in that folder."
        Log-Debug "Searched root, FortniteGame\Binaries\Win64\, and 5 levels deep."
        Start-Sleep 2
        return
    }
    Log-Success "Found exe: $exePath"

    # Check for duplicates
    $existing = Get-Builds
    foreach ($b in $existing) {
        if ($b.Path -eq $path) {
            Log-Warn "This path is already added as '$($b.Name)'."
            Start-Sleep 1
            return
        }
    }

    # Detect build info
    $info = Detect-BuildInfo $path
    Log-Info "Detected: Build $($info.Build) | CL-$($info.CL)"

    # Auto-generate name from folder, let user override
    $folderName = Split-Path $path -Leaf
    $autoName = "Fortnite $folderName"
    Write-Host "  Build name [$autoName]: " -NoNewline -ForegroundColor White
    $name = Read-Host
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $autoName }

    # Save
    $entry = "$name|$path|$($info.Build)|$($info.CL)"
    Add-Content -Path $script:BuildsFile -Value $entry -Encoding UTF8
    Log-Success "Build '$name' added!"
    Start-Sleep 1
}

function Menu-ListBuilds {
    $builds = Get-Builds
    if ($builds.Count -eq 0) {
        Log-Warn "No builds found. Use 'Add Build' first."
        return $null
    }

    Log-Blank
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $b = $builds[$i]
        Write-Host "  [" -NoNewline -ForegroundColor DarkGray
        Write-Host "$($i+1)" -NoNewline -ForegroundColor Cyan
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($b.Name) " -NoNewline -ForegroundColor White
        Write-Host "(" -NoNewline -ForegroundColor DarkGray
        Write-Host "v$($b.Version)" -NoNewline -ForegroundColor DarkCyan
        Write-Host " | " -NoNewline -ForegroundColor DarkGray
        Write-Host "CL-$($b.CL)" -NoNewline -ForegroundColor DarkCyan
        Write-Host ")" -ForegroundColor DarkGray
    }
    Log-Blank
    return $builds
}

function Menu-RemoveBuild {
    Show-Banner
    Draw-Header "Remove Build"

    $builds = Menu-ListBuilds
    if (-not $builds) { Start-Sleep 1; return }

    Write-Host "  Select build to remove (" -NoNewline -ForegroundColor DarkGray
    Write-Host "0" -NoNewline -ForegroundColor DarkYellow
    Write-Host " = back): " -NoNewline -ForegroundColor DarkGray
    $choice = Read-Host
    if ($choice -eq "0" -or [string]::IsNullOrWhiteSpace($choice)) { return }

    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $builds.Count) { Log-Error "Invalid."; Start-Sleep 1; return }

    $removed = $builds[$idx]
    $lines = Get-Content $script:BuildsFile | Where-Object { $_ -match '\|' }
    $newLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -ne $idx) { $newLines += $lines[$i] }
    }
    Set-Content -Path $script:BuildsFile -Value $newLines -Encoding UTF8
    Log-Success "Removed '$($removed.Name)'."
    Start-Sleep 1
}

function Select-Build {
    $builds = Menu-ListBuilds
    if (-not $builds) { Start-Sleep 1; return $null }

    Write-Host "  Select build (" -NoNewline -ForegroundColor DarkGray
    Write-Host "0" -NoNewline -ForegroundColor DarkYellow
    Write-Host " = back): " -NoNewline -ForegroundColor DarkGray
    $choice = Read-Host
    if ($choice -eq "0" -or [string]::IsNullOrWhiteSpace($choice)) { return $null }

    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $builds.Count) { Log-Error "Invalid."; Start-Sleep 1; return $null }

    return $builds[$idx]
}

# ============================================================================
# ACCOUNT MANAGEMENT
# ============================================================================

function Get-Account {
    if (-not (Test-Path $script:AccountFile)) { return $null }
    $lines = Get-Content $script:AccountFile -EA SilentlyContinue
    if ($lines.Count -lt 1) { return $null }
    return @{
        Email    = $lines[0]
        Password = if ($lines.Count -gt 1) { $lines[1] } else { "" }
    }
}

function Get-HostAccount {
    if (-not (Test-Path $script:HostAccountFile)) { return $null }
    $lines = Get-Content $script:HostAccountFile -EA SilentlyContinue
    if ($lines.Count -lt 1) { return $null }
    return @{
        Email    = $lines[0]
        Password = if ($lines.Count -gt 1) { $lines[1] } else { "" }
    }
}

function Menu-Account {
    Show-Banner
    Draw-Header "Account Settings"

    $acc = Get-Account
    $hostAcc = Get-HostAccount
    Write-Host "  Client:  " -NoNewline -ForegroundColor DarkGray
    if ($acc) { Write-Host "$($acc.Email)" -ForegroundColor Green }
    else { Write-Host "Not set" -ForegroundColor Red }
    Write-Host "  Host:    " -NoNewline -ForegroundColor DarkGray
    if ($hostAcc) { Write-Host "$($hostAcc.Email)" -ForegroundColor Yellow }
    else { Write-Host "Not set" -ForegroundColor Red }
    Log-Blank

    Draw-MenuItem "1" "Set Client Account"
    Draw-MenuItem "2" "Set Host Account"
    Draw-MenuItem "3" "Clear Client Account"
    Draw-MenuItem "4" "Clear Host Account"
    Draw-MenuBack
    Draw-Prompt
    $opt = Read-Host

    switch ($opt) {
        "1" {
            Log-Blank
            while ($true) {
                Write-Host "  Enter E-Mail: " -NoNewline -ForegroundColor Cyan
                $email = Read-Host
                if ($email -match '@') { break }
                Log-Error "Invalid email."
            }
            Write-Host "  Enter Password: " -NoNewline -ForegroundColor Cyan
            $pass = Read-Host
            Set-Content -Path $script:AccountFile -Value @($email, $pass) -Encoding UTF8
            Log-Success "Client account saved!"
            Start-Sleep 1
        }
        "2" {
            Log-Blank
            while ($true) {
                Write-Host "  Enter Host E-Mail: " -NoNewline -ForegroundColor Cyan
                $email = Read-Host
                if ($email -match '@') { break }
                Log-Error "Invalid email."
            }
            Write-Host "  Enter Host Password: " -NoNewline -ForegroundColor Cyan
            $pass = Read-Host
            Set-Content -Path $script:HostAccountFile -Value @($email, $pass) -Encoding UTF8
            Log-Success "Host account saved!"
            Start-Sleep 1
        }
        "3" {
            if (Test-Path $script:AccountFile) { Remove-Item $script:AccountFile -Force }
            Log-Success "Client account cleared."
            Start-Sleep 1
        }
        "4" {
            if (Test-Path $script:HostAccountFile) { Remove-Item $script:HostAccountFile -Force }
            Log-Success "Host account cleared."
            Start-Sleep 1
        }
    }
}

# ============================================================================
# DLL MANAGEMENT
# ============================================================================

function Download-DLL([string]$url, [string]$destPath, [string]$name) {
    if ([string]::IsNullOrEmpty($url)) {
        Log-Warn "$name - No URL configured."
        return $false
    }
    if (Test-Path $destPath) {
        Log-Info "$name already present."
        return $true
    }

    Log-Info "Downloading $name..."
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $isZip = $url -match '\.zip$'

        if ($isZip) {
            # Download zip, extract DLL
            $tempZip = Join-Path $env:TEMP "psfn_$([guid]::NewGuid()).zip"
            (New-Object System.Net.WebClient).DownloadFile($url, $tempZip)

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
            $entry = $zip.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $entry) { $entry = $zip.Entries | Where-Object { $_.Name -like "*.dll" } | Select-Object -First 1 }

            if ($entry) {
                $stream = $entry.Open()
                $fs = [System.IO.File]::Create($destPath)
                $stream.CopyTo($fs)
                $fs.Close()
                $stream.Close()
            }
            $zip.Dispose()
            Remove-Item $tempZip -Force -EA SilentlyContinue
        } else {
            (New-Object System.Net.WebClient).DownloadFile($url, $destPath)
        }

        if (Test-Path $destPath) {
            Log-Success "$name downloaded."
            return $true
        }
        Log-Error "$name download failed."
        return $false
    } catch {
        Log-Error "$name download failed: $_"
        return $false
    }
}

function Menu-UpdateDLLs {
    Show-Banner
    Draw-Header "Update DLLs"

    foreach ($dll in $script:DLLUrls.Keys) {
        $dest = Join-Path $script:DLLFolder $dll
        Download-DLL $script:DLLUrls[$dll] $dest $dll | Out-Null
    }

    Log-Blank
    Log-Success "DLL check complete."
    Start-Sleep 1
}

function Menu-RedownloadDLLs {
    Show-Banner
    Draw-Header "Re-Download DLLs (force)"

    # Delete existing
    Get-ChildItem $script:DLLFolder -Filter "*.dll" -EA SilentlyContinue | Remove-Item -Force
    Log-Info "Cleared old DLLs."

    foreach ($dll in $script:DLLUrls.Keys) {
        $dest = Join-Path $script:DLLFolder $dll
        Download-DLL $script:DLLUrls[$dll] $dest $dll | Out-Null
    }

    Log-Blank
    Log-Success "All DLLs re-downloaded."
    Start-Sleep 1
}

function Menu-ViewDLLs {
    Show-Banner
    Draw-Header "DLL Status"

    foreach ($dll in $script:DLLUrls.Keys) {
        $dest = Join-Path $script:DLLFolder $dll
        if (Test-Path $dest) {
            $size = [math]::Round((Get-Item $dest).Length / 1KB, 1)
            Write-Host "  [" -NoNewline -ForegroundColor DarkGray
            Write-Host "OK" -NoNewline -ForegroundColor Green
            Write-Host "] " -NoNewline -ForegroundColor DarkGray
            Write-Host "$dll " -NoNewline -ForegroundColor White
            Write-Host "($($size) KB)" -ForegroundColor DarkCyan
        } else {
            Write-Host "  [" -NoNewline -ForegroundColor DarkGray
            Write-Host "!!" -NoNewline -ForegroundColor Red
            Write-Host "] " -NoNewline -ForegroundColor DarkGray
            Write-Host "$dll " -NoNewline -ForegroundColor White
            Write-Host "MISSING" -ForegroundColor Red
        }
    }
    Log-Blank
    Write-Host "  Press Enter to continue..." -NoNewline -ForegroundColor DarkGray
    Read-Host
}

# ============================================================================
# PROCESS MANAGEMENT
# ============================================================================

$script:GameProcess = $null
$script:ClientPid = 0
$script:ClientCompanionPids = @()
$script:GSPid = 0

function Kill-Fortnite {
    param(
        [string]$Spare = "none"  # "client", "gs", or "none" (kill all)
    )

    Log-Info "Killing Fortnite processes..."
    $killed = 0

    # Collect PIDs to spare
    $sparePids = @()
    if ($Spare -eq "client" -and $script:ClientPid -gt 0) {
        $sparePids += $script:ClientPid
        $sparePids += $script:ClientCompanionPids
    }
    if ($Spare -eq "gs" -and $script:GSPid -gt 0) {
        $sparePids += $script:GSPid
    }

    @("FortniteClient-Win64-Shipping", "FortniteLauncher", "FortniteClient-Win64-Shipping_EAC", "FortniteClient-Win64-Shipping_BE") | ForEach-Object {
        Get-Process -Name $_ -EA SilentlyContinue | ForEach-Object {
            if ($sparePids -notcontains $_.Id) {
                try { $_.Kill(); $killed++ } catch {}
            }
        }
    }

    # Clear tracked PIDs for killed instances
    if ($Spare -ne "client") {
        $script:ClientPid = 0
        $script:ClientCompanionPids = @()
    }
    if ($Spare -ne "gs") {
        $script:GSPid = 0
    }
    $script:GameProcess = $null
    if ($killed -gt 0) { Log-Success "Killed $killed process(es)." }
    else { Log-Success "Done." }
}

function Launch-Client {
    param(
        $Build,
        $Account
    )

    $exePath = Find-GameExe $Build.Path
    if (-not $exePath) {
        Log-Error "Game exe not found in: $($Build.Path)"
        return $false
    }
    $exeDir = [System.IO.Path]::GetDirectoryName($exePath)

    # Kill stale client processes (spare GS if running)
    Kill-Fortnite -Spare "gs"

    # Spawn companion processes SUSPENDED (fake EAC - same as RebooterV2)
    $companionPids = @()
    $launcherExe = Join-Path $exeDir "FortniteLauncher.exe"
    $eacExe = Join-Path $exeDir "FortniteClient-Win64-Shipping_EAC.exe"

    $launcherArgs = "-epicapp=Fortnite -epicenv=Prod -epiclocale=en-us -epicportal -noeac -fromfl=be -fltoken=h1cdhchd10150221h130eB56 -skippatchcheck"

    if (Test-Path $launcherExe) {
        $lpid = [PSFNInjector]::SpawnSuspended($launcherExe, $launcherArgs)
        if ($lpid -gt 0) { Log-Debug "FortniteLauncher spawned suspended (PID: $lpid)"; $companionPids += $lpid }
        else { Log-Debug "FortniteLauncher not spawned." }
    }
    if (Test-Path $eacExe) {
        $epid = [PSFNInjector]::SpawnSuspended($eacExe, "")
        if ($epid -gt 0) { Log-Debug "EAC stub spawned suspended (PID: $epid)"; $companionPids += $epid }
        else { Log-Debug "EAC stub not spawned." }
    }

    # Build launch arguments (no EAC, no BE)
    $launchArgs = @(
        "-epicapp=Fortnite",
        "-epicenv=Prod",
        "-epiclocale=en-us",
        "-epicportal",
        "-skippatchcheck",
        "-nobe",
        "-dx11",
        "-fromfl=eac",
        "-fltoken=3db3ba5dcbd2e16703f3978d",
        "-AUTH_TYPE=epic",
        "-AUTH_LOGIN=$($Account.Email)",
        "-AUTH_PASSWORD=$($Account.Password)"
    ) -join " "

    # Launch game
    Log-Info "Starting FortniteClient-Win64-Shipping.exe..."
    Log-Debug "Args: -epicapp=Fortnite ... -AUTH_LOGIN=$($Account.Email)"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = $launchArgs
    $psi.WorkingDirectory = $exeDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.EnvironmentVariables["OPENSSL_ia32cap"] = "~0x20000000"

    $script:GameProcess = [System.Diagnostics.Process]::Start($psi)
    $gamePid = $script:GameProcess.Id
    $script:ClientPid = $gamePid
    $script:ClientCompanionPids = $companionPids
    Log-Success "Fortnite started (PID: $gamePid)"

    # Inject Auth DLL (Tellurium) immediately with retries
    $tellPath = Join-Path $script:DLLFolder "Tellurium.dll"
    if (Test-Path $tellPath) {
        Log-Info "Injecting Tellurium.dll (auth)..."
        $r = [PSFNInjector]::InjectWithRetry([uint32]$gamePid, $tellPath, 30, 500)
        if ($r -eq "OK") { Log-Success "Tellurium.dll injected." }
        else { Log-Error "Tellurium.dll: $r" }
    } else { Log-Warn "Tellurium.dll not found - skipping auth injection." }

    # Monitor game log file for login + lobby load
    $logFile = Join-Path $env:LOCALAPPDATA "FortniteGame\Saved\Logs\FortniteGame.log"
    $lastPos = 0

    # Wait for log file to appear (game takes a moment to create it)
    $logWait = [System.Diagnostics.Stopwatch]::StartNew()
    while ($logWait.Elapsed.TotalSeconds -lt 15 -and -not (Test-Path $logFile)) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path $logFile) { $lastPos = (Get-Item $logFile).Length }

    # Helper to read new log lines
    function Read-NewLog {
        if (-not (Test-Path $logFile)) { return "" }
        $currentSize = (Get-Item $logFile).Length
        if ($currentSize -le $script:_logPos) { return "" }
        try {
            $fs = [System.IO.FileStream]::new($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $fs.Position = $script:_logPos
            $reader = New-Object System.IO.StreamReader($fs)
            $text = $reader.ReadToEnd()
            $reader.Close()
            $fs.Close()
            $script:_logPos = $currentSize
            return $text
        } catch { return "" }
    }
    $script:_logPos = $lastPos

    # Step 1: Wait for login (120s timeout)
    Log-Info "Waiting for login (120s timeout)..."
    $loginOk = $false
    $loginError = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $loginTriggers = @("LogOnlineAccount", "ContinueLoggingIn")
    $errorTriggers = @("port 3551 failed", "Unable to login", "HTTP 400", "Login failed", "ForceLogout")

    while ($sw.Elapsed.TotalSeconds -lt 120 -and -not $loginOk -and -not $loginError) {
        if ($script:GameProcess.HasExited) {
            Log-Error "Game exited during login."
            return $false
        }

        $newText = Read-NewLog
        if ($newText) {
            # Check login (look for the completed login line)
            if ($newText -match 'ContinueLoggingIn.*Completed') {
                $loginOk = $true
                break
            }
            foreach ($e in $errorTriggers) {
                if ($newText -like "*$e*") { $loginError = $true; Log-Error "Login error: $e"; break }
            }
        }

        if (-not $loginOk -and -not $loginError) { Start-Sleep -Milliseconds 500 }
    }

    if ($loginOk) { Log-Success "Login successful!" }
    elseif ($loginError) { Log-Warn "Login error - continuing anyway..." }
    else { Log-Warn "Login timeout - injecting remaining DLLs anyway..." }

    # Inject ErbiumClient.dll (console) - immediately after login, same as RebooterV2
    $erbPath = Join-Path $script:DLLFolder "ErbiumClient.dll"
    if (Test-Path $erbPath) {
        Log-Info "Injecting ErbiumClient.dll (console)..."
        $r = [PSFNInjector]::Inject([uint32]$gamePid, $erbPath)
        if ($r -eq "OK") { Log-Success "ErbiumClient.dll injected." }
        else { Log-Error "ErbiumClient.dll: $r" }
    } else { Log-Warn "ErbiumClient.dll not found - skipping." }

    return $true
}

# ============================================================================
# GAME SERVER LAUNCH (HOST)
# ============================================================================

function Launch-GameServer {
    param(
        $Build,
        $Account
    )

    $exePath = Find-GameExe $Build.Path
    if (-not $exePath) {
        Log-Error "Game exe not found in: $($Build.Path)"
        return $false
    }
    $exeDir = [System.IO.Path]::GetDirectoryName($exePath)

    # Kill stale GS processes (spare client if running)
    Kill-Fortnite -Spare "client"

    # No companion processes for GS (no fake EAC needed)

    # Record log file position BEFORE launch (GS boots fast with -nullrhi)
    $logFile = Join-Path $env:LOCALAPPDATA "FortniteGame\Saved\Logs\FortniteGame.log"
    $script:_logPos = 0
    if (Test-Path $logFile) { $script:_logPos = (Get-Item $logFile).Length }

    # Build GS launch arguments (headless: -nullrhi -nosplash -nosound, -log for log monitoring)
    $launchArgs = @(
        "-epicapp=Fortnite",
        "-epicenv=Prod",
        "-epiclocale=en-us",
        "-epicportal",
        "-skippatchcheck",
        "-nobe",
        "-fromfl=eac",
        "-fltoken=3db3ba5dcbd2e16703f3978d",
        "-caldera=eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiYmU5ZGE1YzJmYmVhNDQwN2IyZjQwZWJhYWQ4NTlhZDQiLCJnZW5lcmF0ZWQiOjE2Mzg3MTcyNzgsImNhbGRlcmFHdWlkIjoiMzgxMGI4NjMtMmE2NS00NDU3LTliNTgtNGRhYjNiNDgyYTg2IiwiYWNQcm92aWRlciI6IkVhc3lBbnRpQ2hlYXQiLCJub3RlcyI6IiIsImZhbGxiYWNrIjpmYWxzZX0.VAWQB67RTxhiWOxx7DBjnzDnXyyEnX7OljJm-j2d88G_WgwQ9wrE6lwMEHZHjBd1ISJdUO1UVUqkfLdU5nofBQ",
        "-nullrhi",
        "-nosplash",
        "-nosound",
        "-log",
        "-AUTH_TYPE=epic",
        "-AUTH_LOGIN=$($Account.Email)",
        "-AUTH_PASSWORD=$($Account.Password)"
    ) -join " "

    # Launch game server (headless)
    Log-Info "Starting GameServer (headless)..."
    Log-Debug "Args: -epicapp=Fortnite ... -nullrhi -nosplash -nosound -log"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = $launchArgs
    $psi.WorkingDirectory = $exeDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.EnvironmentVariables["OPENSSL_ia32cap"] = "~0x20000000"

    $script:GameProcess = [System.Diagnostics.Process]::Start($psi)
    $gamePid = $script:GameProcess.Id
    $script:GSPid = $gamePid
    Log-Success "GameServer started (PID: $gamePid)"

    # Inject Auth DLL (Tellurium) immediately with retries
    $tellPath = Join-Path $script:DLLFolder "Tellurium.dll"
    if (Test-Path $tellPath) {
        Log-Info "Injecting Tellurium.dll (auth)..."
        $r = [PSFNInjector]::InjectWithRetry([uint32]$gamePid, $tellPath, 30, 500)
        if ($r -eq "OK") { Log-Success "Tellurium.dll injected." }
        else { Log-Error "Tellurium.dll: $r" }
    } else { Log-Warn "Tellurium.dll not found - skipping auth injection." }

    # Wait for log file to appear (game recreates it on launch)
    $logWait = [System.Diagnostics.Stopwatch]::StartNew()
    while ($logWait.Elapsed.TotalSeconds -lt 15 -and -not (Test-Path $logFile)) {
        Start-Sleep -Milliseconds 250
    }

    function Read-NewLog {
        if (-not (Test-Path $logFile)) { return "" }
        $currentSize = (Get-Item $logFile).Length
        # File was recreated by new game instance — reset position and read from start
        if ($currentSize -lt $script:_logPos) { $script:_logPos = 0 }
        if ($currentSize -le $script:_logPos) { return "" }
        try {
            $fs = [System.IO.FileStream]::new($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $fs.Position = $script:_logPos
            $reader = New-Object System.IO.StreamReader($fs)
            $text = $reader.ReadToEnd()
            $reader.Close()
            $fs.Close()
            $script:_logPos = $currentSize
            return $text
        } catch { return "" }
    }

    # Wait for login (60s timeout — GS with -nullrhi is fast)
    Log-Info "Waiting for GS login..."
    $loginOk = $false
    $loginError = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $errorTriggers = @("port 3551 failed", "Unable to login", "HTTP 400", "Login failed", "ForceLogout")

    while ($sw.Elapsed.TotalSeconds -lt 60 -and -not $loginOk -and -not $loginError) {
        if ($script:GameProcess.HasExited) {
            Log-Error "GameServer exited during login."
            return $false
        }

        $newText = Read-NewLog
        if ($newText) {
            if ($newText -match 'ContinueLoggingIn.*Completed') {
                $loginOk = $true
                break
            }
            foreach ($e in $errorTriggers) {
                if ($newText -like "*$e*") { $loginError = $true; Log-Error "Login error: $e"; break }
            }
        }

        if (-not $loginOk -and -not $loginError) { Start-Sleep -Milliseconds 250 }
    }

    if ($loginOk) { Log-Success "GS Login detected!" }
    elseif ($loginError) { Log-Warn "Login error - continuing anyway..." }
    else { Log-Warn "Login timeout - injecting GS DLL anyway..." }

    # Inject ErbiumGS.dll (gameserver console)
    $gsPath = Join-Path $script:DLLFolder "ErbiumGS.dll"
    if (Test-Path $gsPath) {
        Log-Info "Injecting ErbiumGS.dll (gameserver)..."
        $r = [PSFNInjector]::Inject([uint32]$gamePid, $gsPath)
        if ($r -eq "OK") { Log-Success "ErbiumGS.dll injected." }
        else { Log-Error "ErbiumGS.dll: $r" }
    } else { Log-Warn "ErbiumGS.dll not found - skipping. Run 'Update DLLs' first." }

    return $true
}

# ============================================================================
# BACKEND MANAGEMENT
# ============================================================================

$script:BackendProcess = $null

function Menu-BackendSettings {
    Show-Banner
    Draw-Header "Backend Settings"

    Write-Host "  Mode: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($script:Settings.BackendMode)" -ForegroundColor Cyan
    Write-Host "  Host: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($script:Settings.BackendHost):$($script:Settings.BackendPort)" -ForegroundColor Cyan
    if ($script:Settings.BackendMode -eq "embedded") {
        Write-Host "  Cmd:  " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($script:Settings.EmbeddedCmd)" -ForegroundColor Cyan
        Write-Host "  Dir:  " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($script:Settings.EmbeddedWorkDir)" -ForegroundColor Cyan
    }
    Log-Blank

    Draw-MenuItem "1" "Switch Mode" "(local/embedded)"
    Draw-MenuItem "2" "Set Host & Port"
    Draw-MenuItem "3" "Set Embedded Command"
    Draw-MenuItem "4" "Start Backend"
    Draw-MenuItem "5" "Stop Backend"
    Draw-MenuItem "6" "Test Connection"
    Draw-MenuBack
    Draw-Prompt
    $opt = Read-Host

    switch ($opt) {
        "1" {
            if ($script:Settings.BackendMode -eq "local") {
                $script:Settings.BackendMode = "embedded"
            } else {
                $script:Settings.BackendMode = "local"
            }
            Save-Settings
            Log-Success "Mode set to: $($script:Settings.BackendMode)"
            Start-Sleep 1
            Menu-BackendSettings
        }
        "2" {
            Write-Host "  Host (current: $($script:Settings.BackendHost)): " -NoNewline -ForegroundColor White
            $h = Read-Host
            if ($h) { $script:Settings.BackendHost = $h }
            Write-Host "  Port (current: $($script:Settings.BackendPort)): " -NoNewline -ForegroundColor White
            $p = Read-Host
            if ($p) { $script:Settings.BackendPort = [int]$p }
            Save-Settings
            Log-Success "Updated."
            Start-Sleep 1
            Menu-BackendSettings
        }
        "3" {
            Write-Host "  Command (e.g. 'node index.js' or 'run.bat'): " -NoNewline -ForegroundColor White
            $script:Settings.EmbeddedCmd = Read-Host
            Write-Host "  Working directory (leave empty for auto): " -NoNewline -ForegroundColor White
            $script:Settings.EmbeddedWorkDir = Read-Host
            Save-Settings
            Log-Success "Saved."
            Start-Sleep 1
            Menu-BackendSettings
        }
        "4" {
            if ($script:Settings.BackendMode -ne "embedded") {
                Log-Warn "Backend mode is 'local'. Switch to 'embedded' first."
                Start-Sleep 1
                Menu-BackendSettings
                return
            }
            if ([string]::IsNullOrEmpty($script:Settings.EmbeddedCmd)) {
                Log-Error "No command configured."
                Start-Sleep 1
                Menu-BackendSettings
                return
            }
            Log-Info "Starting embedded backend..."
            $cmd = $script:Settings.EmbeddedCmd
            $wd = $script:Settings.EmbeddedWorkDir

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            if ($cmd -match '\.(bat|cmd)$') {
                $psi.FileName = "cmd.exe"
                $psi.Arguments = "/C $cmd"
            } else {
                $parts = $cmd -split ' ', 2
                $psi.FileName = $parts[0]
                $psi.Arguments = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            }
            if ($wd) { $psi.WorkingDirectory = $wd }
            $psi.UseShellExecute = $true

            $script:BackendProcess = [System.Diagnostics.Process]::Start($psi)
            Log-Success "Backend started (PID: $($script:BackendProcess.Id))"
            Start-Sleep 2
            Menu-BackendSettings
        }
        "5" {
            if ($script:BackendProcess -and -not $script:BackendProcess.HasExited) {
                $script:BackendProcess.Kill()
                Log-Success "Backend stopped."
            } else {
                Log-Warn "No backend running."
            }
            Start-Sleep 1
            Menu-BackendSettings
        }
        "6" {
            Log-Info "Testing $($script:Settings.BackendHost):$($script:Settings.BackendPort)..."
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.Connect($script:Settings.BackendHost, $script:Settings.BackendPort)
                $tcp.Close()
                Log-Success "Connection OK!"
            } catch {
                Log-Error "Cannot connect: $_"
            }
            Start-Sleep 2
            Menu-BackendSettings
        }
        "0" { return }
        default { Menu-BackendSettings }
    }
}



# ============================================================================
# SETTINGS MENU
# ============================================================================

function Menu-Settings {
    Show-Banner
    Draw-Header "Settings"

    Draw-MenuItem "1" "Backend Settings"
    Draw-MenuItem "2" "View DLLs"
    Draw-MenuItem "3" "Re-Download DLLs"
    Draw-MenuItem "4" "Open AppData Folder"
    Draw-MenuItem "5" "Kill Fortnite"
    Draw-MenuBack
    Draw-Prompt
    $opt = Read-Host

    switch ($opt) {
        "1" { Menu-BackendSettings }
        "2" { Menu-ViewDLLs }
        "3" { Menu-RedownloadDLLs }
        "4" { Start-Process "explorer.exe" -ArgumentList $script:AppData }
        "5" { Kill-Fortnite; Start-Sleep 1 }
        "0" { return }
        default { Menu-Settings }
    }
}

# ============================================================================
# LAUNCH MENUS
# ============================================================================

function Menu-LaunchClient {
    Show-Banner
    Draw-Header "Launch Client"

    # Check account
    $acc = Get-Account
    if (-not $acc) {
        Log-Error "No account set! Go to Account settings first."
        Start-Sleep 2
        return
    }

    # Select build
    $build = Select-Build
    if (-not $build) { return }

    Log-Blank
    Draw-Line "DarkCyan"
    Write-Host "  Build:   " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($build.Name)" -NoNewline -ForegroundColor White
    Write-Host " (v$($build.Version))" -ForegroundColor DarkCyan
    Write-Host "  Account: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($acc.Email)" -ForegroundColor Green
    Draw-Line "DarkCyan"
    Log-Blank

    $success = Launch-Client -Build $build -Account $acc

    if ($success) {
        Log-Blank
        Log-Success "Game is running! Returning to menu..."
    } else {
        Log-Error "Launch failed."
    }
    Start-Sleep 2
}

function Menu-LaunchHost {
    Show-Banner
    Draw-Header "Host GameServer"

    # Check host account (separate from client)
    $acc = Get-HostAccount
    if (-not $acc) {
        Log-Error "No host account set! Go to Account > Set Host Account first."
        Start-Sleep 2
        return
    }

    # Select build
    $build = Select-Build
    if (-not $build) { return }

    Log-Blank
    Draw-Line "DarkCyan"
    Write-Host "  Mode:    " -NoNewline -ForegroundColor DarkGray
    Write-Host "GAMESERVER (headless)" -ForegroundColor Yellow
    Write-Host "  Build:   " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($build.Name)" -NoNewline -ForegroundColor White
    Write-Host " (v$($build.Version))" -ForegroundColor DarkCyan
    Write-Host "  Account: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($acc.Email)" -NoNewline -ForegroundColor Yellow
    Write-Host " (host)" -ForegroundColor DarkGray
    Draw-Line "DarkCyan"
    Log-Blank

    $success = Launch-GameServer -Build $build -Account $acc

    if ($success) {
        Log-Blank
        Log-Success "GameServer is running (headless)! Returning to menu..."
    } else {
        Log-Error "Host launch failed."
    }
    Start-Sleep 2
}

# ============================================================================
# MAIN MENU
# ============================================================================

function Main-Menu {
    Show-Banner

    # Quick status line
    $acc = Get-Account
    $builds = Get-Builds
    Write-Host "  Status: " -NoNewline -ForegroundColor DarkGray
    if ($acc) { Write-Host "$($acc.Email)" -NoNewline -ForegroundColor Green }
    else { Write-Host "No account" -NoNewline -ForegroundColor Red }
    Write-Host " | " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($builds.Count) build(s)" -NoNewline -ForegroundColor DarkCyan
    Write-Host ""
    Log-Blank

    Draw-MenuItem "1" "Launch" "(client)"
    Draw-MenuItem "2" "Host" "(gameserver)"
    Draw-MenuItem "3" "Add Build"
    Draw-MenuItem "4" "Remove Build"
    Draw-MenuItem "5" "Account"
    Draw-MenuItem "6" "Update DLLs"
    Draw-MenuItem "7" "Settings"
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "0" -NoNewline -ForegroundColor Red
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host "Exit" -ForegroundColor DarkGray
    Draw-Prompt
    $opt = Read-Host

    switch ($opt) {
        "1" { Menu-LaunchClient }
        "2" { Menu-LaunchHost }
        "3" { Menu-AddBuild }
        "4" { Menu-RemoveBuild }
        "5" { Menu-Account }
        "6" { Menu-UpdateDLLs }
        "7" { Menu-Settings }
        "0" {
            Kill-Fortnite
            Write-Host ""
            Log-Info "Goodbye!"
            exit 0
        }
        default {
            Log-Error "Invalid option."
            Start-Sleep -Milliseconds 500
        }
    }

    Main-Menu
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# Load settings
Load-Settings

# Auto-download DLLs on first run
$firstRun = -not (Test-Path (Join-Path $script:DLLFolder "Tellurium.dll"))
if ($firstRun) {
    Show-Banner
    Log-Info "First run - downloading DLLs..."
    foreach ($dll in $script:DLLUrls.Keys) {
        $dest = Join-Path $script:DLLFolder $dll
        Download-DLL $script:DLLUrls[$dll] $dest $dll | Out-Null
    }
    Log-Blank
}

# Start
Main-Menu
