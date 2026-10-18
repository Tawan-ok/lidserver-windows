# Safe self-test: checks the scripts and runs the heat, battery and lid rules against fake
# readings. Nothing is paused, muted, shut down or hibernated; those calls are replaced by
# stand-ins that only record what would have happened.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Failed = 0

function Assert([bool]$Condition, [string]$Name) {
    if ($Condition) { "  PASS  $Name" } else { "  FAIL  $Name"; $script:Failed++ }
}

"Files"
foreach ($file in Get-ChildItem $root -Recurse -Include *.ps1, *.cmd, *.json | Where-Object FullName -notmatch '\\(\.git|logs|state)\\') {
    $rel = $file.FullName.Substring($root.Length + 1)
    $nonAscii = @([IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count
    Assert ($nonAscii -eq 0) "$rel is ASCII (PowerShell 5.1 misreads anything else)"
    if ($file.Extension -eq '.ps1') {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        Assert ($errors.Count -eq 0) "$rel parses"
    }
}

$cfg = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
Assert ($cfg.thermal.pauseC -lt $cfg.thermal.criticalC) 'config: pause temperature is below critical'
Assert ($cfg.battery.shutdownPct -lt $cfg.battery.lowPct) 'config: battery shutdown is below the low-battery alert'
Assert (-not $cfg.alerts.discordWebhookUrl) 'config: no Discord webhook committed'

# Load the helpers and the agent's rule functions without starting the agent.
. (Join-Path $root 'lib\common.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'agent.ps1'), [ref]$null, [ref]$null)
$ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

""
"Sensors (read only)"
$r = Get-Reading
"  temperature $($r.TempC) C, CPU $($r.CpuPct) %, battery $($r.BatteryPct) %, on AC $($r.OnAC)"
Assert ($null -ne $r.TempC) 'temperature sensor readable (if this fails, heat rules cannot work on this laptop)'
"  external monitor connected: $(Test-ExternalDisplay)"

# Stand-ins that record instead of acting.
$script:Calls = New-Object System.Collections.Generic.List[string]
$script:FakeState = [pscustomobject]@{ on = $false; reason = '' }
function Send-Alert($Message, $Key) { $script:Calls.Add("alert") }
function Enter-ServerMode($Reason) { $script:Calls.Add("enter:$Reason"); $script:FakeState = [pscustomobject]@{ on = $true; reason = $Reason; suspended = @() }; $script:FakeState }
function Exit-ServerMode { $script:Calls.Add('exit'); $script:FakeState = [pscustomobject]@{ on = $false; reason = '' }; 0 }
function Get-ServerModeState { $script:FakeState }
function shutdown.exe { $script:Calls.Add("shutdown $($args[0])") }
function Write-AgentLog($Message) { }
function Reset-Fakes { $script:Calls.Clear(); $script:FakeState = [pscustomobject]@{ on = $false; reason = '' }; $script:CritCount = 0; $script:CoolCount = 0 }
function New-FakeReading($TempC = 50, $BatteryPct = 100, $OnAC = $true) {
    [pscustomobject]@{ TempC = $TempC; CpuPct = 10; BatteryPct = $BatteryPct; OnAC = $OnAC }
}

""
"Heat rules"
Reset-Fakes; Invoke-ThermalRules (New-FakeReading -TempC 60) $cfg
Assert ($script:Calls.Count -eq 0) '60 C: nothing happens'
Reset-Fakes; Invoke-ThermalRules (New-FakeReading -TempC ($cfg.thermal.warnC + 1)) $cfg
Assert ($script:Calls -contains 'alert' -and $script:Calls -notcontains 'enter:thermal') 'warm: alert only'
Reset-Fakes; Invoke-ThermalRules (New-FakeReading -TempC $cfg.thermal.pauseC) $cfg
Assert ($script:Calls -contains 'enter:thermal') 'hot: background apps paused'
Reset-Fakes
1..$cfg.thermal.criticalReadings | ForEach-Object { Invoke-ThermalRules (New-FakeReading -TempC $cfg.thermal.criticalC) $cfg }
Assert ($script:Calls -contains 'shutdown /h') "critical for $($cfg.thermal.criticalReadings) readings: hibernate"
Reset-Fakes; Invoke-ThermalRules (New-FakeReading -TempC $cfg.thermal.criticalC) $cfg
Assert ($script:Calls -notcontains 'shutdown /h') 'critical once: no hibernate yet'
Reset-Fakes; $script:FakeState = [pscustomobject]@{ on = $true; reason = 'thermal' }
1..$cfg.thermal.cooldownReadings | ForEach-Object { Invoke-ThermalRules (New-FakeReading -TempC $cfg.thermal.cooldownC) $cfg }
Assert ($script:Calls -contains 'exit') "cooled for $($cfg.thermal.cooldownReadings) readings: apps resumed"

""
"Battery rules"
$script:OnAC = $null
Reset-Fakes; Invoke-BatteryRules (New-FakeReading -BatteryPct 5 -OnAC $true) $cfg
Assert ($script:Calls -notcontains 'shutdown /s') 'plugged in at 5 %: keeps charging, no shutdown'
Reset-Fakes; Invoke-BatteryRules (New-FakeReading -BatteryPct 50 -OnAC $false) $cfg
Assert ($script:Calls -contains 'alert' -and $script:Calls -notcontains 'shutdown /s') 'unplugged at 50 %: power-lost alert only'
Reset-Fakes; Invoke-BatteryRules (New-FakeReading -BatteryPct $cfg.battery.shutdownPct -OnAC $false) $cfg
Assert ($script:Calls -contains 'shutdown /s') "unplugged at $($cfg.battery.shutdownPct) %: clean shutdown"

""
"Lid rules"
function Test-ExternalDisplay { $false }
Reset-Fakes; $script:Lid = 'open'; Invoke-LidChange $false
Assert ($script:Calls -contains 'enter:lid') 'lid closed, no monitor: server mode on'
Reset-Fakes; $script:FakeState = [pscustomobject]@{ on = $true; reason = 'lid' }; $script:Lid = 'closed'; Invoke-LidChange $true
Assert ($script:Calls -contains 'exit') 'lid opened: server mode off'
function Test-ExternalDisplay { $true }
Reset-Fakes; $script:Lid = 'open'; Invoke-LidChange $false
Assert ($script:Calls -notcontains 'enter:lid') 'lid closed with external monitor: server mode skipped'

""
if ($script:Failed) { "$script:Failed check(s) FAILED."; exit 1 }
"All checks passed."
