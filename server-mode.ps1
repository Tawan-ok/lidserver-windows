# Manual control for server mode.
#   server-mode.ps1 on       pause background apps, mute, turn the display off
#   server-mode.ps1 off      resume everything
#   server-mode.ps1 status   current temperature, mode and agent state
#   server-mode.ps1 report   temperature summary by lid state (default: last 24 hours)
param(
    [ValidateSet('on', 'off', 'status', 'report')][string]$Action = 'status',
    [int]$Hours = 24
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

switch ($Action) {
    'on' {
        $state = Enter-ServerMode 'manual'
        "Server mode ON ($($state.reason)). Paused $(@($state.suspended).Count) processes."
        "Bring everything back with: server-off.cmd"
    }
    'off' {
        $count = Exit-ServerMode
        "Server mode OFF. Resumed $count processes."
    }
    'status' {
        $r = Get-Reading
        $state = Get-ServerModeState
        $mode = 'off'
        if ($state.on) { $mode = "ON ($($state.reason)) since $($state.since), $(@($state.suspended).Count) processes paused" }
        $power = 'battery'
        if ($r.OnAC) { $power = 'AC' }
        "Temperature : $($r.TempC) C"
        "CPU         : $($r.CpuPct) %"
        "Power       : $power, battery $($r.BatteryPct) %"
        "Server mode : $mode"
        "Agent       : $(if (Test-AgentRunning) { 'running' } else { 'NOT running (run install.ps1)' })"
        "Power plan  : $((powercfg /getactivescheme) -replace '^.*\((.*)\)\s*$', '$1')"
    }
    'report' {
        $since = (Get-Date).AddHours(-$Hours)
        $rows = Get-ChildItem (Join-Path $script:LogDir 'temps-*.csv') -ErrorAction SilentlyContinue |
            ForEach-Object { Import-Csv $_.FullName } |
            Where-Object { $_.tempC -and ([datetime]$_.time) -ge $since }
        if (-not $rows) { "No readings in the last $Hours hours."; return }

        "Readings in the last $Hours hours: $(@($rows).Count)"
        $rows | Group-Object lid | ForEach-Object {
            $m = $_.Group | ForEach-Object { [double]$_.tempC } | Measure-Object -Average -Maximum -Minimum
            [pscustomobject]@{
                Lid      = $_.Name
                Readings = $_.Count
                MinC     = $m.Minimum
                AvgC     = [math]::Round($m.Average, 1)
                MaxC     = $m.Maximum
            }
        } | Format-Table -AutoSize | Out-String

        $top = $rows | Sort-Object { [double]$_.tempC } -Descending | Select-Object -First 1
        "Hottest: $($top.tempC) C at $($top.time) (CPU $($top.cpuPct)%, lid $($top.lid), mode $($top.mode))"
    }
}
