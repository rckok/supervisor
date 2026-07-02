#Requires -Version 5.1
<#
.SYNOPSIS
    Windows GUI Process Supervisor.

.DESCRIPTION
    Starts, stops, restarts, and monitors GUI Windows executables with configurable
    restart policies and guaranteed orphan cleanup via Job Objects.

    Each app gets its own hidden supervisor process that owns the restart loop.
    The CLI script reads/writes a JSON registry and per-app signal files.

    Usage: supervisor.ps1 <command> [options]

    Commands:
      register   -Name <n> -Path <exe> [-Arguments <s>] [-WorkingDirectory <dir>]
                 [-RestartPolicy Always|Never] [-AutoStart] [-Start]
                 [-MaxRestarts <n>] [-RestartWindowSeconds <n>]
                 [-GracefulStopTimeoutSeconds <n>]
      unregister -Name <n> | -All
      set        -Name <n> [-RestartPolicy Always|Never] [-AutoStart:$true|:$false]
      start      -Name <n> | -All
      stop       -Name <n> | -All
      restart    -Name <n> | -All
      status     [-Name <n>]
      list
      install-autostart
      uninstall-autostart
      install    [-Alias <n>]
      uninstall  [-Alias <n>]
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    # Internal flag -- the supervisor loop invokes this script with -Supervise.
    # End-users do not call -Supervise directly.
    [switch]$Supervise,

    [string]$Name,
    [string]$Path,
    [string]$Arguments        = '',
    [string]$WorkingDirectory = '',

    # For install/uninstall: alias name to create/remove (defaults to 'supervisor').
    [string]$Alias = 'supervisor',

    [ValidateSet('Always', 'Never')]
    [string]$RestartPolicy = 'Always',

    # For register: use -AutoStart (bare flag) to enable, omit to disable.
    # For set: use -AutoStart:$true or -AutoStart:$false (colon syntax required for switches).
    # $PSBoundParameters.ContainsKey('AutoStart') distinguishes "not supplied" from explicit false.
    [switch]$AutoStart,

    # Start the app immediately after register
    [switch]$Start,

    # Apply the command to all registered apps (start, stop, restart, unregister)
    [switch]$All,

    # Per-app tuning (stored in registry; defaults shown here)
    [int]$MaxRestarts                   = 5,
    [int]$RestartWindowSeconds          = 60,
    [int]$GracefulStopTimeoutSeconds    = 5,
    [int]$InitialBackoffSeconds         = 1,
    [int]$MaxBackoffSeconds             = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$SupervisorRoot = Join-Path $env:APPDATA 'Supervisor'
$RegistryFile   = Join-Path $SupervisorRoot 'registry.json'
# Global\ prefix makes the mutex visible across all sessions on the machine,
# preventing registry corruption when two CLI invocations race.
$MutexName  = 'Global\SupervisorRegistry_v1'
$ScriptPath = $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Job Object P/Invoke
#
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is the key flag: when the last handle to
# the job closes (because the supervisor exits or explicitly calls CloseHandle),
# Windows kills every process in the job -- the app and all its descendants --
# with no manual process-tree traversal needed.
#
# We create a fresh job per launch iteration (not reused across restarts) so a
# stale job from the previous run can't interfere.
# ---------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'WinJob').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.ComponentModel;

public static class WinJob {

    private const int JobObjectExtendedLimitInformation = 9;

