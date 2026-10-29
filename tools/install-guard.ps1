# Installs the Dynamic Island guard (island_guard.py) as a Task Scheduler task for this user:
# at logon and every 10 minutes, silent (pythonw). Run once:
#   powershell -ExecutionPolicy Bypass -File tools\install-guard.ps1
# Remove it again with: Unregister-ScheduledTask -TaskName 'DynamicIsland Guard' -Confirm:$false

$py = (Get-Command pythonw -ErrorAction Stop).Source
$script = Join-Path $PSScriptRoot 'island_guard.py'
$action = New-ScheduledTaskAction -Execute $py -Argument "`"$script`"" -WorkingDirectory $PSScriptRoot
$every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
$desc = 'Keeps the Dynamic Island Rainmeter skin running (tools\island_guard.py)'
try {
    $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    Register-ScheduledTask -TaskName 'DynamicIsland Guard' -Action $action -Trigger $logon, $every -Settings $settings `
        -Description $desc -Force -ErrorAction Stop | Out-Null
    'Guard installed: at logon and every 10 minutes.'
} catch {
    # a logon trigger can need admin rights: the 10-minute one alone covers logon too
    Register-ScheduledTask -TaskName 'DynamicIsland Guard' -Action $action -Trigger $every -Settings $settings `
        -Description $desc -Force | Out-Null
    'Guard installed: every 10 minutes.'
}
