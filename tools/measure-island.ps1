# What the Dynamic Island costs: CPU and RAM of Rainmeter and its helpers, and how often their
# files get rewritten, over a few minutes. Run it before and after a change to compare.
#   powershell -ExecutionPolicy Bypass -File tools\measure-island.ps1 [-Seconds 300] [-Label before]
# Prints a table and saves it next to the skin's files (and into Nextcloud\Claude\dynamic-island if that exists).

param([int]$Seconds = 300, [string]$Label = (Get-Date -Format 'yyyyMMdd-HHmm'))

$res = Join-Path $HOME 'Documents\Rainmeter\Skins\DynamicIsland\@Resources'
$pattern = 'NowPlaying\.ps1|feeds\.py|pcstate\.py|djstate\.py|cover\.py'

function Get-Parts {
    Get-CimInstance Win32_Process | ForEach-Object {
        $name = $null
        if ($_.Name -eq 'Rainmeter.exe') { $name = 'Rainmeter' }
        elseif ($_.CommandLine -match $pattern) {
            $name = $Matches[0]
            if ($_.CommandLine -match '\s(watch|loop|act)\b|-Action (\w+)') { $name += ' ' + $Matches[1] + $Matches[2] }
        }
        if ($name) { [pscustomobject]@{ Id = $_.ProcessId; Name = $name } }
    }
}

# file rewrites
$writes = @{}
$watcher = New-Object IO.FileSystemWatcher $res, '*.inc'
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true
foreach ($ev in 'Changed', 'Renamed', 'Created') {
    Register-ObjectEvent $watcher $ev -SourceIdentifier "isl-$ev" | Out-Null
}

$start = @{}; $ram = @{}; $samples = @{}; $names = @{}; $seen = @{}
$t0 = Get-Date
$steps = [Math]::Max(1, [int]($Seconds / 5))
for ($i = 0; $i -le $steps; $i++) {
    foreach ($p in Get-Parts) {
        $proc = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        if (-not $seen.ContainsKey($p.Id)) { $seen[$p.Id] = $true; $names[$p.Id] = $p.Name; $start[$p.Id] = @($proc.TotalProcessorTime.TotalMilliseconds, (Get-Date)) }
        $ram[$p.Id] = [double]$ram[$p.Id] + $proc.WorkingSet64 / 1MB
        $samples[$p.Id] = [int]$samples[$p.Id] + 1
        $start[$p.Id] = @($start[$p.Id][0], $start[$p.Id][1], $proc.TotalProcessorTime.TotalMilliseconds, (Get-Date))
    }
    foreach ($e in Get-Event -ErrorAction SilentlyContinue) {
        if ($e.SourceIdentifier -like 'isl-*') {
            $f = Split-Path -Leaf $e.SourceEventArgs.FullPath
            if ($f -like '*.inc') { $writes[$f] = [int]$writes[$f] + 1 }
        }
        Remove-Event -EventIdentifier $e.EventIdentifier
    }
    if ($i -lt $steps) { Start-Sleep -Seconds 5 }
}
foreach ($ev in 'Changed', 'Renamed', 'Created') { Unregister-Event "isl-$ev" -ErrorAction SilentlyContinue }
$mins = ((Get-Date) - $t0).TotalMinutes

$cores = [Environment]::ProcessorCount
$rows = foreach ($id in $seen.Keys) {
    $s = $start[$id]
    $cpu = if ($s.Count -ge 4 -and ($s[3] - $s[1]).TotalMilliseconds -gt 0) { ($s[2] - $s[0]) / ($s[3] - $s[1]).TotalMilliseconds * 100 } else { 0 }
    [pscustomobject]@{ Part = $names[$id]; PID = $id; 'CPU % of one core' = [Math]::Round($cpu, 2); 'RAM MB' = [Math]::Round($ram[$id] / $samples[$id], 1) }
}
$rows = $rows | Sort-Object 'CPU % of one core' -Descending
$total = ($rows | Measure-Object 'CPU % of one core' -Sum).Sum
$text = @(
    "Dynamic Island measurement '$Label', $([Math]::Round($mins, 1)) min, $cores cores"
    ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
    "Total: $([Math]::Round($total, 2)) % of one core ($([Math]::Round($total / $cores, 2)) % of the whole CPU), RAM $([Math]::Round(($rows | Measure-Object 'RAM MB' -Sum).Sum, 0)) MB"
    "Processes seen: $($seen.Count) (more than the running ones = helpers started and ended meanwhile)"
    "File change events per minute (rough, one write can show as 2): " + (($writes.Keys | Sort-Object | ForEach-Object { "$_ $([Math]::Round($writes[$_] / $mins, 1))" }) -join ', ')
) -join "`r`n"
$text
$text | Set-Content (Join-Path $res "measure-$Label.txt") -Encoding utf8
$nc = Join-Path $HOME 'Nextcloud\Claude\dynamic-island'
if (Test-Path $nc) { $text | Set-Content (Join-Path $nc "measure-$Label.txt") -Encoding utf8 }
