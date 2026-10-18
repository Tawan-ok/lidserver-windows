# Shared helpers for LidServer.
# Keep this file ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$script:Root = Split-Path -Parent $PSScriptRoot
$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:StateDir = Join-Path $script:Root 'state'
$script:StatePath = Join-Path $script:StateDir 'server-mode.json'
$script:LogDir = Join-Path $script:Root 'logs'
$script:AgentMutexName = 'Local\LidServerAgent'
$script:LastAlert = @{}

# state\ and logs\ are not in the repo; a fresh clone creates them on first use.
foreach ($dir in $script:StateDir, $script:LogDir) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# Never paused, even if someone adds them to pauseApps in config.json.
$script:Protected = @(
    'python', 'pythonw', 'py', 'terminal64', 'metatester64', 'powershell', 'pwsh', 'cmd', 'conhost',
    'windowsterminal', 'openconsole', 'explorer', 'claude', 'node', 'code', 'dwm', 'csrss', 'winlogon',
    'services', 'lsass', 'svchost', 'system', 'idle', 'sihost', 'taskhostw', 'ctfmon', 'fontdrvhost'
)

Add-Type -AssemblyName System.Windows.Forms

if (-not ('LidServer.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace LidServer
{
    public static class Native
    {
        const uint PROCESS_SUSPEND_RESUME = 0x0800;

        [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr handle);
        [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        public static bool Suspend(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
            if (h == IntPtr.Zero) return false;
            try { return NtSuspendProcess(h) == 0; } finally { CloseHandle(h); }
        }

        public static bool Resume(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
            if (h == IntPtr.Zero) return false;
            try { return NtResumeProcess(h) == 0; } finally { CloseHandle(h); }
        }

        // PostMessage, not SendMessage: a broadcast SendMessage blocks on any hung (or paused) window.
        public static void DisplayOff()
        {
            PostMessage((IntPtr)0xFFFF, 0x0112, (IntPtr)0xF170, (IntPtr)2);
        }
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        int f(); int g(); int h(); int i();
        int SetMasterVolumeLevelScalar(float level, Guid context);
        int j();
        int GetMasterVolumeLevelScalar(out float level);
        int k(); int l(); int m(); int n();
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, Guid context);
        int GetMute(out bool mute);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume endpoint);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int f();
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    public static class Audio
    {
        static IAudioEndpointVolume Endpoint()
        {
            var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
            IMMDevice device = null;
            Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out device));
            IAudioEndpointVolume endpoint = null;
            Guid id = typeof(IAudioEndpointVolume).GUID;
            Marshal.ThrowExceptionForHR(device.Activate(ref id, 23, 0, out endpoint));
            return endpoint;
        }

        public static bool Mute
        {
            get { bool mute; Marshal.ThrowExceptionForHR(Endpoint().GetMute(out mute)); return mute; }
            set { Marshal.ThrowExceptionForHR(Endpoint().SetMute(value, Guid.Empty)); }
        }
    }
}
'@
}

function Get-ServerConfig {
    Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
}

function Write-AgentLog([string]$Message) {
    $line = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Message"
    try { Add-Content -Path (Join-Path $script:LogDir 'agent.log') -Value $line -Encoding utf8 } catch { }
}

# Temperature comes from the ACPI thermal zone, readable without admin rights.
function Get-Reading {
    $temp = $null
    try {
        $zones = Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop
        $max = ($zones | Measure-Object HighPrecisionTemperature -Maximum).Maximum
        if ($max -gt 0) { $temp = [math]::Round($max / 10 - 273.15, 1) }
    } catch { }

    $cpu = $null
    try {
        $proc = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
        $cpu = [int]$proc.PercentProcessorUtility
    } catch { }

    $power = [System.Windows.Forms.SystemInformation]::PowerStatus
    [pscustomobject]@{
        Time       = Get-Date
        TempC      = $temp
        CpuPct     = $cpu
        BatteryPct = [int][math]::Round($power.BatteryLifePercent * 100)
        OnAC       = ($power.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online)
    }
}

# Logs every alert; also posts to Discord when a webhook is configured.
# With -Key, the same alert repeats at most once per alerts.repeatMinutes.
function Send-Alert([string]$Message, [string]$Key = '') {
    $cfg = Get-ServerConfig
    if ($Key) {
        $last = $script:LastAlert[$Key]
        if ($last -and ((Get-Date) - $last).TotalMinutes -lt $cfg.alerts.repeatMinutes) { return }
        $script:LastAlert[$Key] = Get-Date
    }
    Write-AgentLog "ALERT $Message"
    $url = $cfg.alerts.discordWebhookUrl
    if (-not $url) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = @{ content = "[$env:COMPUTERNAME] $Message" } | ConvertTo-Json
        Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
    } catch {
        Write-AgentLog "alert delivery failed: $($_.Exception.Message)"
    }
}

