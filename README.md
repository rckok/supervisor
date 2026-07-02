# Windows GUI Process Supervisor

A self-contained PowerShell script that starts, stops, restarts, and monitors GUI
Windows executables. Each app runs in the interactive user session so its windows
are visible. Child processes are cleaned up via Job Objects — no orphans.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (no install required) or PowerShell 7
- No third-party tools

## Install

Copy `supervisor.ps1` anywhere. No installation step — just run it.
To make the script available under an alias, run `supervisor.ps1 install`. This creates an alias `supervisor`, active immediately and persisted to your PowerShell profile (`$PROFILE`) so it survives new sessions. If that name already points somewhere else, `install` errors out rather than overwriting it. You can specify a different `-Alias` or `uninstall` the conflicting one first. Re-running `install` for an alias that already points at this script is a no-op.
Pass `-Alias <n>` to either command to use a different alias name, e.g. `supervisor.ps1 install -Alias sv`.
Run `supervisor uninstall` (or use whichever alias you've previously set) to remove every alias pointing to the supervisor script, both in the current session and in `$PROFILE`, however it was created (including one added by hand). Pass `-Alias <n>` to remove only that specific alias.

If your execution policy blocks scripts, run this once in an elevated shell:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Or pass `-ExecutionPolicy Bypass` per invocation.

## Autostart at logon

Register a Scheduled Task that restarts supervisors for all `AutoStart` apps
when you log in:

```powershell
.\supervisor.ps1 install-autostart
```

The task runs only when you are logged on (interactive session), so GUI windows
appear normally. Remove it with:

```powershell
.\supervisor.ps1 uninstall-autostart
```

## Example session — two apps

```powershell
# Register Notepad, restart automatically on close or crash
.\supervisor.ps1 register -Name notepad -Path C:\Windows\System32\notepad.exe -RestartPolicy Always -AutoStart -Start

# Register an app with arguments
.\supervisor.ps1 register -Name myapp -Path C:\Apps\myapp.exe -Arguments "--headless --port 8080" -RestartPolicy Always -Start

# Register Calc with Never policy (stays down after closing)
.\supervisor.ps1 register -Name calc -Path C:\Windows\System32\calc.exe -RestartPolicy Never -Start

# Show full detail for both apps
.\supervisor.ps1 info

=== calc ===
  Path           : C:\Windows\System32\calc.exe
  Arguments      :
  RestartPolicy  : Never
  AutoStart      : False
  Status         : Running
  App PID        : 18340
  Supervisor PID : 21204
  Restart count  : 0
  Uptime         : 0d 00h 00m 04s

=== notepad ===
  Path           : C:\Windows\System32\notepad.exe
  Arguments      :
  RestartPolicy  : Always
  AutoStart      : True
  Status         : Running
  App PID        : 7832
  Supervisor PID : 9120
  Restart count  : 0
  Uptime         : 0d 00h 00m 12s

# Close Notepad's window manually → it reappears automatically
# Close Calc's window manually → it stays down, reported as Exited
.\supervisor.ps1 status
calc: Exited
notepad: Running

# Bring Calc back
.\supervisor.ps1 start -Name calc

# Stop Notepad deliberately — it will not restart
.\supervisor.ps1 stop -Name notepad
.\supervisor.ps1 status -Name notepad
Stopped

# Restart Notepad (works regardless of RestartPolicy)
.\supervisor.ps1 restart -Name notepad

# Change Calc's policy to Always going forward
.\supervisor.ps1 set -Name calc -RestartPolicy Always

# Remove an app entirely (stops it first)
.\supervisor.ps1 unregister -Name calc
```

## Command reference

| Command                                    | Description                                                     |
| ------------------------------------------ | --------------------------------------------------------------- |
| `register -Name <n> -Path <exe> [opts]`    | Add/update an app entry                                         |
| `unregister -Name <n>` / `unregister -All` | Stop the app and remove it                                      |
| `set -Name <n> [opts]`                     | Partial update (no restart needed)                              |
| `start -Name <n>` / `start -All`           | Spawn the supervisor (clears stop flag and terminal state)      |
| `stop -Name <n>` / `stop -All`             | Graceful stop; app stays down (status: Stopped)                 |
| `restart -Name <n>` / `restart -All`       | Cycle the app regardless of policy                              |
| `info [-Name <n>]`                         | Full detail block per app (status, PIDs, uptime, last exit)     |
| `status [-Name <n>]`                       | Status string only — prefixed with name when no `-Name` given   |
| `list`                                     | One-line summary of all registered apps                         |
| `install-autostart`                        | Register logon Scheduled Task                                   |
| `uninstall-autostart`                      | Remove the Scheduled Task                                       |
| `install [-Alias <n>]`                     | Create + persist a CLI alias (default `supervisor`)             |
| `uninstall [-Alias <n>]`                   | Remove alias(es) pointing at this script (default: all of them) |

### register / set options

`register` accepts all options below. `set` accepts all except `-Start`
(which is register-only) and `-InitialBackoffSeconds` (take effect at next
supervisor spawn, so re-register if you need to change it).

| Option                         | Default         | Description                                                   |
| ------------------------------ | --------------- | ------------------------------------------------------------- |
| `-Path <exe>`                  | —               | Path to the executable (`register` required; `set` optional)  |
| `-Arguments <string>`          | `''`            | Command-line arguments passed to the executable               |
| `-WorkingDirectory <dir>`      | exe's directory | Working directory for the process                             |
| `-RestartPolicy Always\|Never` | `Always`        | Restart on any exit, or never restart                         |
| `-AutoStart`                   | off             | (`register` only) bare flag — include in logon Scheduled Task |
| `-AutoStart:$true\|$false`     | false           | (`set` only) launch at logon                                  |
| `-Start`                       | off             | (`register` only) start immediately after registering         |
| `-MaxRestarts`                 | 5               | Crash-loop threshold (exits within window)                    |
| `-RestartWindowSeconds`        | 60              | Sliding window for crash-loop detection                       |
| `-GracefulStopTimeoutSeconds`  | 5               | Seconds to wait for graceful close before kill                |
| `-InitialBackoffSeconds`       | 1               | First restart delay                                           |
| `-MaxBackoffSeconds`           | 30              | Backoff cap (doubles each restart)                            |

### status vs info

`status` returns only the status string — useful for scripting, health checks,
or feeding a status bar:

```powershell
.\supervisor.ps1 status -Name notepad
Running

.\supervisor.ps1 status
calc: Exited
notepad: Running
```

`info` returns the full detail block for one or all apps:

```powershell
.\supervisor.ps1 info -Name notepad

=== notepad ===
  Path           : C:\Windows\System32\notepad.exe
  Arguments      :
  RestartPolicy  : Always
  AutoStart      : True
  Status         : Running
  App PID        : 7832
  Supervisor PID : 9120
  Restart count  : 0
  Uptime         : 0d 00h 14m 22s
```

### set AutoStart

For `register`, use the bare flag (presence = true, omission = false):

```powershell
.\supervisor.ps1 register -Name notepad ... -AutoStart    # enabled
.\supervisor.ps1 register -Name notepad ...               # disabled
```

For `set`, use PowerShell's colon syntax to pass an explicit value to the switch:

```powershell
.\supervisor.ps1 set -Name notepad -AutoStart:$true
.\supervisor.ps1 set -Name notepad -AutoStart:$false
```

## Status states

| State               | Meaning                                                    |
| ------------------- | ---------------------------------------------------------- |
| `Running`           | App process is alive                                       |
| `Stopped`           | Deliberately stopped via `stop`                            |
| `Exited`            | Exited on its own; `RestartPolicy=Never` so not relaunched |
| `Failed`            | Crash-loop guard gave up after too many rapid exits        |
| `Restarting`        | Supervisor alive, app briefly between launches             |
| `SupervisorCrashed` | Supervisor died unexpectedly; run `start` to recover       |

## File layout

```
%APPDATA%\Supervisor\
  registry.json          ← all registered apps and their config
  <name>\
    stop.flag            ← presence = deliberate stop requested
    supervisor.pid       ← PID of the per-app supervisor process
    state.json           ← RecordedState, AppPid, RestartCount, …
    app.log              ← timestamped event log
```

## Architecture notes

**One supervisor process per app.** Each app gets a hidden `powershell.exe`
process running `supervisor.ps1 -Supervise -Name <n>`. It owns the
launch → wait → restart cycle independently of other apps. A supervisor
crashing affects only its own app.

**Job Objects prevent orphans.** Every launched app is assigned to a Windows
Job Object created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. When the
supervisor exits (cleanly or by crash), the Job handle closes, and Windows
kills the entire process tree automatically.

**Stop vs. Exited.** The stop flag alone does not determine state; the
`RecordedState` field in `state.json` is the source of truth. `stop` sets
the flag _and_ records `Stopped`. An app that exits on its own with
`RestartPolicy=Never` records `Exited` — clearly distinct in `status`.

**Registry concurrency.** All reads and writes to `registry.json` are
wrapped in a named system Mutex so concurrent CLI invocations cannot
corrupt the file.
