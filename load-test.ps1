# CPU load test: idle baseline, all threads busy, then cooldown. Logs temperature every few seconds.
# Stops the load early if the temperature reaches -AbortTempC (kept below the agent's 95 C hibernate).
# Usage: .\load-test.ps1 -Label before-cleaning
param(
    [int]$BaselineSeconds = 60,
    [int]$LoadSeconds = 480,
    [int]$CooldownSeconds = 120,
    [int]$AbortTempC = 93,
    [int]$SampleSeconds = 10,
    [string]$Label = 'run'
)
$ErrorActionPreference = 'Stop'

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$csv = Join-Path $logDir "loadtest-$stamp-$Label.csv"
$summaryFile = Join-Path $logDir "loadtest-$stamp-$Label.txt"

function Get-Sample {
    $s = (Get-Counter '\Thermal Zone Information(*)\Temperature', '\Processor Information(_Total)\% Processor Performance', '\Processor Information(_Total)\% Processor Utility').CounterSamples
    $temps = @($s | Where-Object { $_.Path -like '*temperature*' } | ForEach-Object { $_.CookedValue - 273.15 })
    [pscustomobject]@{
        TempC    = [math]::Round(($temps | Measure-Object -Maximum).Maximum, 1)
        ClockPct = [math]::Round(($s | Where-Object { $_.Path -like '*processor performance*' }).CookedValue)
        UtilPct  = [math]::Round(($s | Where-Object { $_.Path -like '*processor utility*' }).CookedValue)
    }
}

$rows = New-Object System.Collections.Generic.List[object]
function Invoke-Phase([string]$Phase, [int]$Seconds, [bool]$WatchAbort) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $Seconds) {
        $x = Get-Sample
        $row = [pscustomobject]@{
            Time = (Get-Date -Format 'HH:mm:ss'); Phase = $Phase
            Elapsed = [int]((Get-Date) - $start).TotalSeconds
            TempC = $x.TempC; ClockPct = $x.ClockPct; UtilPct = $x.UtilPct
        }
        $rows.Add($row)
        $row | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding ASCII
        "{0} {1,-8} t+{2,3}s temp={3}C clock={4}% util={5}%" -f $row.Time, $Phase, $row.Elapsed, $row.TempC, $row.ClockPct, $row.UtilPct
        if ($WatchAbort -and $x.TempC -ge $AbortTempC) { return $true }
        Start-Sleep -Seconds ([math]::Max(1, $SampleSeconds - 1))
    }
    return $false
}

$plan = (powercfg /getactivescheme) -replace '.*\((.*)\).*', '$1'
$threads = [Environment]::ProcessorCount
"Plan: $plan | threads: $threads | abort at: $AbortTempC C | log: $csv"

# Keep the desktop usable while every thread is busy.
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'

$aborted = $false
$sync = [hashtable]::Synchronized(@{ Stop = $false })
$pool = $null
$workers = @()
try {
    $out = Invoke-Phase 'baseline' $BaselineSeconds $false
    $out | Where-Object { $_ -is [string] }

    $pool = [runspacefactory]::CreateRunspacePool($threads, $threads)
    $pool.Open()
    $work = {
        param($sync)
        $x = 0.0
        while (-not $sync.Stop) { for ($i = 0; $i -lt 200000; $i++) { $x += [math]::Sqrt($i) } }
    }
    $workers = 1..$threads | ForEach-Object {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($work).AddArgument($sync)
        @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $out = Invoke-Phase 'load' $LoadSeconds $true
    $out | Where-Object { $_ -is [string] }
    $aborted = [bool]($out | Where-Object { $_ -is [bool] } | Select-Object -Last 1)
}
finally {
    $sync.Stop = $true
    foreach ($w in $workers) { try { [void]$w.PS.EndInvoke($w.Handle) } catch {} ; $w.PS.Dispose() }
    if ($pool) { $pool.Close(); $pool.Dispose() }
}

$out = Invoke-Phase 'cooldown' $CooldownSeconds $false
$out | Where-Object { $_ -is [string] }

$base = $rows | Where-Object Phase -eq 'baseline'
$load = $rows | Where-Object Phase -eq 'load'
$cool = $rows | Where-Object Phase -eq 'cooldown'
$loadEnd = ($load | Select-Object -Last 1).Elapsed
$steady = $load | Where-Object { $_.Elapsed -ge ($loadEnd - 120) }
function First-Reach([int]$t) { $r = $load | Where-Object { $_.TempC -ge $t } | Select-Object -First 1; if ($r) { "$($r.Elapsed)s" } else { 'never' } }

$summary = @(
    "LOAD TEST $Label  $stamp"
    "Plan: $plan | threads loaded: $threads"
    "Baseline avg temp:      $([math]::Round(($base | Measure-Object TempC -Average).Average, 1)) C"
    "Load duration:          ${loadEnd}s$(if ($aborted) { "  ABORTED at $AbortTempC C" })"
    "Load peak temp:         $(($load | Measure-Object TempC -Maximum).Maximum) C"
    "Load last-2-min avg:    $([math]::Round(($steady | Measure-Object TempC -Average).Average, 1)) C"
    "Load avg clock / util:  $([math]::Round(($load | Measure-Object ClockPct -Average).Average))% / $([math]::Round(($load | Measure-Object UtilPct -Average).Average))%"
    "Lowest clock in load:   $(($load | Measure-Object ClockPct -Minimum).Minimum)%"
    "Time to reach 80 C:     $(First-Reach 80)"
    "Time to reach 88 C:     $(First-Reach 88)"
    "Cooldown end temp:      $(($cool | Select-Object -Last 1).TempC) C after $(($cool | Select-Object -Last 1).Elapsed)s"
)
$summary | Out-File -FilePath $summaryFile -Encoding ASCII
''
$summary
