# Dynamic Island - Windows system poller
# Run periodically by Rainmeter (Plugin=RunCommand). Reports now-playing
# media (via SMTC), battery status, mic/camera privacy indicators and the
# Claude Code state (from the claude-modes hook) - no API keys, no browser
# extension, no extra installs.
# Writes NowPlaying.inc for the skin to read via a WebParser file:// measure.
#
# Album art: PowerShell 5.1 can't read the SMTC thumbnail stream (its WinRT
# interop doesn't project IRandomAccessStream), so on each track change this
# calls @Resources\cover.py (Python + winrt), which writes the rounded art
# tiles and the blurred glow for the expanded view into slot 0 or 1.
#
# Battery/privacy both use classic WMI/registry (not WinRT) and are
# reliable in this environment, unlike the thumbnail stream above.
#
# Usage: NowPlaying.ps1 [-Action Status|PlayPause|Next|Previous]

param(
    [ValidateSet('Status', 'PlayPause', 'Next', 'Previous')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$outInc     = Join-Path $here 'NowPlaying.inc'
$statePath  = Join-Path $here 'EventState.json'

# === Album art (cover.py, once per track) ===
# Two slots so Rainmeter loads the new file instead of its cached image. A
# track's thumbnail can show up a moment after its title, so a miss is
# retried on the next few polls.

$coverState = Join-Path $here 'CoverState.json'
$coverPy    = Join-Path $here 'cover.py'

function Update-Cover {
    param([string]$Key, [string]$Title = '', [string]$Artist = '', [long]$DurationMs = 0)
    $st = $null
    if (Test-Path $coverState) { try { $st = Get-Content $coverState -Raw | ConvertFrom-Json } catch { } }
    if (-not $st) { $st = [pscustomobject]@{ Key = ''; Slot = 1; Tries = 0 } }
    if ($st.Key -ne $Key) {
        $st.Key = $Key; $st.Slot = 1 - $st.Slot; $st.Tries = 0
    } elseif ($st.Tries -ge 5) {
        return [string]$st.Slot
    }
    try {
        & python $coverPy $here $st.Slot --title $Title --artist $Artist --duration $DurationMs 2>$null | Out-Null
        $st.Tries = if ($LASTEXITCODE -eq 0) { 99 } else { $st.Tries + 1 }
    } catch {
        $st.Tries = 99   # no Python: keep the placeholder tiles
    }
    ($st | ConvertTo-Json) | Set-Content -Path $coverState -Encoding utf8
    return [string]$st.Slot
}

# === Battery (WMI, confirmed reliable) ===

function Get-BatteryInfo {
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $battery) {
        return @{ Percent = -1; Charging = 0; Status = -1 }
    }
    # Charging (for the bolt icon) = actively charging. Status is the raw
    # BatteryStatus code, used separately to detect ANY AC power transition -
    # plugging in a nearly-full battery reports Status 2 ("on AC, not
    # actively charging"), not 6-9, so Charging alone misses that event.
    $charging = [int]($battery.BatteryStatus -in @(6, 7, 8, 9))
    return @{ Percent = [int]$battery.EstimatedChargeRemaining; Charging = $charging; Status = [int]$battery.BatteryStatus }
}

# === Mic/camera privacy (registry, confirmed reliable) ===

function Test-CapabilityActive {
    param([string]$Capability)
    $basePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$Capability"
    if (-not (Test-Path $basePath)) { return $false }

    foreach ($k in Get-ChildItem $basePath -ErrorAction SilentlyContinue) {
        if ($k.PSChildName -eq 'NonPackaged') {
            foreach ($sk in Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue) {
                $stop = (Get-ItemProperty -Path $sk.PSPath -Name LastUsedTimeStop -ErrorAction SilentlyContinue).LastUsedTimeStop
                if ($null -ne $stop -and $stop -eq 0) { return $true }
            }
        } else {
            $stop = (Get-ItemProperty -Path $k.PSPath -Name LastUsedTimeStop -ErrorAction SilentlyContinue).LastUsedTimeStop
            if ($null -ne $stop -and $stop -eq 0) { return $true }
        }
    }
    return $false
}

# === Claude Code (status file written by the claude-modes hook) ===
# State 0 idle, 1 working, 2 needs you, 3 done. Mode picks the colour of the
# spark (same colours as the Claude Code footer). Event 1/2/3 = needs you /
# done / mode changed, inside the same 8 s window as the battery events.

$claudePath = Join-Path $env:USERPROFILE '.claude/claude-modes/status.json'
$claudeModes = @{ plan = 'Plan'; acceptEdits = 'Edits'; auto = 'Auto'; bypassPermissions = 'Bypass' }
$claudeLabels = @{ Default = 'manual'; Plan = 'plan mode'; Edits = 'edit mode'; Auto = 'auto mode'; Bypass = 'bypass' }  # max 9 characters: wider runs into the spark

function Get-ClaudeInfo {
    $idle = @{ ClaudeState = 0; ClaudeMode = 'Default'; ClaudeEvent = 0; ClaudeLabel = ''; ClaudeEventAt = '' }
    if (-not (Test-Path $claudePath)) { return $idle }
    try {
        $s = Get-Content $claudePath -Raw | ConvertFrom-Json
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        # A session that crashed never says goodbye: its status runs out instead.
        if ($nowMs -gt $s.until_ms) { return $idle }

        $info = $idle.Clone()
        $info.ClaudeState = [int](@{ working = 1; needs_you = 2; done = 3 }[[string]$s.state])
        if ($claudeModes.ContainsKey([string]$s.mode)) { $info.ClaudeMode = $claudeModes[[string]$s.mode] }
        if (($nowMs - $s.changed_ms) -lt 8000) {
            $info.ClaudeEventAt = [string]$s.changed_ms
            switch ($s.change) {
                'needs_you' { $info.ClaudeEvent = 1; $info.ClaudeLabel = 'needs you' }
                'done'      { $info.ClaudeEvent = 2; $info.ClaudeLabel = 'done' }
                'mode'      { $info.ClaudeEvent = 3; $info.ClaudeLabel = $claudeLabels[$info.ClaudeMode] }
            }
        }
        return $info
    } catch { return $idle }
}

# === Event decay: "recently changed" window for the battery HUD ===
# Event 2 = AC plug/unplug (any BatteryStatus change). Event 3 = battery
# dropped below the low-battery threshold while unplugged. Event 4 = battery
# dropped below the critical threshold while unplugged (checked first, so it
# wins if a poll ever sees a jump straight past both bands). Each tier has
# its own latch so it fires once per discharge episode rather than every
# poll - both reset once you charge back up past the hysteresis margin or
# plug in, so a later drop below either threshold warns again.

$lowBatteryThreshold = 20
$criticalBatteryThreshold = 10
$lowBatteryResetAbove = 25

function Get-EventCode {
    param([int]$CurrentStatus, [int]$CurrentPercent, [int]$CurrentCharging)

    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $prev = $null
    if (Test-Path $statePath) {
        try { $prev = Get-Content $statePath -Raw | ConvertFrom-Json } catch { $prev = $null }
    }

    if (-not $prev) {
        $state = @{ LastStatus = $CurrentStatus; ChangeAt = 0; ChangeType = 0; LowBatteryWarned = $false; CriticalBatteryWarned = $false }
    } else {
        $lastStatus = if ($null -ne $prev.LastStatus) { $prev.LastStatus } else { $prev.LastCharging }
        $lowBatteryWarned = if ($null -ne $prev.LowBatteryWarned) { $prev.LowBatteryWarned } else { $false }
        $criticalBatteryWarned = if ($null -ne $prev.CriticalBatteryWarned) { $prev.CriticalBatteryWarned } else { $false }
        $state = @{ LastStatus = $lastStatus; ChangeAt = $prev.ChangeAt; ChangeType = $prev.ChangeType; LowBatteryWarned = $lowBatteryWarned; CriticalBatteryWarned = $criticalBatteryWarned }
    }

    $fired = $false

    # Any change in the raw BatteryStatus code means an AC power transition
    # happened (plug in, unplug, or a charging-state shift) - not just the
    # narrower "actively charging" cases.
    if ($CurrentStatus -ne $state.LastStatus -and $CurrentStatus -ge 0 -and $state.LastStatus -ge 0) {
        $state.ChangeAt = $nowMs
        $state.ChangeType = 2
        $fired = $true
    }

    if (-not $fired -and $CurrentPercent -ge 0 -and $CurrentPercent -le $criticalBatteryThreshold `
            -and $CurrentCharging -eq 0 -and -not $state.CriticalBatteryWarned) {
        $state.ChangeAt = $nowMs
        $state.ChangeType = 4
        $state.CriticalBatteryWarned = $true
        $state.LowBatteryWarned = $true
        $fired = $true
    }

    if (-not $fired -and $CurrentPercent -ge 0 -and $CurrentPercent -le $lowBatteryThreshold `
            -and $CurrentCharging -eq 0 -and -not $state.LowBatteryWarned) {
        $state.ChangeAt = $nowMs
        $state.ChangeType = 3
        $state.LowBatteryWarned = $true
        $fired = $true
    }

    if ($CurrentPercent -gt $lowBatteryResetAbove -or $CurrentCharging -eq 1) {
        $state.LowBatteryWarned = $false
        $state.CriticalBatteryWarned = $false
    }

    $state.LastStatus = $CurrentStatus
    ($state | ConvertTo-Json) | Set-Content -Path $statePath -Encoding utf8

    if ($state.ChangeAt -gt 0 -and ($nowMs - $state.ChangeAt) -lt 8000) {
        return $state.ChangeType
    }
    return 0
}

# === Output ===

function Write-NowPlaying {
    param(
        [string]$Track = '',
        [string]$Artist = '',
        [int]$IsPlaying = 0,
        [long]$ProgressMs = 0,
        [long]$DurationMs = 0,
        [int]$BatteryPercent = -1,
        [int]$BatteryCharging = 0,
        [int]$MicActive = 0,
        [int]$CamActive = 0,
        [int]$EventCode = 0,
        [int]$ClaudeState = 0,
        [string]$ClaudeMode = 'Default',
        [int]$ClaudeEvent = 0,
        [string]$ClaudeLabel = '',
        [string]$ClaudeEventAt = '',
        [string]$Cover = ''
    )
    @(
        "Track=$Track"
        "Artist=$Artist"
        "IsPlaying=$IsPlaying"
        "ProgressMs=$ProgressMs"
        "DurationMs=$DurationMs"
        "Volume=0"
        "BatteryPercent=$BatteryPercent"
        "BatteryCharging=$BatteryCharging"
        "MicActive=$MicActive"
        "CamActive=$CamActive"
        "Event=$EventCode"
        "ClaudeState=$ClaudeState"
        "ClaudeMode=$ClaudeMode"
        "ClaudeEvent=$ClaudeEvent"
        "ClaudeLabel=$ClaudeLabel"
        "ClaudeEventAt=$ClaudeEventAt"
        "Cover=$Cover"
    ) | Set-Content -Path $outInc -Encoding utf8
}

# === Gather system state (independent of media session) ===

$batteryInfo = Get-BatteryInfo
$micActive = [int](Test-CapabilityActive -Capability 'microphone')
$camActive = [int](Test-CapabilityActive -Capability 'webcam')
$eventCode = Get-EventCode -CurrentStatus $batteryInfo.Status -CurrentPercent $batteryInfo.Percent -CurrentCharging $batteryInfo.Charging
$claudeInfo = Get-ClaudeInfo

# === SMTC now-playing (independent of the above) ===

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime] | Out-Null

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Wait-WinRT($WinRtOperation, [type]$ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $task = $asTask.Invoke($null, @($WinRtOperation))
    $task.Wait(3000) | Out-Null
    return $task.Result
}

