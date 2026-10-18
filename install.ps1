# Makes the agent start at every logon, then starts it now. No admin rights needed.
# Safe to run again after editing files or moving the folder.

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$taskName = 'LidServer'
$agent = Join-Path $PSScriptRoot 'agent.ps1'
# Launched through a headless conhost so the agent owns no terminal window. A plain
# "powershell -WindowStyle Hidden" gets hosted by Windows Terminal and dies when the
# user closes that terminal.
$arguments = "--headless powershell.exe -NoProfile -File `"$agent`""
$user = "$env:USERDOMAIN\$env:USERNAME"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

$method = $null
try {
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments -WorkingDirectory $PSScriptRoot
    # The repeating trigger restarts a dead agent within 5 minutes; while it is alive,
    # MultipleInstances IgnoreNew makes each repeat a no-op.
    $trigger = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $user),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5))
    )
    # Task Scheduler defaults would stop the agent on battery and after 72 hours.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'LidServer: thermal/battery watchdog and lid trigger.' -Force -ErrorAction Stop | Out-Null
    Remove-ItemProperty -Path $runKey -Name $taskName -ErrorAction SilentlyContinue
    $method = 'scheduled task'
} catch {
    "Scheduled task not allowed without admin ($($_.Exception.Message.Trim())). Using the Run key instead."
    Set-ItemProperty -Path $runKey -Name $taskName -Value "conhost.exe $arguments"
    $method = 'HKCU Run key'
}

if (Test-AgentRunning) {
    "Agent already running. To load changed code, run uninstall.ps1 then install.ps1."
} else {
    if ($method -eq 'scheduled task') { Start-ScheduledTask -TaskName $taskName }
    else { Start-Process conhost.exe -ArgumentList $arguments -WindowStyle Hidden }
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-AgentRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}

"Autostart : $method"
"Agent     : $(if (Test-AgentRunning) { 'running' } else { 'FAILED to start - see logs\agent.log' })"
