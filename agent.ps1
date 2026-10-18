# Background agent: thermal + battery watchdog and lid-close trigger.
# Runs in the user's session (not as a service) because it pauses the user's own
# apps and listens for lid events. Started at logon by install.ps1.
#   -Once   take a single reading, apply the rules, and exit (for testing)
param([switch]$Once)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$script:Lid = 'unknown'
$script:CritCount = 0
$script:CoolCount = 0
$script:OnAC = $null
$script:LowBatteryAlerted = $false
$script:LastTick = Get-Date

function Write-ReadingCsv($Reading, [string]$Mode) {
    $file = Join-Path $script:LogDir ("temps-{0}.csv" -f (Get-Date).ToString('yyyy-MM'))
    if (-not (Test-Path $file)) { Set-Content -Path $file -Value 'time,tempC,cpuPct,batteryPct,onAC,lid,mode' -Encoding utf8 }
    $row = '{0},{1},{2},{3},{4},{5},{6}' -f $Reading.Time.ToString('s'), $Reading.TempC, $Reading.CpuPct,
        $Reading.BatteryPct, $Reading.OnAC, $script:Lid, $Mode
    Add-Content -Path $file -Value $row -Encoding utf8
}

function Test-ExternalDisplay {
    # Lid closed + external monitor = the user is working at the desk, not leaving the laptop.
    # Internal panels report LVDS (6), embedded DisplayPort (11) or INTERNAL (0x80000000).
    try {
        $external = Get-CimInstance -Namespace root\wmi WmiMonitorConnectionParams -ErrorAction Stop |
            Where-Object { $_.Active -and $_.VideoOutputTechnology -notin 6, 11, 2147483648 }
        return [bool]$external
    } catch {
        return $false
    }
}

function Invoke-ThermalRules($Reading, $Cfg) {
    $t = $Reading.TempC
    if ($null -eq $t) { Send-Alert 'Temperature sensor unreadable.' 'sensor'; return }
    $th = $Cfg.thermal
    $state = Get-ServerModeState

    if ($t -ge $th.criticalC) {
        $script:CritCount++
        $script:CoolCount = 0
        if ($script:CritCount -ge $th.criticalReadings) {
            $script:CritCount = 0
            if ($th.criticalAction -eq 'hibernate') {
                Send-Alert "CRITICAL $t C for $($th.criticalReadings) readings. Hibernating now. Bots stop until the laptop is woken."
                & shutdown.exe /h
            } else {
                Send-Alert "CRITICAL $t C for $($th.criticalReadings) readings. No automatic action configured." 'critical'
            }
        } else {
            Send-Alert "CRITICAL $t C (reading $($script:CritCount) of $($th.criticalReadings) before $($th.criticalAction))." 'critical-rising'
        }
        return
    }
    $script:CritCount = 0

    if ($t -ge $th.pauseC) {
        $script:CoolCount = 0
        if (-not $state.on) {
            $new = Enter-ServerMode 'thermal'
            Send-Alert "HOT $t C. Paused $(@($new.suspended).Count) background app processes."
        } else {
            Send-Alert "HOT $t C with background apps already paused." 'hot'
        }
        return
    }

    if ($t -ge $th.warnC) {
        $script:CoolCount = 0
        Send-Alert "Warm: $t C (CPU $($Reading.CpuPct)%)." 'warn'
        return
    }

    # A thermal pause is released only after the temperature has stayed low for a while.
    if ($state.on -and $state.reason -eq 'thermal' -and $t -le $th.cooldownC) {
        $script:CoolCount++
        if ($script:CoolCount -ge $th.cooldownReadings) {
            $script:CoolCount = 0
            Exit-ServerMode | Out-Null
            Send-Alert "Cooled to $t C. Background apps resumed."
        }
    } else {
        $script:CoolCount = 0
    }
}

