# Dynamic Island - Windows system poller
# Started once by Rainmeter (-Action Loop, one copy, quits with Rainmeter): polls every
# second and rewrites NowPlaying.inc only when something changed. The music is only asked
# for when the cover watcher (cover.py watch, started from here) says it changed, and every
# 5 s to be safe; without the watcher it polls every 0.5 s as before. Reports now-playing
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
# Usage: NowPlaying.ps1 [-Action Loop|Status|PlayPause|Next|Previous]
#   Loop       the poller (what the skin runs)
#   Status     one poll, then exit
#   PlayPause, Next, Previous   a media key; the loop shows the result on its next poll

param(
    [ValidateSet('Loop', 'Status', 'PlayPause', 'Next', 'Previous')]
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
$coverTxt   = Join-Path $here 'Cover.txt'      # the watcher's latest art: "title|artist", then the slot

function Test-Watcher {
    try { [Threading.Mutex]::OpenExisting('DynamicIsland-cover').Dispose(); return $true } catch { return $false }
}

function Start-Watcher {
    try { Start-Process pythonw -ArgumentList @("`"$coverPy`"", 'watch', "`"$here`"") -WindowStyle Hidden } catch { }
}

function Get-WatcherCover([string]$Key) {
    try { $c = [IO.File]::ReadAllLines($coverTxt) } catch { return $null }
    if ($c.Count -ge 2 -and $c[0] -eq $Key) { return $c[1] }
    return $null
}

$script:cover = $null   # kept in memory by the loop; the file only carries it across restarts

function Update-Cover {
    param([string]$Key, [string]$Title = '', [string]$Artist = '', [long]$DurationMs = 0)
    $st = $script:cover
    if (-not $st -and (Test-Path $coverState)) { try { $st = Get-Content $coverState -Raw | ConvertFrom-Json } catch { } }
    if (-not $st) { $st = [pscustomobject]@{ Key = ''; Slot = 1; Tries = 0 } }
    $script:cover = $st
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
    $idle = @{ ClaudeState = 0; ClaudeMode = 'Default'; ClaudeEvent = 0; ClaudeLabel = ''; ClaudeEventAt = ''
        ClaudeSince = ''; ClaudeEnded = ''; ClaudeStep = 0; ClaudeDoing = ''; ClaudeProject = '' }
    if (-not (Test-Path $claudePath)) { return $idle }
    try {
        $s = Get-Content $claudePath -Raw | ConvertFrom-Json
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        # A session that crashed never says goodbye: its status runs out instead.
        if ($nowMs -gt $s.until_ms) { return $idle }

        $info = $idle.Clone()
        $info.ClaudeState = [int](@{ working = 1; needs_you = 2; done = 3 }[[string]$s.state])
        if ($claudeModes.ContainsKey([string]$s.mode)) { $info.ClaudeMode = $claudeModes[[string]$s.mode] }
        # the Claude panel: turn start/end (ms), step 0-4, last file or command, project folder
        $info.ClaudeSince = [string]$s.since_ms
        $info.ClaudeEnded = [string]$s.ended_ms
        $info.ClaudeStep = [int]$s.step
        $info.ClaudeDoing = ([string]$s.doing) -replace '[\r\n]', ' '
        $info.ClaudeProject = ([string]$s.project) -replace '[\r\n]', ' '
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
    $prev = $script:evState
    if (-not $prev -and (Test-Path $statePath)) {
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
    $json = $state | ConvertTo-Json -Compress
    if ($json -ne $script:evJson) {   # the file only changes when the state does
        $script:evJson = $json
        $json | Set-Content -Path $statePath -Encoding utf8
    }
    $script:evState = [pscustomobject]$state

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
        [string]$Cover = '',
        [string]$ClaudeSince = '',
        [string]$ClaudeEnded = '',
        [int]$ClaudeStep = 0,
        [string]$ClaudeDoing = '',
        [string]$ClaudeProject = ''
    )
    $lines = @(
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
        "ClaudeSince=$ClaudeSince"
        "ClaudeEnded=$ClaudeEnded"
        "ClaudeStep=$ClaudeStep"
        "ClaudeDoing=$ClaudeDoing"
        "ClaudeProject=$ClaudeProject"
    )
    $text = ($lines -join "`r`n") + "`r`n"
    # unchanged, or only the position moved on as expected while playing (the island carries the
    # position forward itself): no disk write. A seek or a pause still writes.
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $rest = $text -replace 'ProgressMs=\d*', ''
    if ($rest -eq $script:lastRest) {
        $expected = $script:lastPos + $(if ($IsPlaying -eq 1) { $nowMs - $script:lastAt } else { 0 })
        if ([Math]::Abs($ProgressMs - $expected) -lt 1500) { return }
    }
    $tmp = "$outInc.tmp"
    try {
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $true))
        if (Test-Path $outInc) { [IO.File]::Replace($tmp, $outInc, $null) } else { [IO.File]::Move($tmp, $outInc) }
        $script:lastRest, $script:lastPos, $script:lastAt = $rest, $ProgressMs, $nowMs
    } catch { }   # the skin is reading it right now: the next poll writes it
}

# === WinRT media session manager (loaded once) ===

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

function Get-Session {
    if (-not $script:sessionManager) {
        try {
            $script:sessionManager = Wait-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
                ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        } catch { return $null }
    }
    try { return $script:sessionManager.GetCurrentSession() } catch { $script:sessionManager = $null; return $null }
}

# === One poll ===
# Battery (WMI) every 10 polls and mic/camera (registry) every second: both are slower to ask than
# the rest and change rarely. Claude every poll, the media session when it's due (see the loop).

$script:tick = 0
$script:battery = $null
$script:privacy = @{ MicActive = 0; CamActive = 0 }
$script:watcher = $false     # cover.py watch runs: it says when the music changed
$script:mediaDue = $true     # ask Windows about the music on this poll
$script:media = $null        # the last answer, and when it came
$script:mediaAt = 0
$script:lastCover = ''

function Get-Media {
    $session = Get-Session
    if (-not $session) { return @{} }
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

        $cover = ''
        if ($props.Title) {
            $key = "$($props.Title)|$($props.Artist)"
            if ($script:watcher) {
                # the watcher draws the art itself; until it's done the last art stays
                $slot = Get-WatcherCover $key
                $cover = if ($null -ne $slot) { $slot } else { $script:lastCover }
            } else {
                $cover = Update-Cover -Key $key -Title $props.Title -Artist $props.Artist -DurationMs $durationMs
            }
        }
        $script:lastCover = $cover
        return @{ Track = $props.Title; Artist = $props.Artist; IsPlaying = $isPlaying
            ProgressMs = $positionMs; DurationMs = $durationMs; Cover = $cover }
    } catch {
        $script:sessionManager = $null   # a stale manager: ask Windows again next time
        return @{}
    }
}

function Invoke-Poll {
    if (-not $script:battery -or $script:tick % 10 -eq 0) { $script:battery = Get-BatteryInfo }
    if ($script:watcher -or $script:tick % 2 -eq 0) {   # once a second
        $script:privacy = @{
            MicActive = [int](Test-CapabilityActive -Capability 'microphone')
            CamActive = [int](Test-CapabilityActive -Capability 'webcam')
        }
    }
    $script:tick++
    $b = $script:battery
    $eventCode = Get-EventCode -CurrentStatus $b.Status -CurrentPercent $b.Percent -CurrentCharging $b.Charging
    $commonArgs = @{
        BatteryPercent = $b.Percent; BatteryCharging = $b.Charging
        MicActive = $script:privacy.MicActive; CamActive = $script:privacy.CamActive; EventCode = $eventCode
    } + (Get-ClaudeInfo)

    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($script:mediaDue -or $null -eq $script:media) {
        $script:media = Get-Media
        $script:mediaAt = $nowMs
        $m = $script:media
    } else {
        # nothing changed since: the last answer, its position carried forward
        $m = $script:media.Clone()
        if ($m.IsPlaying -eq 1) { $m.ProgressMs = [long]$m.ProgressMs + ($nowMs - $script:mediaAt) }
    }
    Write-NowPlaying @commonArgs @m
}

# === Main ===

if ($Action -in 'PlayPause', 'Next', 'Previous') {
    $session = Get-Session
    if ($session) {
        try {
            switch ($Action) {
                'PlayPause' { $session.TryTogglePlayPauseAsync() | Out-Null }
                'Next'      { $session.TrySkipNextAsync() | Out-Null }
                'Previous'  { $session.TrySkipPreviousAsync() | Out-Null }
            }
        } catch { }
    }
    return
}

if ($Action -eq 'Status') {
    Invoke-Poll
    return
}

# Loop: one copy only, and it ends with Rainmeter
$created = $false
$mutex = New-Object Threading.Mutex($true, 'DynamicIsland-nowplaying', [ref]$created)
if (-not $created) { return }
$ErrorActionPreference = 'Continue'
$kick = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'DynamicIsland-media')
$n = 0
while ($true) {
    if ($n % 20 -eq 0) {
        if (-not (Get-Process -Name Rainmeter -ErrorAction SilentlyContinue)) { break }
        $script:watcher = Test-Watcher
        if (-not $script:watcher -and $n % 120 -eq 0) { Start-Watcher }   # not more often: maybe no pythonw
    }
    $n++
    try { Invoke-Poll } catch { }
    if ($script:watcher) {
        $script:mediaDue = $kick.WaitOne(1000) -or ($n % 5 -eq 0)
    } else {
        Start-Sleep -Milliseconds 500
        $script:mediaDue = $true
    }
}
$mutex.ReleaseMutex()