$commonArgs = @{
    BatteryPercent = $batteryInfo.Percent; BatteryCharging = $batteryInfo.Charging
    MicActive = $micActive; CamActive = $camActive; EventCode = $eventCode
} + $claudeInfo

try {
    $sessionManager = Wait-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
        ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    $session = $sessionManager.GetCurrentSession()
} catch {
    Write-NowPlaying @commonArgs
    return
}

if (-not $session) {
    Write-NowPlaying @commonArgs
    return
}

if ($Action -ne 'Status') {
    try {
        switch ($Action) {
            'PlayPause' { $session.TryTogglePlayPauseAsync() | Out-Null }
            'Next'      { $session.TrySkipNextAsync() | Out-Null }
            'Previous'  { $session.TrySkipPreviousAsync() | Out-Null }
        }
        Start-Sleep -Milliseconds 300
    } catch { }
}

try {
    $props = Wait-WinRT ($session.TryGetMediaPropertiesAsync()) `
        ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    $playbackInfo = $session.GetPlaybackInfo()
    $timeline = $session.GetTimelineProperties()

    $isPlaying = [int]($playbackInfo.PlaybackStatus.ToString() -eq 'Playing')
    $positionMs = [long]$timeline.Position.TotalMilliseconds
    # SMTC only refreshes the position on play/pause/seek: carry it forward from when it was taken
    if ($isPlaying -eq 1 -and $timeline.LastUpdatedTime.Year -gt 2000) {
        $positionMs += [long]([DateTimeOffset]::Now - $timeline.LastUpdatedTime).TotalMilliseconds
    }
    $durationMs = [long]($timeline.EndTime - $timeline.StartTime).TotalMilliseconds

    $cover = if ($props.Title) {
        Update-Cover -Key "$($props.Title)|$($props.Artist)" -Title $props.Title -Artist $props.Artist -DurationMs $durationMs
    } else { '' }

    Write-NowPlaying @commonArgs -Track $props.Title -Artist $props.Artist -IsPlaying $isPlaying `
        -ProgressMs $positionMs -DurationMs $durationMs -Cover $cover
} catch {
    Write-NowPlaying @commonArgs
}