function Invoke-BatteryRules($Reading, $Cfg) {
    if ($null -ne $script:OnAC -and $script:OnAC -ne $Reading.OnAC) {
        if ($Reading.OnAC) { Send-Alert "Power restored. Battery $($Reading.BatteryPct)%." }
        else { Send-Alert "Power lost. Running on battery at $($Reading.BatteryPct)%." }
    }
    $script:OnAC = $Reading.OnAC

    if ($Reading.OnAC) { $script:LowBatteryAlerted = $false; return }

    # Near empty the gauge falls fast (12 -> 6 % in one minute, then power died before Windows'
    # own 5 % shutdown ran), so the agent shuts down itself while there is still charge left.
    # /t 30 implies /f: paused (suspended) apps can't hold the shutdown up.
    $shutdownPct = $Cfg.battery.shutdownPct
    if ($shutdownPct -and $Reading.BatteryPct -le $shutdownPct) {
        Send-Alert "Battery $($Reading.BatteryPct)% and still unplugged. Shutting down cleanly in 30 s. Bots restart after the laptop is plugged in and switched on." 'battery-shutdown'
        & shutdown.exe /s /t 30 /c "Battery low: the server agent is shutting down cleanly." 2>$null
        return
    }

    if ($Reading.BatteryPct -le $Cfg.battery.lowPct -and -not $script:LowBatteryAlerted) {
        $script:LowBatteryAlerted = $true
        Send-Alert "Battery low: $($Reading.BatteryPct)% and still unplugged. The agent shuts the laptop down at $shutdownPct%."
    }
}

function Invoke-Tick {
    try {
        $now = Get-Date
        $cfg = Get-ServerConfig
        # A long gap means the laptop slept or hibernated; stale counters must not carry over.
        if (($now - $script:LastTick).TotalSeconds -gt ($cfg.pollSeconds * 5)) {
            $script:CritCount = 0
            $script:CoolCount = 0
            Write-AgentLog 'resumed after a gap; counters reset'
        }
        $script:LastTick = $now

        $reading = Get-Reading
        $state = Get-ServerModeState
        if ($state.on -and $state.reason -eq 'lid' -and (Test-ExternalDisplay)) {
            $count = Exit-ServerMode
            Write-AgentLog "external monitor in use: lid server mode OFF, resumed $count processes"
            $state = Get-ServerModeState
        }
        $mode = 'off'
        if ($state.on) { $mode = $state.reason }
        Write-ReadingCsv $reading $mode
        Invoke-ThermalRules $reading $cfg
        Invoke-BatteryRules $reading $cfg
    } catch {
        Write-AgentLog "tick error: $($_.Exception.Message)"
    }
}

function Invoke-LidChange([bool]$Open) {
    try {
        $new = 'closed'
        if ($Open) { $new = 'open' }
        if ($new -eq $script:Lid) { return }
        $script:Lid = $new
        Write-AgentLog "lid $new"

        $cfg = Get-ServerConfig
        $state = Get-ServerModeState
        if (-not $Open) {
            if ($cfg.lid.serverModeOnClose) {
                if (Test-ExternalDisplay) { Write-AgentLog 'external monitor in use: server mode skipped' }
                else { Enter-ServerMode 'lid' | Out-Null }
            }
        } elseif ($state.on -and $state.reason -eq 'lid') {
            Exit-ServerMode | Out-Null
        }
    } catch {
        Write-AgentLog "lid handler error: $($_.Exception.Message)"
    }
}

if ($Once) {
    Invoke-Tick
    return
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $script:AgentMutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-AgentLog 'agent already running; this instance exits'
    return
}

if (-not ('LidServer.LidWindow' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace LidServer
{
    // Invisible window that receives lid open/close notifications from Windows.
    public class LidWindow : Form
    {
        const int WM_POWERBROADCAST = 0x0218;
        const int PBT_POWERSETTINGCHANGE = 0x8013;
        static Guid LidSwitch = new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct POWERBROADCAST_SETTING
        {
            public Guid PowerSetting;
            public uint DataLength;
            public byte Data;
        }

        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, int flags);

        public event Action<bool> LidChanged;

        public LidWindow()
        {
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedToolWindow;
        }

        protected override void SetVisibleCore(bool value)
        {
            if (!IsHandleCreated) CreateHandle();
            base.SetVisibleCore(false);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            RegisterPowerSettingNotification(Handle, ref LidSwitch, 0);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt32() == PBT_POWERSETTINGCHANGE)
            {
                var s = (POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(POWERBROADCAST_SETTING));
                Action<bool> handler = LidChanged;
                if (s.PowerSetting == LidSwitch && handler != null) handler(s.Data != 0);
            }
            base.WndProc(ref m);
        }
    }
}
'@
}

try {
    Write-AgentLog "agent started (pid $PID)"
    $cfg = Get-ServerConfig

    # Windows reports the current lid state right after registration, which also
    # reconciles a lid-triggered pause left over from a crash or reboot.
    $window = New-Object LidServer.LidWindow
    $window.add_LidChanged({ param($open) Invoke-LidChange $open })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [int]$cfg.pollSeconds * 1000
    $timer.add_Tick({ Invoke-Tick })
    $timer.Start()

    Invoke-Tick
    [System.Windows.Forms.Application]::Run($window)
} finally {
    Write-AgentLog 'agent stopped'
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
