# Stops the agent, resumes any paused apps and removes autostart.
# Leaves config, logs and the power plan untouched.

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$taskName = 'LidServer'
$agent = Join-Path $PSScriptRoot 'agent.ps1'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    "Removed scheduled task."
}
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $taskName -ErrorAction SilentlyContinue

$stopped = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($agent) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $stopped++ }
"Stopped $stopped agent process(es)."

$count = Exit-ServerMode
"Resumed $count paused processes."