function New-ServerModeState {
    [pscustomobject]@{ on = $false; reason = ''; since = ''; mutedByUs = $false; suspended = @() }
}

function Get-ServerModeState {
    if (Test-Path $script:StatePath) {
        try { return (Get-Content $script:StatePath -Raw | ConvertFrom-Json) } catch { }
    }
    New-ServerModeState
}

function Save-ServerModeState($State) {
    $State | ConvertTo-Json -Depth 4 | Set-Content -Path $script:StatePath -Encoding utf8
}

function Get-PausableProcess([string[]]$Names) {
    $session = (Get-Process -Id $PID).SessionId
    $want = @($Names | Where-Object { $script:Protected -notcontains $_.ToLower() })
    Get-Process | Where-Object { $_.SessionId -eq $session -and $want -contains $_.Name }
}

function Suspend-Apps([string[]]$Names) {
    foreach ($p in Get-PausableProcess $Names) {
        try { $start = $p.StartTime.ToFileTimeUtc().ToString() } catch { continue }
        if ([LidServer.Native]::Suspend($p.Id)) {
            [pscustomobject]@{ pid = $p.Id; name = $p.Name; start = $start }
        }
    }
}

# Resumes only processes whose PID and start time both match what was recorded,
# so a recycled PID is never touched.
function Resume-Apps($List) {
    $count = 0
    foreach ($s in @($List)) {
        if (-not $s) { continue }
        $p = Get-Process -Id $s.pid -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        try { if ($p.StartTime.ToFileTimeUtc().ToString() -ne [string]$s.start) { continue } } catch { continue }
        if ([LidServer.Native]::Resume($s.pid)) { $count++ }
    }
    $count
}

# Safety net for a crash between pausing and saving state: any listed app whose
# threads are all suspended gets resumed. Resuming a running process is a no-op.
function Resume-StuckApps([string[]]$Names) {
    $count = 0
    foreach ($p in Get-PausableProcess $Names) {
        try {
            $threads = @($p.Threads)
            if ($threads.Count -eq 0) { continue }
            $stuck = @($threads | Where-Object { $_.ThreadState -eq 'Wait' -and $_.WaitReason -eq 'Suspended' })
            if ($stuck.Count -eq $threads.Count -and [LidServer.Native]::Resume($p.Id)) { $count++ }
        } catch { }
    }
    $count
}

# Reason is 'manual', 'lid' or 'thermal'. A thermal pause only freezes apps: the
# user may be sitting at the screen, so the display and audio are left alone.
function Enter-ServerMode([string]$Reason) {
    $cfg = Get-ServerConfig
    $state = Get-ServerModeState
    if ($state.on) { return $state }

    $quiet = ($Reason -ne 'thermal')
    $mutedByUs = $false
    if ($quiet -and $cfg.serverMode.muteAudio) {
        try {
            if (-not [LidServer.Audio]::Mute) { [LidServer.Audio]::Mute = $true; $mutedByUs = $true }
        } catch { Write-AgentLog "mute failed: $($_.Exception.Message)" }
    }

    $suspended = @(Suspend-Apps $cfg.serverMode.pauseApps)
    $state = [pscustomobject]@{
        on        = $true
        reason    = $Reason
        since     = (Get-Date).ToString('s')
        mutedByUs = $mutedByUs
        suspended = $suspended
    }
    Save-ServerModeState $state

    if ($quiet -and $cfg.serverMode.displayOff) { [LidServer.Native]::DisplayOff() }
    Write-AgentLog "server mode ON ($Reason): paused $($suspended.Count) processes"
    $state
}

function Exit-ServerMode {
    $cfg = Get-ServerConfig
    $state = Get-ServerModeState
    $count = Resume-Apps $state.suspended
    $count += Resume-StuckApps $cfg.serverMode.pauseApps
    if ($state.mutedByUs) {
        try { [LidServer.Audio]::Mute = $false } catch { Write-AgentLog "unmute failed: $($_.Exception.Message)" }
    }
    Save-ServerModeState (New-ServerModeState)
    if ($state.on -or $count -gt 0) { Write-AgentLog "server mode OFF: resumed $count processes" }
    $count
}

function Test-AgentRunning {
    try {
        $m = [System.Threading.Mutex]::OpenExisting($script:AgentMutexName)
        $m.Dispose()
        $true
    } catch { $false }
}