    // The only flag we set: close the job handle -> kill the whole tree.
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long    PerProcessUserTimeLimit;
        public long    PerJobUserTimeLimit;
        public uint    LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint    ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint    PriorityClass;
        public uint    SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS                       IoInfo;
        public UIntPtr                           ProcessMemoryLimit;
        public UIntPtr                           JobMemoryLimit;
        public UIntPtr                           PeakProcessMemoryUsed;
        public UIntPtr                           PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr hJob, int JobObjectInfoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpInfo, uint cbInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    /// <summary>
    /// Creates an anonymous job object with KILL_ON_JOB_CLOSE set.
    /// Throws Win32Exception on failure.
    /// </summary>
    public static IntPtr Create() {
        IntPtr hJob = CreateJobObject(IntPtr.Zero, null);
        if (hJob == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");

        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

        uint size = (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        if (!SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, ref info, size)) {
            int err = Marshal.GetLastWin32Error();
            CloseHandle(hJob);
            throw new Win32Exception(err, "SetInformationJobObject failed");
        }
        return hJob;
    }
}
'@
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
function Get-AppDir([string]$AppName) {
    Join-Path $SupervisorRoot $AppName
}
function Get-StopFlagPath([string]$AppName) {
    Join-Path (Get-AppDir $AppName) 'stop.flag'
}
function Get-SupervisorPidPath([string]$AppName) {
    Join-Path (Get-AppDir $AppName) 'supervisor.pid'
}
function Get-StatePath([string]$AppName) {
    Join-Path (Get-AppDir $AppName) 'state.json'
}
function Get-LogPath([string]$AppName) {
    Join-Path (Get-AppDir $AppName) 'app.log'
}

function Initialize-AppDir([string]$AppName) {
    $dir = Get-AppDir $AppName
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Logging (per-app, timestamped, best-effort)
# ---------------------------------------------------------------------------
function Write-AppLog([string]$AppName, [string]$Message) {
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    try {
        Add-Content -LiteralPath (Get-LogPath $AppName) -Value $line -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# Registry helpers (JSON file, protected by a named system Mutex)
#
# The mutex guards every read-modify-write to registry.json so concurrent CLI
# invocations cannot interleave their updates.
# ---------------------------------------------------------------------------
function Invoke-WithRegistryLock([scriptblock]$Action) {
    $mutex    = New-Object System.Threading.Mutex($false, $MutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(8000)   # 8-second timeout
        } catch [System.Threading.AbandonedMutexException] {
            # Previous holder crashed mid-write; we now own it.
            $acquired = $true
        }
        if (-not $acquired) { throw "Could not acquire registry lock within 8 seconds." }
        & $Action
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Read-Registry {
    if (-not (Test-Path $RegistryFile)) { return @{} }
    $raw = Get-Content -LiteralPath $RegistryFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }

    $doc = $raw | ConvertFrom-Json
    $ht  = @{}
    foreach ($prop in $doc.PSObject.Properties) {
        $a = $prop.Value
        # Deserialise into a typed hashtable so callers never deal with PSCustomObject.
        $ht[$prop.Name] = @{
            Name                       = [string]$a.Name
            Path                       = [string]$a.Path
            Arguments                  = [string]$a.Arguments
            WorkingDirectory           = [string]$a.WorkingDirectory
            AutoStart                  = [bool]$a.AutoStart
            RestartPolicy              = [string]$a.RestartPolicy
            MaxRestarts                = [int]$a.MaxRestarts
            RestartWindowSeconds       = [int]$a.RestartWindowSeconds
            GracefulStopTimeoutSeconds = [int]$a.GracefulStopTimeoutSeconds
            InitialBackoffSeconds      = [int]$a.InitialBackoffSeconds
            MaxBackoffSeconds          = [int]$a.MaxBackoffSeconds
        }
    }
    return $ht
}

function Write-Registry([hashtable]$Reg) {
    $doc = @{}
    foreach ($key in $Reg.Keys) { $doc[$key] = $Reg[$key] }
    $doc | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $RegistryFile -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Per-app state (state.json)
# Fields: RecordedState, AppPid, RestartCount, LastStartTime,
#         LastExitCode, LastExitTime
# RecordedState values: Running | Stopped | Exited | Failed | Unknown
# ---------------------------------------------------------------------------
function Read-AppState([string]$AppName) {
    $path = Get-StatePath $AppName
    if (-not (Test-Path $path)) {
        return @{
            RecordedState = 'Unknown'; AppPid = 0; RestartCount = 0
            LastStartTime = $null;    LastExitCode = $null; LastExitTime = $null
        }
    }
    try {
        $o = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
        return @{
            RecordedState = [string]$o.RecordedState
            AppPid        = [int]$o.AppPid
            RestartCount  = [int]$o.RestartCount
            LastStartTime = if ($o.LastStartTime) { [string]$o.LastStartTime } else { $null }
            LastExitCode  = if ($null -ne $o.LastExitCode -and $o.LastExitCode -ne '') {
                                [int]$o.LastExitCode } else { $null }
            LastExitTime  = if ($o.LastExitTime) { [string]$o.LastExitTime } else { $null }
        }
    } catch {
        return @{
            RecordedState = 'Unknown'; AppPid = 0; RestartCount = 0
            LastStartTime = $null;    LastExitCode = $null; LastExitTime = $null
        }
    }
}

function Write-AppState([string]$AppName, [hashtable]$State) {
    Initialize-AppDir $AppName
    $State | ConvertTo-Json |
        Set-Content -LiteralPath (Get-StatePath $AppName) -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Stop-flag helpers
#
# The stop flag is a sentinel file whose PRESENCE signals "stay down".
# Its absence alone is not enough to distinguish Stopped/Exited/Failed;
# those distinctions live in RecordedState.
# ---------------------------------------------------------------------------
function Test-StopFlag([string]$AppName) {
    Test-Path (Get-StopFlagPath $AppName)
}

function Set-StopFlagFile([string]$AppName) {
    Initialize-AppDir $AppName
    '' | Set-Content -LiteralPath (Get-StopFlagPath $AppName) -Encoding UTF8
}

function Clear-StopFlagFile([string]$AppName) {
    $f = Get-StopFlagPath $AppName
    if (Test-Path $f) { Remove-Item -LiteralPath $f -Force }
}

# ---------------------------------------------------------------------------
# Process utilities
# ---------------------------------------------------------------------------
function Test-ProcessAlive([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return (-not $p.HasExited)
    } catch {
        return $false
    }
}

function Stop-ProcessGracefully([System.Diagnostics.Process]$Proc, [int]$TimeoutSec) {
    if ($null -eq $Proc -or $Proc.HasExited) { return }
    try { $null = $Proc.CloseMainWindow() } catch { }    # WM_CLOSE to main window

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $Proc.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }

    if (-not $Proc.HasExited) {
        try { $Proc.Kill() } catch { }
    }
}

# ---------------------------------------------------------------------------
# Spawn the supervisor process (detached, hidden, runs in the user's session)
#
# We use Start-Process with -WindowStyle Hidden rather than the .NET API here
# because PowerShell's Start-Process correctly sets the CREATE_NEW_PROCESS_GROUP
# flag and keeps the process in the current interactive session, which is what
# GUI apps need.  The supervisor itself is a console app; only the apps it
# manages need visible windows.
# ---------------------------------------------------------------------------
function Start-SupervisorProcess([string]$AppName) {
    Initialize-AppDir $AppName
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-WindowStyle', 'Hidden',
            '-File', "`"$ScriptPath`"",
            '-Supervise',
            '-Name', "`"$AppName`""
        ) `
        -WindowStyle Hidden `
        -PassThru
    Write-AppLog $AppName "CLI: spawned supervisor PID=$($proc.Id)"
    return $proc
}

# ===========================================================================
# SUPERVISOR LOOP  (-Supervise mode)
#
# This function runs inside the hidden per-app supervisor process.
# It owns the launch -> wait -> decide cycle and the Job Object for that app.
# ===========================================================================
function Start-SupervisorLoop([string]$AppName) {
    Initialize-AppDir $AppName

    # Persist our own PID so the CLI can check our liveness.
    $supervisorPidPath = Get-SupervisorPidPath $AppName
    [System.IO.File]::WriteAllText($supervisorPidPath, "$PID")

    $restartCount      = 0
    $currentBackoff    = 0   # Initialised from registry config on first iteration
    # Sliding-window timestamps (for crash-loop detection)
    $windowTimestamps  = [System.Collections.Generic.List[datetime]]::new()

    Write-AppLog $AppName "Supervisor started (PID=$PID)"

    :supervisorLoop while ($true) {
        # --- Read latest config (picks up 'set' changes between restarts) ---
        $reg = Read-Registry
        if (-not $reg.ContainsKey($AppName)) {
            Write-AppLog $AppName "FATAL: app not in registry -- supervisor exiting"
            break supervisorLoop
        }
        $cfg              = $reg[$AppName]
        $restartPolicy    = $cfg.RestartPolicy
        $maxRestarts      = $cfg.MaxRestarts
        $restartWindowSec = $cfg.RestartWindowSeconds
        $gracefulTimeout  = $cfg.GracefulStopTimeoutSeconds
        $initBackoff      = $cfg.InitialBackoffSeconds
        $maxBackoff       = $cfg.MaxBackoffSeconds
        $exePath          = $cfg.Path
        $exeArgs          = $cfg.Arguments
        $workDir          = if ($cfg.WorkingDirectory) { $cfg.WorkingDirectory } else { Split-Path $exePath }

        # (1) Stop flag check -- honour a deliberate stop before attempting launch.
        if (Test-StopFlag $AppName) {
            Write-AppLog $AppName "Stop flag set before launch -- exiting (Stopped)"
            Write-AppState $AppName @{
                RecordedState = 'Stopped'; AppPid = 0; RestartCount = $restartCount
                LastStartTime = $null; LastExitCode = $null; LastExitTime = $null
            }
            break supervisorLoop
        }

        # (2) Create Job Object for this launch iteration.
        #     A fresh job per launch means no state bleeds across restarts.
        $jobHandle = [IntPtr]::Zero
        try {
            $jobHandle = [WinJob]::Create()
        } catch {
            Write-AppLog $AppName "ERROR: CreateJobObject failed: $_ -- supervisor exiting (Failed)"
            Write-AppState $AppName @{
                RecordedState = 'Failed'; AppPid = 0; RestartCount = $restartCount
                LastStartTime = $null; LastExitCode = $null; LastExitTime = $null
            }
            break supervisorLoop
        }

        # (2b) Launch the app.
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName         = $exePath
        $startInfo.Arguments        = $exeArgs
        $startInfo.WorkingDirectory = $workDir
        # UseShellExecute = $false gives us a reliable process handle for AssignProcessToJobObject.
        # The process still runs in the interactive session because the supervisor does.
        $startInfo.UseShellExecute  = $false

        $appProc    = $null
        $launchTime = $null
        try {
            $appProc = [System.Diagnostics.Process]::Start($startInfo)
        } catch {
            Write-AppLog $AppName "ERROR: failed to start '$exePath': $_"
            [WinJob]::CloseHandle($jobHandle) | Out-Null
            $jobHandle = [IntPtr]::Zero

            # Treat launch failure as a crash for crash-loop bookkeeping.
            $windowTimestamps.Add((Get-Date))
        }

        if ($null -ne $appProc) {
            # (2c) Assign the process to the Job Object immediately after start.
            #      Ideally we'd start suspended, assign, then resume to catch child
            #      processes spawned in the first milliseconds, but that requires
            #      CREATE_SUSPENDED which UseShellExecute=false cannot set from
            #      managed code without additional P/Invoke.  Assigning immediately
            #      after start catches all practical cases.
            try {
                [WinJob]::AssignProcessToJobObject($jobHandle, $appProc.Handle) | Out-Null
            } catch {
                Write-AppLog $AppName "WARNING: AssignProcessToJobObject failed: $_ (orphan risk)"
            }

            $launchTime = Get-Date
            Write-AppState $AppName @{
                RecordedState = 'Running'; AppPid = $appProc.Id; RestartCount = $restartCount
                LastStartTime = $launchTime.ToString('o')
                LastExitCode  = $null; LastExitTime = $null
            }
            Write-AppLog $AppName "Started app PID=$($appProc.Id)"

            # (3) Wait for the process to exit (crash, clean exit, or user closes window --
            #     all are just "process exited" from the supervisor's perspective).
            $appProc.WaitForExit()
            $exitCode = $appProc.ExitCode
            $exitTime = Get-Date
            Write-AppLog $AppName "App exited PID=$($appProc.Id) ExitCode=$exitCode"

            $windowTimestamps.Add($exitTime)
        } else {
            $exitCode = -1
            $exitTime = Get-Date
        }

        # (4) Close Job Object -- kills any surviving child processes.
        if ($jobHandle -ne [IntPtr]::Zero) {
            [WinJob]::CloseHandle($jobHandle) | Out-Null
            $jobHandle = [IntPtr]::Zero
        }

        # --- Prune timestamps outside the sliding crash-loop window ---
        $cutoff = $exitTime.AddSeconds(-$restartWindowSec)
        $fresh  = [System.Collections.Generic.List[datetime]]::new()
        foreach ($ts in $windowTimestamps) {
            if ($ts -ge $cutoff) { $fresh.Add($ts) }
        }
        $windowTimestamps = $fresh

        # (5a) Stop flag after exit -- deliberate stop wins over policy.
        if (Test-StopFlag $AppName) {
            Write-AppLog $AppName "Stop flag set after exit -- recording Stopped"
            Write-AppState $AppName @{
                RecordedState = 'Stopped'; AppPid = 0; RestartCount = $restartCount
                LastStartTime = if ($null -ne $launchTime) { $launchTime.ToString('o') } else { $null }
                LastExitCode  = $exitCode; LastExitTime = $exitTime.ToString('o')
            }
            break supervisorLoop
        }

        # (5b) Crash-loop guard -- only applies when policy would restart.
        if ($restartPolicy -ne 'Never' -and $windowTimestamps.Count -ge $maxRestarts) {
            Write-AppLog $AppName ("CRASH-LOOP: exited {0} times in {1}s -- giving up (Failed)" `
                -f $windowTimestamps.Count, $restartWindowSec)
            Write-AppState $AppName @{
                RecordedState = 'Failed'; AppPid = 0; RestartCount = $restartCount
                LastStartTime = if ($null -ne $launchTime) { $launchTime.ToString('o') } else { $null }
                LastExitCode  = $exitCode; LastExitTime = $exitTime.ToString('o')
            }
            break supervisorLoop
        }

        # (5c) RestartPolicy = Never -- record Exited, don't relaunch.
        if ($restartPolicy -eq 'Never') {
            Write-AppLog $AppName "RestartPolicy=Never -- recording Exited"
            Write-AppState $AppName @{
                RecordedState = 'Exited'; AppPid = 0; RestartCount = $restartCount
                LastStartTime = if ($null -ne $launchTime) { $launchTime.ToString('o') } else { $null }
                LastExitCode  = $exitCode; LastExitTime = $exitTime.ToString('o')
            }
            break supervisorLoop
        }

        # (5d) Relaunch -- apply exponential backoff.
        $restartCount++
        # Initialise from registry on first relaunch; config may differ from script default.
        if ($currentBackoff -eq 0) { $currentBackoff = $initBackoff }

        # Stable run (longer than the crash window) -- reset backoff so a long-lived
        # app that eventually crashes doesn't start with a large delay.
        if ($null -ne $launchTime) {
            $runDuration = ($exitTime - $launchTime).TotalSeconds
            if ($runDuration -gt $restartWindowSec) { $currentBackoff = $initBackoff }
        }

        Write-AppLog $AppName "Restarting in ${currentBackoff}s (restart #$restartCount)..."
        Start-Sleep -Seconds $currentBackoff
        $currentBackoff = [Math]::Min($currentBackoff * 2, $maxBackoff)
    }

    # Remove our PID file on clean exit so status doesn't see a stale record.
    try { Remove-Item -LiteralPath $supervisorPidPath -Force -ErrorAction SilentlyContinue } catch { }
    Write-AppLog $AppName "Supervisor exiting"
}

# ===========================================================================
# CLI command implementations
# ===========================================================================

# ---------------------------------------------------------------------------
# register
# ---------------------------------------------------------------------------
function Invoke-Register {
    if (-not $Name) { throw "register: -Name is required" }
    if (-not $Path) { throw "register: -Path is required" }

    Initialize-AppDir $Name
    $wd = if ($WorkingDirectory) { $WorkingDirectory } else { Split-Path $Path }

    $entry = @{
        Name                       = $Name
        Path                       = $Path
        Arguments                  = $Arguments
        WorkingDirectory           = $wd
        AutoStart = $AutoStart.IsPresent
        RestartPolicy              = $RestartPolicy
        MaxRestarts                = $MaxRestarts
        RestartWindowSeconds       = $RestartWindowSeconds
        GracefulStopTimeoutSeconds = $GracefulStopTimeoutSeconds
        InitialBackoffSeconds      = $InitialBackoffSeconds
        MaxBackoffSeconds          = $MaxBackoffSeconds
    }

    Invoke-WithRegistryLock {
        $reg = Read-Registry
        $reg[$Name] = $entry
        Write-Registry $reg
    }

    Write-Host "Registered '$Name' (policy=$RestartPolicy, autoStart=$($AutoStart.IsPresent))"
    if ($Start) { Invoke-Start -AppName $Name }
}

# ---------------------------------------------------------------------------
# set  (partial update -- does not disturb a running instance)
# ---------------------------------------------------------------------------
function Invoke-Set([hashtable]$BoundParams) {
    if (-not $Name) { throw "set: -Name is required" }

    Invoke-WithRegistryLock {
        $reg = Read-Registry
        if (-not $reg.ContainsKey($Name)) { throw "set: '$Name' is not registered" }

        $entry = $reg[$Name]
        if ($BoundParams.ContainsKey('Path'))                       { $entry.Path                       = $Path }
        if ($BoundParams.ContainsKey('Arguments'))                  { $entry.Arguments                  = $Arguments }
        if ($BoundParams.ContainsKey('WorkingDirectory'))           { $entry.WorkingDirectory           = $WorkingDirectory }
        if ($BoundParams.ContainsKey('RestartPolicy'))              { $entry.RestartPolicy              = $RestartPolicy }
        # -AutoStart / -AutoStart:$false detected via ContainsKey
        if ($BoundParams.ContainsKey('AutoStart'))                  { $entry.AutoStart                  = $AutoStart.IsPresent }
        if ($BoundParams.ContainsKey('MaxRestarts'))                { $entry.MaxRestarts                = $MaxRestarts }
        if ($BoundParams.ContainsKey('RestartWindowSeconds'))       { $entry.RestartWindowSeconds       = $RestartWindowSeconds }
        if ($BoundParams.ContainsKey('GracefulStopTimeoutSeconds')) { $entry.GracefulStopTimeoutSeconds = $GracefulStopTimeoutSeconds }
        if ($BoundParams.ContainsKey('MaxBackoffSeconds'))          { $entry.MaxBackoffSeconds          = $MaxBackoffSeconds }
        $reg[$Name] = $entry
        Write-Registry $reg
    }

    Write-Host "Updated config for '$Name' (changes take effect on next restart)"
}

# ---------------------------------------------------------------------------
# unregister
# ---------------------------------------------------------------------------
function Invoke-Unregister([string]$AppName = $Name) {
    if (-not $AppName) { throw "unregister: -Name is required" }

    # Stop the app if running (quiet on not-running).
    Invoke-Stop -AppName $AppName -Quiet

    Invoke-WithRegistryLock {
        $reg = Read-Registry
        $reg.Remove($AppName)
        Write-Registry $reg
    }

    $dir = Get-AppDir $AppName
    if (Test-Path $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Unregistered '$AppName'"
}

# ---------------------------------------------------------------------------
# start  -- clear stop flag + terminal state, then spawn supervisor
# ---------------------------------------------------------------------------
function Invoke-Start([string]$AppName = $Name) {
    if (-not $AppName) { throw "start: -Name is required" }

    $reg = Read-Registry
    if (-not $reg.ContainsKey($AppName)) { throw "start: '$AppName' is not registered" }

    # Guard: app already running?
    $state = Read-AppState $AppName
    if ($state.RecordedState -eq 'Running' -and (Test-ProcessAlive $state.AppPid)) {
        Write-Host "App '$AppName' is already running (PID=$($state.AppPid))"
        return
    }

    # Guard: supervisor still alive (e.g. policy=Always, brief gap between restarts)?
    $spidPath = Get-SupervisorPidPath $AppName
    if (Test-Path $spidPath) {
        $spid = 0
        try { $spid = [int](Get-Content -LiteralPath $spidPath -Raw) } catch { }
        if ((Test-ProcessAlive $spid)) {
            Write-Host "Supervisor for '$AppName' is already running (PID=$spid)"
            return
        }
    }

    # Clear stop flag -- without this the loop exits immediately on the first check.
    Clear-StopFlagFile $AppName
    # Clear any terminal state so the loop doesn't see Exited/Failed and bail.
    Write-AppState $AppName @{
        RecordedState = 'Unknown'; AppPid = 0; RestartCount = 0
        LastStartTime = $null; LastExitCode = $null; LastExitTime = $null
    }

    $proc = Start-SupervisorProcess $AppName
    Write-Host "Started '$AppName' (supervisor PID=$($proc.Id))"
}

# ---------------------------------------------------------------------------
# stop  -- set stop flag, then terminate the app gracefully->forcefully
# ---------------------------------------------------------------------------
function Invoke-Stop([string]$AppName = $Name, [switch]$Quiet) {
    if (-not $AppName) { throw "stop: -Name is required" }

    # Signal the loop to not restart after the process exits.
    # This must happen BEFORE we kill the app so the loop sees the flag
    # when it wakes up after WaitForExit().
    Set-StopFlagFile $AppName

    # Read graceful timeout from registry if available.
    $gracefulTimeout = $GracefulStopTimeoutSeconds
    try {
        $reg = Read-Registry
        if ($reg.ContainsKey($AppName)) {
            $gracefulTimeout = $reg[$AppName].GracefulStopTimeoutSeconds
        }
    } catch { }

    $state = Read-AppState $AppName
    if ($state.AppPid -gt 0 -and (Test-ProcessAlive $state.AppPid)) {
        try {
            $appProc = Get-Process -Id $state.AppPid -ErrorAction Stop
            Stop-ProcessGracefully $appProc $gracefulTimeout
            if (-not $Quiet) { Write-Host "Stopped '$AppName' (was PID=$($state.AppPid))" }
        } catch {
            if (-not $Quiet) { Write-Host "App process $($state.AppPid) already gone" }
        }
    } else {
        if (-not $Quiet) { Write-Host "App '$AppName' was not running" }
    }

    # Wait briefly for the supervisor to acknowledge (write Stopped state and exit).
    $spidPath = Get-SupervisorPidPath $AppName
    if (Test-Path $spidPath) {
        $spid = 0
        try { $spid = [int](Get-Content -LiteralPath $spidPath -Raw) } catch { }
        $deadline = (Get-Date).AddSeconds(10)
        while ((Test-ProcessAlive $spid) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
    }
}

# ---------------------------------------------------------------------------
# restart -- clear stop flag + terminal state, kill app so loop relaunches
# ---------------------------------------------------------------------------
function Invoke-Restart([string]$AppName = $Name) {
    if (-not $AppName) { throw "restart: -Name is required" }

    $reg = Read-Registry
    if (-not $reg.ContainsKey($AppName)) { throw "restart: '$AppName' is not registered" }

    $gracefulTimeout = $GracefulStopTimeoutSeconds
    try { $gracefulTimeout = $reg[$AppName].GracefulStopTimeoutSeconds } catch { }

    # Ensure the stop flag is clear -- the loop checks this after the process exits
    # and must see "go ahead and relaunch" regardless of policy.
    Clear-StopFlagFile $AppName

    # Check if a supervisor is alive that can handle the relaunch.
    $supervisorAlive = $false
    $spidPath = Get-SupervisorPidPath $AppName
    if (Test-Path $spidPath) {
        $spid = 0
        try { $spid = [int](Get-Content -LiteralPath $spidPath -Raw) } catch { }
        $supervisorAlive = (Test-ProcessAlive $spid)
    }

    if (-not $supervisorAlive) {
        # Supervisor is gone (policy=Never app exited, crash-loop gave up, or crashed).
        # Clear terminal state and spawn a fresh supervisor.
        Write-AppState $AppName @{
            RecordedState = 'Unknown'; AppPid = 0; RestartCount = 0
            LastStartTime = $null; LastExitCode = $null; LastExitTime = $null
        }
        $proc = Start-SupervisorProcess $AppName
        Write-Host "Restarted '$AppName' (new supervisor PID=$($proc.Id))"
        return
    }

    # Supervisor alive -- kill the app so the loop picks it up and relaunches.
    $state = Read-AppState $AppName
    if ($state.AppPid -gt 0 -and (Test-ProcessAlive $state.AppPid)) {
        try {
            $appProc = Get-Process -Id $state.AppPid -ErrorAction Stop
            Stop-ProcessGracefully $appProc $gracefulTimeout
        } catch { }
    }
    Write-Host "Restarted '$AppName'"
}

# ---------------------------------------------------------------------------
# Helper: resolve the effective status string for one app
# ---------------------------------------------------------------------------
function Get-AppStatus([string]$AppName) {
    $state = Read-AppState $AppName

    $appAlive        = Test-ProcessAlive $state.AppPid
    $supervisorAlive = $false

    $spidPath = Get-SupervisorPidPath $AppName
    if (Test-Path $spidPath) {
        $spid = 0
        try { $spid = [int](Get-Content -LiteralPath $spidPath -Raw) } catch { }
        $supervisorAlive = Test-ProcessAlive $spid
    }

    $effective = $state.RecordedState
    if ($effective -eq 'Running' -and -not $appAlive) {
        $effective = if ($supervisorAlive) { 'Restarting' } else { 'SupervisorCrashed' }
    }
    return $effective
}

# ---------------------------------------------------------------------------
# info  (full per-app detail block)
# ---------------------------------------------------------------------------
function Invoke-Info([string]$AppName = '') {
    $reg   = Read-Registry
    $names = @(if ($AppName) { $AppName } else { $reg.Keys | Sort-Object })

    if ($names.Count -eq 0) { Write-Host "No apps registered."; return }

    foreach ($n in $names) {
        $cfg    = if ($reg.ContainsKey($n)) { $reg[$n] } else { $null }
        $state  = Read-AppState $n
        $appStatus = Get-AppStatus $n

        $supervisorPid = 0
        $spidPath = Get-SupervisorPidPath $n
        if (Test-Path $spidPath) {
            try { $supervisorPid = [int](Get-Content -LiteralPath $spidPath -Raw) } catch { }
        }

        # --- Format uptime ---
        $uptime = ''
        if ($appStatus -eq 'Running' -and $state.LastStartTime) {
            try {
                $span   = (Get-Date) - [datetime]$state.LastStartTime
                $uptime = '{0}d {1:D2}h {2:D2}m {3:D2}s' -f [int]$span.TotalDays, $span.Hours, $span.Minutes, $span.Seconds
            } catch { }
        }

        Write-Host ''
        Write-Host "=== $n ==="
        if ($cfg) {
            Write-Host "  Path           : $($cfg.Path)"
            Write-Host "  Arguments      : $($cfg.Arguments)"
            Write-Host "  RestartPolicy  : $($cfg.RestartPolicy)"
            Write-Host "  AutoStart      : $($cfg.AutoStart)"
        } else {
            Write-Host "  (not in registry)"
        }
        Write-Host "  Status         : $appStatus"
        Write-Host "  App PID        : $(if ($state.AppPid -gt 0) { $state.AppPid } else { 'N/A' })"
        Write-Host "  Supervisor PID : $(if ($supervisorPid -gt 0) { $supervisorPid } else { 'N/A' })"
        Write-Host "  Restart count  : $($state.RestartCount)"
        if ($uptime)                       { Write-Host "  Uptime         : $uptime" }
        if ($null -ne $state.LastExitCode) { Write-Host "  Last exit code : $($state.LastExitCode)" }
        if ($state.LastExitTime)           { Write-Host "  Last exit time : $($state.LastExitTime)" }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# status  (one status string per app)
# With -Name: bare string.  Without -Name: "<name>: <status>" per line.
# ---------------------------------------------------------------------------
function Invoke-Status([string]$AppName = '') {
    $reg   = Read-Registry
    $names = @(if ($AppName) { $AppName } else { $reg.Keys | Sort-Object })

    if ($names.Count -eq 0) { Write-Host "No apps registered."; return }

    foreach ($n in $names) {
        $appStatus = Get-AppStatus $n
        if ($AppName) { Write-Host $appStatus } else { Write-Host "${n}: $appStatus" }
    }
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
function Invoke-List {
    $reg = Read-Registry
    if ($reg.Count -eq 0) { Write-Host "No apps registered."; return }

    $fmt = '{0,-20}  {1,-9}  {2,-10}  {3}'
    Write-Host ($fmt -f 'Name', 'Restart', 'AutoStart', 'Path')
    Write-Host ($fmt -f '----', '-------', '---------', '----')
    foreach ($n in ($reg.Keys | Sort-Object)) {
        $c = $reg[$n]
        Write-Host ($fmt -f $c.Name, $c.RestartPolicy, $(if ($c.AutoStart) { 'Yes' } else { 'No' }), $c.Path)
    }
}

# ---------------------------------------------------------------------------
# install-autostart  -- Scheduled Task at logon (interactive, current user)
#
# We use Register-ScheduledTask rather than schtasks because:
#   * We can pass -LogonType Interactive without needing a password.
#   * The syntax is cleaner and easier to verify.
# The task calls 'autostart-run' which starts supervisors for all AutoStart apps.
# ---------------------------------------------------------------------------
function Invoke-InstallAutostart {
    $taskName = 'SupervisorAutostart'
    $action   = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ("-NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " +
                   "-File `"$ScriptPath`" autostart-run")

    # AtLogOn for the current user only -- "Run only when user is logged on"
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action   $action `
        -Trigger  $trigger `
        -Settings $settings `
        -RunLevel Limited `
        -Force | Out-Null

    Write-Host "Autostart task '$taskName' installed for $env:USERDOMAIN\$env:USERNAME"
    Write-Host "All apps with -AutoStart will start at next logon."
}

# ---------------------------------------------------------------------------
# uninstall-autostart
# ---------------------------------------------------------------------------
function Invoke-UninstallAutostart {
    Unregister-ScheduledTask -TaskName 'SupervisorAutostart' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Autostart task removed."
}

# ---------------------------------------------------------------------------
# autostart-run  -- called by the Scheduled Task at logon
# ---------------------------------------------------------------------------
function Invoke-AutostartRun {
    $reg = Read-Registry
    foreach ($n in $reg.Keys) {
        if ($reg[$n].AutoStart) {
            Invoke-Start -AppName $n
        }
    }
}

# ---------------------------------------------------------------------------
# Profile alias helpers (used by install/uninstall)
#
# 'install' persists an alias by appending a marker-delimited block to
# $PROFILE (CurrentUserCurrentHost) so it survives new sessions. These
# helpers also recognise bare Set-Alias/New-Alias lines a user may have
# added to their profile by hand, so 'uninstall' can find and remove those
# too without being told the alias name.
# ---------------------------------------------------------------------------
function Get-ProfileAliasBlockMarker([string]$AliasName) {
    return "# >>> Supervisor alias: $AliasName >>>", "# <<< Supervisor alias: $AliasName <<<"
}

function Get-ProfileAliasMatches([string]$AliasName, [string]$TargetPath) {
    $results = @()
    if (-not (Test-Path $PROFILE)) { return $results }

    $lines = @(Get-Content -LiteralPath $PROFILE -Encoding UTF8)
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]

        # --- Our own marker block ---
        if ($line -match '^\s*#\s*>>>\s*Supervisor alias:\s*(.+?)\s*>>>\s*$') {
            $blockName  = $Matches[1]
            $endPattern = '^\s*#\s*<<<\s*Supervisor alias:\s*' + [regex]::Escape($blockName) + '\s*<<<\s*$'
            $endIdx     = -1
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match $endPattern) { $endIdx = $j; break }
            }
            if ($endIdx -ge 0) {
                $innerTarget = $null
                for ($k = $i + 1; $k -lt $endIdx; $k++) {
                    if ($lines[$k] -match "-Value\s+['`"]([^'`"]+)['`"]") { $innerTarget = $Matches[1]; break }
                }
                $results += [pscustomobject]@{
                    Name = $blockName; Target = $innerTarget
                    StartLine = $i; EndLine = $endIdx; IsMarkerBlock = $true
                }
                $i = $endIdx + 1
                continue
            }
        }

        # --- Bare Set-Alias / New-Alias line (e.g. added by hand) ---
        if ($line -notmatch '^\s*#' -and $line -match '^\s*(Set-Alias|New-Alias)\b') {
            $name = $null; $target = $null
            if ($line -match "-Name\s+['`"]?([^'`"\s]+)")  { $name   = $Matches[1] }
            if ($line -match "-Value\s+['`"]?([^'`"\s]+)") { $target = $Matches[1] }
            if ((-not $name) -or (-not $target)) {
                if ($line -match '^\s*(?:Set-Alias|New-Alias)\s+(\S+)\s+(\S+)') {
                    if (-not $name)   { $name   = $Matches[1].Trim("'`"") }
                    if (-not $target) { $target = $Matches[2].Trim("'`"") }
                }
            }
            if ($name -and $target) {
                $results += [pscustomobject]@{
                    Name = $name; Target = $target
                    StartLine = $i; EndLine = $i; IsMarkerBlock = $false
                }
            }
        }

        $i++
    }

    if ($AliasName)  { $results = @($results | Where-Object { $_.Name -ieq $AliasName }) }
    if ($TargetPath) { $results = @($results | Where-Object { $_.Target -and ($_.Target -ieq $TargetPath) }) }
    return $results
}

function Remove-ProfileAliasMatches([array]$AliasMatches) {
    if (-not $AliasMatches -or $AliasMatches.Count -eq 0) { return }
    if (-not (Test-Path $PROFILE)) { return }

    $lines       = @(Get-Content -LiteralPath $PROFILE -Encoding UTF8)
    $removeLines = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($m in $AliasMatches) {
        for ($k = $m.StartLine; $k -le $m.EndLine; $k++) { [void]$removeLines.Add($k) }
    }

    $kept = New-Object System.Collections.Generic.List[string]
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        if (-not $removeLines.Contains($idx)) { $kept.Add($lines[$idx]) }
    }

    # Collapse consecutive blank lines left behind, and trim leading/trailing blanks.
    $collapsed = New-Object System.Collections.Generic.List[string]
    $prevBlank = $false
    foreach ($l in $kept) {
        $isBlank = [string]::IsNullOrWhiteSpace($l)
        if ($isBlank -and $prevBlank) { continue }
        $collapsed.Add($l)
        $prevBlank = $isBlank
    }
    while ($collapsed.Count -gt 0 -and [string]::IsNullOrWhiteSpace($collapsed[0]))                  { $collapsed.RemoveAt(0) }
    while ($collapsed.Count -gt 0 -and [string]::IsNullOrWhiteSpace($collapsed[$collapsed.Count-1])) { $collapsed.RemoveAt($collapsed.Count - 1) }

    Set-Content -LiteralPath $PROFILE -Value $collapsed -Encoding UTF8
}

# ---------------------------------------------------------------------------
# install -- creates an alias for this script, active immediately and
# persisted to the user's PowerShell profile so it survives new sessions.
# ---------------------------------------------------------------------------
function Invoke-Install {
    $liveAlias      = Get-Alias -Name $Alias -ErrorAction SilentlyContinue
    $profileMatches = @(Get-ProfileAliasMatches -AliasName $Alias -TargetPath $null)

    $existingTarget = $null
    if ($liveAlias) { $existingTarget = $liveAlias.Definition }
    elseif ($profileMatches.Count -gt 0) { $existingTarget = $profileMatches[0].Target }

    if ($existingTarget) {
        if ($existingTarget -ieq $ScriptPath) {
            Write-Host "Alias '$Alias' is already installed for $ScriptPath -- nothing to do."
            return
        }
        throw "install: alias '$Alias' already exists and points to '$existingTarget'. Choose a different -Alias, or run 'uninstall -Alias $Alias' first."
    }

    # Active immediately in the current session (Global scope reaches the
    # calling interactive shell, since running '.\supervisor.ps1 install'
    # executes in a child scope of that same session).
    Set-Alias -Name $Alias -Value $ScriptPath -Scope Global

    # Persist so it survives new sessions.
    $profileDir = Split-Path $PROFILE -Parent
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    if (-not (Test-Path $PROFILE))    { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }

    $startMarker, $endMarker = Get-ProfileAliasBlockMarker $Alias
    $block = @(
        $startMarker
        "Set-Alias -Name '$Alias' -Value '$ScriptPath'"
        $endMarker
    )
    Add-Content -LiteralPath $PROFILE -Value $block -Encoding UTF8

    Write-Host "Alias '$Alias' created for $ScriptPath (active now; persisted in $PROFILE for new sessions)"
}

# ---------------------------------------------------------------------------
# uninstall -- removes an alias for this script, from both the current
# session and the user's PowerShell profile.
#
# Without -Alias: removes every alias (session + profile) pointing at this
# script, however it was created -- including ones added by hand.
# With -Alias <n>: restricts removal to that specific alias name.
# ---------------------------------------------------------------------------
function Invoke-Uninstall([bool]$ExplicitAlias) {
    $removed            = @()
    $skippedWrongTarget = $false

    if ($ExplicitAlias) {
        $liveAlias = Get-Alias -Name $Alias -ErrorAction SilentlyContinue
        if ($liveAlias) {
            if ($liveAlias.Definition -ieq $ScriptPath) {
                Remove-Item -Path "Alias:$Alias" -Force
                $removed += $Alias
            } else {
                Write-Host "Alias '$Alias' points to '$($liveAlias.Definition)', not this script -- not removing."
                $skippedWrongTarget = $true
            }
        }
    } else {
        $liveMatches = @(Get-Alias | Where-Object { $_.Definition -ieq $ScriptPath })
        foreach ($a in $liveMatches) {
            Remove-Item -Path "Alias:$($a.Name)" -Force
            $removed += $a.Name
        }
    }

    $aliasFilter    = if ($ExplicitAlias) { $Alias } else { $null }
    $profileMatches = @(Get-ProfileAliasMatches -AliasName $aliasFilter -TargetPath $ScriptPath)
    if ($profileMatches.Count -gt 0) {
        Remove-ProfileAliasMatches -AliasMatches $profileMatches
        foreach ($m in $profileMatches) { $removed += $m.Name }
    }

    $removed = @($removed | Select-Object -Unique)
    foreach ($name in $removed) {
        Write-Host "Alias '$name' removed for $ScriptPath"
    }

    if ($removed.Count -eq 0 -and -not $skippedWrongTarget) {
        if ($ExplicitAlias) {
            Write-Host "Alias '$Alias' not found (or does not point to this script)."
        } else {
            Write-Host "No alias found pointing to $ScriptPath"
        }
    }
}

# ===========================================================================
# ENTRY POINT
# ===========================================================================

# --- Supervisor mode (internal) -------------------------------------------
if ($Supervise) {
    if (-not $Name) { throw "-Supervise requires -Name" }
    Start-SupervisorLoop -AppName $Name
    exit 0
}

# --- Ensure root directory exists ------------------------------------------
if (-not (Test-Path $SupervisorRoot)) {
    New-Item -ItemType Directory -Path $SupervisorRoot -Force | Out-Null
}

# --- CLI dispatch -----------------------------------------------------------
switch ($Command.ToLower()) {
    'install'   { Invoke-Install }
    'uninstall' { Invoke-Uninstall -ExplicitAlias:($PSBoundParameters.ContainsKey('Alias')) }
    'register' { Invoke-Register }
    'unregister' {
        if ($All) {
            $names = @(((Read-Registry).Keys) | Sort-Object)
            foreach ($n in $names) { Invoke-Unregister -AppName $n }
        } else { Invoke-Unregister }
    }
    'set' { Invoke-Set -BoundParams $PSBoundParameters }
    'start' {
        if ($All) {
            foreach ($n in ((Read-Registry).Keys | Sort-Object)) { Invoke-Start -AppName $n }
        } else { Invoke-Start }
    }
    'stop' {
        if ($All) {
            foreach ($n in ((Read-Registry).Keys | Sort-Object)) { Invoke-Stop -AppName $n }
        } else { Invoke-Stop }
    }
    'restart' {
        if ($All) {
            foreach ($n in ((Read-Registry).Keys | Sort-Object)) { Invoke-Restart -AppName $n }
        } else { Invoke-Restart }
    }
    'info'                { Invoke-Info   -AppName $Name }
    'status'              { Invoke-Status -AppName $Name }
    'list'                { Invoke-List }
    'install-autostart'   { Invoke-InstallAutostart }
    'uninstall-autostart' { Invoke-UninstallAutostart }
    'autostart-run'       { Invoke-AutostartRun }
    default {
        Write-Host @'
Usage: supervisor.ps1 <command> [options]

Commands:
  register   -Name <n> -Path <exe> [-Arguments <s>] [-WorkingDirectory <dir>]
             [-RestartPolicy Always|Never] [-AutoStart] [-Start]
             [-MaxRestarts <n>] [-RestartWindowSeconds <n>]
             [-GracefulStopTimeoutSeconds <n>]
             [-InitialBackoffSeconds <n>] [-MaxBackoffSeconds <n>]

  unregister -Name <n> | -All

  set        -Name <n> [-Path <exe>] [-Arguments <s>] [-WorkingDirectory <dir>]
             [-RestartPolicy Always|Never] [-AutoStart:$true|:$false]
             [-MaxRestarts <n>] [-RestartWindowSeconds <n>]

  start      -Name <n> | -All
  stop       -Name <n> | -All
  restart    -Name <n> | -All

  info       [-Name <n>]          (full detail; all apps if no name given)
  status     [-Name <n>]          (status string only; prefixed with name if no -Name given)
  list

  install-autostart               (register Scheduled Task for logon)
  uninstall-autostart

  install    [-Alias <n>]         (create alias, default 'supervisor'; active now
                                   and persisted to $PROFILE for new sessions;
                                   errors if that name is already taken elsewhere)
  uninstall  [-Alias <n>]         (no -Alias: remove every alias -- session and
                                   $PROFILE, however it was created -- that points
                                   at this script. With -Alias: remove only that one)

Status states:
  Running          -- app process is alive
  Stopped          -- deliberately stopped via 'stop'
  Exited           -- app exited and RestartPolicy=Never (not a deliberate stop)
  Failed           -- crash-loop guard gave up after too many rapid exits
  Restarting       -- supervisor alive, app momentarily between launches
  SupervisorCrashed -- supervisor died unexpectedly; run 'start' to recover
'@
    }
}
