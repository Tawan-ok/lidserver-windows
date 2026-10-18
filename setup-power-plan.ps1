# Creates (or updates) the "LidServer 24-7" power plan: never sleeps or hibernates on AC,
# closing the lid does nothing on AC, and CPU turbo is off so the laptop runs cooler.
# Run once. Your current plan is not changed unless you pass -Activate.
#   -Activate               switch to the plan now
#   -KeepRunningOnBattery   also keep running with the lid closed on battery (default: sleep,
#                           so a laptop closed into a bag cannot cook itself)
#   -KeepTurbo              leave CPU turbo boost on (faster, but much hotter)
#   -Remove                 delete the plan (switch to another plan first)
param(
    [switch]$Activate,
    [switch]$KeepRunningOnBattery,
    [switch]$KeepTurbo,
    [switch]$Remove,
    [string]$Name = 'LidServer 24-7'
)
$ErrorActionPreference = 'Stop'

$balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'

function Get-PlanGuid([string]$PlanName) {
    foreach ($line in (powercfg /list)) {
        if ($line -match '([0-9a-fA-F-]{36})\s+\((.+?)\)' -and $Matches[2] -eq $PlanName) { return $Matches[1] }
    }
}

function Invoke-PowerCfg {
    & powercfg.exe @args
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

# value index: AC, DC
function Set-PlanValue([string]$Guid, [string]$Group, [string]$Setting, [int]$Ac, [int]$Dc) {
    Invoke-PowerCfg /setacvalueindex $Guid $Group $Setting $Ac
    Invoke-PowerCfg /setdcvalueindex $Guid $Group $Setting $Dc
}

$guid = Get-PlanGuid $Name

if ($Remove) {
    if (-not $guid) { "No plan named '$Name'."; return }
    Invoke-PowerCfg /delete $guid
    "Deleted plan '$Name' ($guid)."
    return
}

if (-not $guid) {
    $out = powercfg /duplicatescheme $balanced
    if ($LASTEXITCODE -ne 0 -or "$out" -notmatch '([0-9a-fA-F-]{36})') { throw "Could not copy the Balanced plan: $out" }
    $guid = $Matches[1]
    Invoke-PowerCfg /changename $guid $Name 'LidServer: never sleeps on AC, lid close does nothing on AC, turbo off.'
    "Created plan '$Name' ($guid)."
} else {
    "Updating plan '$Name' ($guid)."
}

$batterySleep = 1
$batteryStandby = 900
if ($KeepRunningOnBattery) { $batterySleep = 0; $batteryStandby = 0 }

Set-PlanValue $guid SUB_SLEEP STANDBYIDLE 0 $batteryStandby     # sleep after (seconds, 0 = never)
Set-PlanValue $guid SUB_SLEEP HIBERNATEIDLE 0 0                 # hibernate after
Set-PlanValue $guid SUB_SLEEP UNATTENDSLEEP 0 120               # unattended sleep (hidden setting)
Set-PlanValue $guid SUB_BUTTONS LIDACTION 0 $batterySleep       # lid: 0 = do nothing, 1 = sleep
Set-PlanValue $guid SUB_VIDEO VIDEOIDLE 300 120                 # display off after

if ($KeepTurbo) {
    Set-PlanValue $guid SUB_PROCESSOR PERFBOOSTMODE 2 2         # aggressive (Windows default)
    Set-PlanValue $guid SUB_PROCESSOR PROCTHROTTLEMAX 100 100
} else {
    # Turbo is the main heat source on a closed laptop. 99 % max state also stops turbo on
    # machines that ignore the boost mode setting.
    Set-PlanValue $guid SUB_PROCESSOR PERFBOOSTMODE 0 0
    Set-PlanValue $guid SUB_PROCESSOR PROCTHROTTLEMAX 99 99
}

if ($Activate) {
    Invoke-PowerCfg /setactive $guid
    "Plan '$Name' is now active."
} else {
    "Not activated. Switch to it with: .\setup-power-plan.ps1 -Activate"
}
