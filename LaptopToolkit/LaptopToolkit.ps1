# LaptopToolkit v3 - Skytech Noir (Ryzen 7 8845HS / DDR5-5600 / RTX 4070 Laptop до 140 Вт)
# Файл должен быть в UTF-8 с BOM: иначе Windows PowerShell 5.1 ломает кириллицу.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    } catch { }
    [Environment]::Exit(0)
}

$ProgressPreference = 'SilentlyContinue'
$Version = '3.0'

# ---------------- нативные функции ----------------
# Этот же код сохраняется в ProgramData и используется агентом автопереключения,
# поэтому только C# 5 (компилятор Windows PowerShell 5.1) и без LINQ.
$CsSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LTK
{
    public static class Win
    {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORYSTATUSEX
        {
            public uint dwLength; public uint dwMemoryLoad;
            public ulong ullTotalPhys; public ulong ullAvailPhys;
            public ulong ullTotalPageFile; public ulong ullAvailPageFile;
            public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);

        // [0] - всего байт, [1] - свободно байт
        public static ulong[] Memory()
        {
            MEMORYSTATUSEX m = new MEMORYSTATUSEX();
            m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            if (!GlobalMemoryStatusEx(ref m)) return new ulong[] { 0, 0 };
            return new ulong[] { m.ullTotalPhys, m.ullAvailPhys };
        }
    }

    public static class Pwr
    {
        [StructLayout(LayoutKind.Sequential)]
        struct SYSTEM_POWER_STATUS
        {
            public byte ACLineStatus; public byte BatteryFlag; public byte BatteryLifePercent; public byte SystemStatusFlag;
            public int BatteryLifeTime; public int BatteryFullLifeTime;
        }
        [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
        [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
        [DllImport("powrprof.dll")] static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
        [DllImport("powrprof.dll")] static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, out uint value);
        [DllImport("powrprof.dll")] static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, out uint value);
        [DllImport("powrprof.dll")] static extern uint PowerWriteACValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, uint value);
        [DllImport("powrprof.dll")] static extern uint PowerWriteDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, uint value);
        [DllImport("powrprof.dll")] static extern uint PowerSetActiveOverlayScheme(Guid overlay);
        [DllImport("powrprof.dll")] static extern uint PowerGetEffectiveOverlayScheme(out Guid overlay);

        static SYSTEM_POWER_STATUS Status()
        {
            SYSTEM_POWER_STATUS s;
            if (!GetSystemPowerStatus(out s)) { s = new SYSTEM_POWER_STATUS(); s.ACLineStatus = 255; s.BatteryLifePercent = 255; s.BatteryLifeTime = -1; }
            return s;
        }
        // 1 - от сети, 0 - от батареи, -1 - неизвестно
        public static int OnAC() { byte a = Status().ACLineStatus; return a == 1 ? 1 : (a == 0 ? 0 : -1); }
        public static int BatteryPercent() { byte p = Status().BatteryLifePercent; return p > 100 ? -1 : p; }
        public static int BatterySeconds() { return Status().BatteryLifeTime; }
        public static bool HasBattery() { byte f = Status().BatteryFlag; return f != 128 && f != 255; }

        public static string ActiveScheme()
        {
            IntPtr p;
            if (PowerGetActiveScheme(IntPtr.Zero, out p) != 0) return "";
            Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
            LocalFree(p);
            return g.ToString();
        }
        // -1 - такой настройки нет в системе
        public static long Read(string scheme, string sub, string setting, bool dc)
        {
            Guid sc = new Guid(scheme), s = new Guid(sub), st = new Guid(setting);
            uint v;
            uint r = dc ? PowerReadDCValueIndex(IntPtr.Zero, ref sc, ref s, ref st, out v)
                        : PowerReadACValueIndex(IntPtr.Zero, ref sc, ref s, ref st, out v);
            return r == 0 ? (long)v : -1;
        }
        public static uint Write(string scheme, string sub, string setting, bool dc, uint value)
        {
            Guid sc = new Guid(scheme), s = new Guid(sub), st = new Guid(setting);
            return dc ? PowerWriteDCValueIndex(IntPtr.Zero, ref sc, ref s, ref st, value)
                      : PowerWriteACValueIndex(IntPtr.Zero, ref sc, ref s, ref st, value);
        }
        // Изменения схемы вступают в силу после повторной активации.
        public static uint Apply()
        {
            string a = ActiveScheme();
            if (a.Length == 0) return 1;
            Guid g = new Guid(a);
            return PowerSetActiveScheme(IntPtr.Zero, ref g);
        }
        public static uint SetOverlay(string overlay) { return PowerSetActiveOverlayScheme(new Guid(overlay)); }
        public static string GetOverlay()
        {
            Guid g;
            try { if (PowerGetEffectiveOverlayScheme(out g) != 0) return ""; } catch { return ""; }
            return g.ToString();
        }
    }

    public static class Disp
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
            public int dmFields;
            public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
            public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
            public int dmDisplayFlags; public int dmDisplayFrequency;
            public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
            public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);

        const int ENUM_CURRENT_SETTINGS = -1;
        const int DM_PELSWIDTH = 0x80000, DM_PELSHEIGHT = 0x100000, DM_DISPLAYFREQUENCY = 0x400000;
        const uint CDS_UPDATEREGISTRY = 1;

        static DEVMODE Create() { DEVMODE d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return d; }

        // Частота основного экрана, Гц (0 - не удалось узнать)
        public static int Current()
        {
            DEVMODE d = Create();
            return EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref d) ? d.dmDisplayFrequency : 0;
        }
        // Доступные частоты при текущем разрешении, по возрастанию
        public static int[] Rates()
        {
            DEVMODE cur = Create();
            if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref cur)) return new int[0];
            List<int> list = new List<int>();
            DEVMODE d = Create();
            for (int i = 0; EnumDisplaySettings(null, i, ref d); i++)
            {
                if (d.dmPelsWidth == cur.dmPelsWidth && d.dmPelsHeight == cur.dmPelsHeight &&
                    d.dmBitsPerPel == cur.dmBitsPerPel && d.dmDisplayFrequency > 1 && !list.Contains(d.dmDisplayFrequency))
                    list.Add(d.dmDisplayFrequency);
            }
            list.Sort();
            return list.ToArray();
        }
        // 0 - успешно (или уже стоит), иначе код DISP_CHANGE_*
        public static int Set(int hz)
        {
            DEVMODE d = Create();
            if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref d)) return -100;
            if (d.dmDisplayFrequency == hz) return 0;
            d.dmDisplayFrequency = hz;
            d.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
            return ChangeDisplaySettingsEx(null, ref d, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
        }
    }
}
'@
Add-Type -TypeDefinition $CsSource
[void][LTK.Win]::SetProcessDPIAware()      # иначе на 2K-экране со 150% всё размыто
[void][LTK.Win]::ShowWindow([LTK.Win]::GetConsoleWindow(), 0)   # консоль нужна только для ошибок запуска

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# ---------------- общие данные ----------------
$Desktop   = [Environment]::GetFolderPath('Desktop')   # учитывает перенос рабочего стола в OneDrive
$ReportDir = Join-Path $Desktop 'LaptopToolkit'
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

# Служебные файлы (журнал отката, агент) - в ProgramData, доступ на запись только у администраторов.
$DataDir     = Join-Path $env:ProgramData 'LaptopToolkit'
$JournalPath = Join-Path $DataDir 'undo.json'
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
& icacls.exe $DataDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1 | Out-Null

$Smi = $null
$smiCmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smiCmd) { $Smi = $smiCmd.Source }
elseif (Test-Path "$env:SystemRoot\System32\nvidia-smi.exe") { $Smi = "$env:SystemRoot\System32\nvidia-smi.exe" }

$MaxMHz = (Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed
$OsBuild = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
$script:Log = New-Object Text.StringBuilder
$script:Busy = $false
$script:BusyName = ''
$script:Cat = $null
$script:StressJobs = @()
$script:StressEnd = $null
$script:StressGHz = New-Object Collections.Generic.List[double]
$script:GpuPeak = 0.0
$script:NoBatWmi = $false

# Режимы питания Windows (ползунок «Режим питания»)
$OV_EFF  = '961cc777-2547-4f9d-8174-7d86181b8a7a'
$OV_BAL  = '00000000-0000-0000-0000-000000000000'
$OV_PERF = 'ded574b5-45a0-4f42-8737-46345c09c238'
$OverlayNames = @{
    $OV_EFF  = 'Лучшая энергоэффективность'
    $OV_BAL  = 'Сбалансированный'
    $OV_PERF = 'Максимальная производительность'
    '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'Лучшее время работы (Win10)'
}

# Параметры схемы питания: подгруппа / настройка
$PW = @{
    Proc = '54533251-82be-4824-96c1-47b60b740d00'; Boost = 'be337238-0d82-4146-a960-4f3749d470c7'; Epp = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
    Video = '7516b95f-f776-4464-8c53-06167f40cc99'; ScreenOff = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
    Sleep = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; SleepAfter = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; HibAfter = '9d7815a6-7ee4-497e-8888-515a05f02364'
    None = 'fea3413e-7e05-4911-9a71-700331f1c294'; NetStandby = 'f15576e8-98b7-4186-b944-eafa664402d9'
    Pcie = '501a4d13-42af-4429-9fd1-a8218c268e20'; Aspm = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
    Usb = '2a737441-1930-4402-8d77-b2bebba308a3'; UsbSuspend = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    Wifi = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; WifiSave = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
    Saver = 'de830923-a562-41af-a086-e3a2c6bad2da'; SaverAt = 'e69653ca-cf7f-4f05-aa73-cb833fa90ad4'
    Media = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'; VideoPlay = '34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4'
}

# ---------------- окно ----------------
$g0 = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = [math]::Max(1.0, $g0.DpiX / 96.0)
$g0.Dispose()
function Px([double]$n) { [int][math]::Round($n * $script:Scale) }
function Sz([double]$w, [double]$h) { New-Object Drawing.Size((Px $w), (Px $h)) }
function Pad([double]$l, [double]$t, [double]$r, [double]$b) { New-Object Windows.Forms.Padding((Px $l), (Px $t), (Px $r), (Px $b)) }

$bg      = [Drawing.Color]::FromArgb(24, 26, 31)
$panel   = [Drawing.Color]::FromArgb(34, 37, 44)
$panel2  = [Drawing.Color]::FromArgb(46, 50, 59)
$accent  = [Drawing.Color]::FromArgb(0, 170, 150)
$accentD = [Drawing.Color]::FromArgb(0, 120, 106)
$fg      = [Drawing.Color]::FromArgb(230, 230, 230)
$cDim    = [Drawing.Color]::FromArgb(150, 156, 168)
$cOk     = [Drawing.Color]::FromArgb(95, 205, 125)
$cWarn   = [Drawing.Color]::FromArgb(240, 175, 60)
$cErr    = [Drawing.Color]::FromArgb(240, 95, 95)

$form = New-Object Windows.Forms.Form
$form.Text = "Laptop Toolkit v$Version - Skytech Noir (R7 8845HS / RTX 4070)"
$form.AutoScaleMode = 'None'
$form.Size = Sz 1220 820
$form.MinimumSize = Sz 940 600
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$form.ForeColor = $fg
$form.Font = New-Object Drawing.Font('Segoe UI', 9)

$tips = New-Object Windows.Forms.ToolTip
$tips.AutoPopDelay = 20000; $tips.InitialDelay = 400

$left = New-Object Windows.Forms.FlowLayoutPanel
$left.Dock = 'Left'; $left.Width = Px 290; $left.BackColor = $panel
$left.FlowDirection = 'TopDown'; $left.WrapContents = $false; $left.AutoScroll = $true
$left.Padding = Pad 10 6 6 10

$top = New-Object Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = Px 62; $top.BackColor = $panel

$mon = New-Object Windows.Forms.Label
$mon.Dock = 'Fill'
$mon.Font = New-Object Drawing.Font('Consolas', 10)
$mon.Padding = Pad 10 8 0 0
$mon.Text = 'Монитор запускается...'

$chkGpu = New-Object Windows.Forms.CheckBox
$chkGpu.Dock = 'Right'; $chkGpu.Width = Px 340
$chkGpu.Text = 'GPU в мониторе (будит видеокарту - только от сети)'
$chkGpu.ForeColor = $fg
$tips.SetToolTip($chkGpu, 'Опрос nvidia-smi не даёт RTX 4070 уснуть. На батарее галочка снимается автоматически.')

$top.Controls.Add($mon)
$top.Controls.Add($chkGpu)

$bottom = New-Object Windows.Forms.Panel
$bottom.Dock = 'Bottom'; $bottom.Height = Px 26; $bottom.BackColor = $panel
$statusLbl = New-Object Windows.Forms.Label
$statusLbl.Dock = 'Left'; $statusLbl.Width = Px 380; $statusLbl.TextAlign = 'MiddleLeft'
$statusLbl.Padding = Pad 10 0 0 0; $statusLbl.ForeColor = $cDim; $statusLbl.Text = 'Готово.'
$stateLbl = New-Object Windows.Forms.Label
$stateLbl.Dock = 'Fill'; $stateLbl.TextAlign = 'MiddleRight'
$stateLbl.Padding = Pad 0 0 10 0; $stateLbl.ForeColor = $cDim
$bottom.Controls.Add($stateLbl)
$bottom.Controls.Add($statusLbl)

$box = New-Object Windows.Forms.RichTextBox
$box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.DetectUrls = $false
$box.Dock = 'Fill'; $box.BackColor = $bg; $box.ForeColor = $fg
$box.Font = New-Object Drawing.Font('Consolas', 10)
$box.BorderStyle = 'None'

$form.Controls.Add($box)
$form.Controls.Add($top)
$form.Controls.Add($bottom)
$form.Controls.Add($left)

# ---------------- помощники ----------------
function Out-Box([object[]]$Lines, $Color = $null) {
    foreach ($l in $Lines) {
        $s = "$l"
        $c = $Color
        if ($null -eq $c) {
            if ($s -match '^\s*(!!!|ОШИБКА)') { $c = $cErr }
            elseif ($s -match '^\s*\[!\]') { $c = $cWarn }
            else { $c = $fg }
        }
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionColor = $c
        $box.AppendText("$s`n")
        [void]$script:Log.AppendLine($s)
    }
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
    [Windows.Forms.Application]::DoEvents()
}
function Head([string]$t) { Out-Box @('', "=============== $t ===============") $accent }
function Out-Ok([object[]]$Lines)   { Out-Box $Lines $cOk }
function Out-Warn([object[]]$Lines) { Out-Box $Lines $cWarn }
function Out-Dim([object[]]$Lines)  { Out-Box $Lines $cDim }

function Ask-User([string]$msg, [string]$title = 'Подтверждение') {
    $r = [Windows.Forms.MessageBox]::Show($form, $msg, $title, 'YesNo', 'Question')
    return ($r -eq [Windows.Forms.DialogResult]::Yes)
}

function Invoke-Safe([string]$name, [scriptblock]$action) {
    if ($script:Busy) { $statusLbl.Text = "Подождите: ещё выполняется «$($script:BusyName)»"; return }
    $script:Busy = $true; $script:BusyName = $name
    $statusLbl.Text = "Выполняется: $name..."
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try { & $action }
    catch { Out-Box "ОШИБКА [$name]: $($_.Exception.Message)" }
    finally {
        $script:Busy = $false; $script:Cat = $null
        $form.Cursor = [Windows.Forms.Cursors]::Default
        $statusLbl.Text = "Готово: $name"
    }
}

function Add-Section([string]$text) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.ForeColor = $accent
    $l.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
    $l.Width = Px 250; $l.Height = Px 28; $l.TextAlign = 'BottomLeft'
    $left.Controls.Add($l)
}

function Add-Btn([string]$text, [scriptblock]$action, [string]$tip = '', [switch]$Primary) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Width = Px 250; $b.Height = Px 34
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $accent
    $b.TextAlign = 'MiddleLeft'; $b.Padding = Pad 6 0 0 0
    if ($Primary) {
        $b.BackColor = $accentD; $b.ForeColor = [Drawing.Color]::White
        $b.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
        $b.FlatAppearance.MouseOverBackColor = $accent
    } else {
        $b.BackColor = $panel; $b.ForeColor = $fg
        $b.FlatAppearance.MouseOverBackColor = $panel2
    }
    $b.FlatAppearance.MouseDownBackColor = $accent
    $b.Margin = Pad 0 0 0 4
    $b.Tag = @{ Name = $text; Action = $action }
    $b.Add_Click({ param($s, $e) Invoke-Safe $s.Tag.Name $s.Tag.Action })
    if ($tip) { $tips.SetToolTip($b, $tip) }
    $left.Controls.Add($b)
}

# Долгие команды идут в отдельном окне (права администратора наследуются).
function Start-Console([string]$title, [string]$command) {
    $cmd = "`$host.UI.RawUI.WindowTitle = '$title'; $command; Write-Host ''; Write-Host 'ГОТОВО. Окно можно закрыть.' -ForegroundColor Green"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand $enc"
    Out-Box "Открыто отдельное окно: $title"
}

function Test-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Out-Box 'winget не найден. Установите «Установщик приложений» (App Installer) из Microsoft Store.'
    Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1'
    return $false
}

function GB($bytes) { [math]::Round($bytes / 1GB, 1) }
function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($true))) }

# ---------------- журнал изменений (для отката) ----------------
# Перед каждым изменением запоминается исходное значение. Категория ($script:Cat) задаёт,
# какой кнопкой «Откатить» оно возвращается. Без категории изменения не журналируются.
function Load-Journal {
    $script:Journal = New-Object Collections.ArrayList
    if (-not (Test-Path $JournalPath)) { return }
    try {
        $j = Get-Content $JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in @($j)) { if ($e) { [void]$script:Journal.Add($e) } }
    } catch { }
}
function Save-Journal {
    Write-Utf8 $JournalPath (ConvertTo-Json -InputObject @($script:Journal) -Depth 5)
}
function Save-Original([string]$key, [hashtable]$data) {
    if (-not $script:Cat) { return }
    foreach ($e in $script:Journal) { if ($e.Key -eq $key) { return } }   # храним самое первое (исходное) значение
    $data.Key = $key; $data.Cat = $script:Cat
    [void]$script:Journal.Add([pscustomobject]$data)
    Save-Journal
}
Load-Journal

function Set-Reg([string]$path, [string]$name, $value, [string]$type = 'DWord') {
    $vn = if ($name -eq '(default)') { '' } else { $name }
    if (-not (Test-Path $path)) {
        $topKey = $path
        $parent = Split-Path $topKey -Parent
        while ($parent -and -not (Test-Path $parent)) { $topKey = $parent; $parent = Split-Path $topKey -Parent }
        Save-Original "key|$topKey" @{ Kind = 'key'; Path = $topKey }
        New-Item -Path $path -Force | Out-Null
    } else {
        $cur = Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $cur) {
            Save-Original "reg|$path|$name" @{ Kind = 'reg'; Path = $path; Name = $name; Existed = $true; Value = $cur.$name
                                              Type = (Get-Item $path).GetValueKind($vn).ToString() }
        } else {
            Save-Original "reg|$path|$name" @{ Kind = 'reg'; Path = $path; Name = $name; Existed = $false }
        }
    }
    if ($name -eq '(default)') { Set-ItemProperty -Path $path -Name '(default)' -Value $value }
    else { New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null }
}

function Set-Svc([string]$name, [string]$startType) {
    $s = Get-Service $name -ErrorAction SilentlyContinue
    if (-not $s) { return $false }
    Save-Original "svc|$name" @{ Kind = 'svc'; Name = $name; StartType = "$($s.StartType)" }
    Set-Service $name -StartupType $startType -ErrorAction SilentlyContinue
    if ($startType -eq 'Disabled') { Stop-Service $name -Force -ErrorAction SilentlyContinue }
    return $true
}

function Get-Pow([string]$sub, [string]$setting, [switch]$AC) {
    [LTK.Pwr]::Read([LTK.Pwr]::ActiveScheme(), $sub, $setting, (-not $AC))
}
function Set-Pow([string]$sub, [string]$setting, [uint32]$value, [string]$label, [switch]$AC) {
    $dc = -not $AC
    $scheme = [LTK.Pwr]::ActiveScheme()
    $old = [LTK.Pwr]::Read($scheme, $sub, $setting, $dc)
    if ($old -lt 0) { Out-Dim "  - $label - нет на этом ноутбуке, пропущено"; return }
    Save-Original "pow|$scheme|$setting|$dc" @{ Kind = 'pow'; Scheme = $scheme; Sub = $sub; Setting = $setting; Dc = $dc; Value = $old }
    $r = [LTK.Pwr]::Write($scheme, $sub, $setting, $dc, $value)
    if ($r -eq 0) { Out-Ok "  + $label" } else { Out-Warn "  [!] $label - ошибка $r" }
}

function Undo-Journal([string]$cat) {
    $entries = @($script:Journal | Where-Object { $_.Cat -eq $cat })
    if (-not $entries.Count) { return 0 }
    $n = 0
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $e = $entries[$i]
        try {
            switch ($e.Kind) {
                'reg' {
                    if ($e.Existed) {
                        $v = $e.Value
                        switch ($e.Type) { 'Binary' { $v = [byte[]]@($v) } 'MultiString' { $v = [string[]]@($v) } 'DWord' { $v = [int]$v } 'QWord' { $v = [long]$v } }
                        if ($e.Name -eq '(default)') { Set-ItemProperty -Path $e.Path -Name '(default)' -Value $v }
                        else { New-ItemProperty -Path $e.Path -Name $e.Name -Value $v -PropertyType $e.Type -Force | Out-Null }
                    } else { Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue }
                }
                'key' { Remove-Item -Path $e.Path -Recurse -Force -ErrorAction SilentlyContinue }
                'svc' { if ($e.StartType -in 'Automatic', 'Manual', 'Disabled') { Set-Service $e.Name -StartupType $e.StartType -ErrorAction SilentlyContinue } }
                'pow' { [void][LTK.Pwr]::Write($e.Scheme, $e.Sub, $e.Setting, [bool]$e.Dc, [uint32]$e.Value) }
                'hib' {
                    if (-not $e.WasOn) { powercfg /hibernate off | Out-Null }
                    elseif ($e.WasType -eq 1) { powercfg /h /type reduced | Out-Null }
                }
            }
            $n++
        } catch { Out-Warn "  [!] Не удалось вернуть $($e.Key): $($_.Exception.Message)" }
        [void]$script:Journal.Remove($e)
    }
    [void][LTK.Pwr]::Apply()
    Save-Journal
    return $n
}

# ---------------- агент автопереключения (зарядка <-> батарея) ----------------
$AgentScript = @'
# LaptopToolkit: переключение профиля при подключении/отключении зарядки.
# Запускается планировщиком (задача \LaptopToolkit\PowerAgent), настройки - agent.json рядом.
$ErrorActionPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Get-Content (Join-Path $dir 'agent.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cfg) { exit }
Add-Type -Path (Join-Path $dir 'LTK.cs')
Start-Sleep -Seconds 2   # даём Windows обновить состояние питания
$ac = [LTK.Pwr]::OnAC()
if ($ac -lt 0) { exit }
$done = @()
$ov = if ($ac -eq 1) { $cfg.AcOverlay } else { $cfg.DcOverlay }
if ($ov) { $done += "режим $ov -> $([LTK.Pwr]::SetOverlay($ov))" }
if ($cfg.Refresh) {
    $rates = @([LTK.Disp]::Rates())
    if ($rates.Count) {
        if ($ac -eq 1) { $hz = $rates[-1] }
        elseif ($rates -contains [int]$cfg.DcHz) { $hz = [int]$cfg.DcHz }
        else { $hz = $rates[0] }
        $done += "экран $hz Гц -> $([LTK.Disp]::Set($hz))"
    }
}
$line = '{0:yyyy-MM-dd HH:mm:ss}  {1}: {2}' -f (Get-Date), $(if ($ac -eq 1) { 'СЕТЬ   ' } else { 'БАТАРЕЯ' }), ($done -join '; ')
$lp = Join-Path $dir 'agent.log'
$old = @(Get-Content $lp -Encoding UTF8 | Select-Object -Last 199)
[IO.File]::WriteAllLines($lp, [string[]]($old + $line), (New-Object Text.UTF8Encoding($true)))
'@

function Get-AgentConfig {
    $p = Join-Path $DataDir 'agent.json'
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Test-AgentTask { [bool](Get-ScheduledTask -TaskName 'PowerAgent' -TaskPath '\LaptopToolkit\' -ErrorAction SilentlyContinue) }

function Install-Agent([hashtable]$changes) {
    $cfg = @{ AcOverlay = ''; DcOverlay = ''; Refresh = $false; DcHz = 60 }
    $old = Get-AgentConfig
    if ($old) { foreach ($k in @($cfg.Keys)) { if ($null -ne $old.$k) { $cfg[$k] = $old.$k } } }
    foreach ($k in $changes.Keys) { $cfg[$k] = $changes[$k] }

    Write-Utf8 (Join-Path $DataDir 'LTK.cs') $CsSource
    Write-Utf8 (Join-Path $DataDir 'PowerAgent.ps1') $AgentScript
    Write-Utf8 (Join-Path $DataDir 'agent.json') (ConvertTo-Json -InputObject $cfg)

    $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $ps1 = Join-Path $DataDir 'PowerAgent.ps1'
    if ($OsBuild -ge 22000) { $exe = 'conhost.exe'; $arg = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1`"" }
    else { $exe = 'powershell.exe'; $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`"" }
    $query = "<QueryList><Query Id=`"0`" Path=`"System`">" +
             "<Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=105 or EventID=507)]]</Select>" +
             "<Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>" +
             "</Query></QueryList>"
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>LaptopToolkit</Author>
    <Description>LaptopToolkit: при отключении зарядки - экономичный режим и 60 Гц, при подключении - производительность и максимальная частота экрана.</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger><Enabled>true</Enabled><Subscription>$(& $esc $query)</Subscription></EventTrigger>
    <LogonTrigger><Enabled>true</Enabled><UserId>$(& $esc "$env:USERDOMAIN\$env:USERNAME")</UserId><Delay>PT15S</Delay></LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>$exe</Command><Arguments>$(& $esc $arg)</Arguments></Exec>
  </Actions>
</Task>
"@
    try {
        Register-ScheduledTask -TaskName 'PowerAgent' -TaskPath '\LaptopToolkit\' -Xml $xml -Force -ErrorAction Stop | Out-Null
    } catch {
        Out-Box "  [!] Не удалось создать задачу автопереключения: $($_.Exception.Message)"
        return
    }
    Start-ScheduledTask -TaskName 'PowerAgent' -TaskPath '\LaptopToolkit\' -ErrorAction SilentlyContinue
    $script:AgentOn = $true
    Out-Ok '  + Автопереключение при подключении/отключении зарядки включено (Планировщик: \LaptopToolkit\PowerAgent)'
}

function Uninstall-Agent {
    Unregister-ScheduledTask -TaskName 'PowerAgent' -TaskPath '\LaptopToolkit\' -Confirm:$false -ErrorAction SilentlyContinue
    $script:AgentOn = $false
    foreach ($f in 'PowerAgent.ps1', 'agent.json', 'LTK.cs') { Remove-Item (Join-Path $DataDir $f) -Force -ErrorAction SilentlyContinue }
    $rates = @([LTK.Disp]::Rates())
    if ($rates.Count) { [void][LTK.Disp]::Set($rates[-1]) }
    Out-Ok '  + Автопереключение выключено, частота экрана возвращена на максимум.'
}

# ---------------- окно с галочками ----------------
# $items: @{ Group; Key; Text; Hint; On }. Возвращает hashtable выбранных ключей или $null при отмене.
function Show-Options([string]$title, [string]$intro, [object[]]$items, [string]$okText = 'Применить') {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = $title; $dlg.StartPosition = 'CenterParent'; $dlg.AutoScaleMode = 'None'
    $dlg.Size = Sz 720 760; $dlg.MinimumSize = Sz 540 420
    $dlg.BackColor = $bg; $dlg.ForeColor = $fg; $dlg.ShowInTaskbar = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object Drawing.Font('Segoe UI', 9)

    $head = New-Object Windows.Forms.Label
    $head.Dock = 'Top'; $head.Height = Px 64; $head.Padding = Pad 14 10 14 0
    $head.Text = $intro; $head.BackColor = $panel

    $flow = New-Object Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
    $flow.Padding = Pad 14 6 10 10
    $w = Px 640
    $script:OptBoxes = New-Object Collections.ArrayList
    $grp = $null
    foreach ($it in $items) {
        if ($it.Group -and $it.Group -ne $grp) {
            $grp = $it.Group
            $gl = New-Object Windows.Forms.Label
            $gl.Text = $grp.ToUpper(); $gl.ForeColor = $accent; $gl.AutoSize = $true
            $gl.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
            $gl.Margin = Pad 0 12 0 2
            $flow.Controls.Add($gl)
        }
        $cb = New-Object Windows.Forms.CheckBox
        $cb.Text = $it.Text; $cb.Checked = [bool]$it.On; $cb.Tag = $it.Key
        $cb.AutoSize = $true; $cb.MaximumSize = New-Object Drawing.Size($w, 0)
        $cb.Font = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
        $cb.Margin = Pad 0 6 0 0
        $flow.Controls.Add($cb)
        [void]$script:OptBoxes.Add($cb)
        if ($it.Hint) {
            $h = New-Object Windows.Forms.Label
            $h.Text = $it.Hint; $h.ForeColor = $cDim; $h.AutoSize = $true
            $h.MaximumSize = New-Object Drawing.Size(($w - (Px 22)), 0)
            $h.Margin = Pad 20 0 0 2
            $flow.Controls.Add($h)
        }
    }

    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = Px 52; $bar.BackColor = $panel
    $bar.FlowDirection = 'RightToLeft'; $bar.Padding = Pad 8 9 8 0
    $mk = {
        param($t, $primary)
        $b = New-Object Windows.Forms.Button
        $b.Text = $t; $b.Height = Px 34; $b.AutoSize = $true; $b.MinimumSize = Sz 110 34
        $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $accent; $b.ForeColor = $fg
        $b.BackColor = $(if ($primary) { $accentD } else { $panel })
        $b.Margin = Pad 6 0 0 0
        $b
    }
    $ok = & $mk $okText $true; $ok.DialogResult = 'OK'
    $cancel = & $mk 'Отмена' $false; $cancel.DialogResult = 'Cancel'
    $all = & $mk 'Отметить всё' $false
    $all.Add_Click({ foreach ($c in $script:OptBoxes) { $c.Checked = $true } })
    $none = & $mk 'Снять всё' $false
    $none.Add_Click({ foreach ($c in $script:OptBoxes) { $c.Checked = $false } })
    $bar.Controls.AddRange(@($ok, $cancel, $none, $all))

    $dlg.Controls.Add($flow); $dlg.Controls.Add($head); $dlg.Controls.Add($bar)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $res = $dlg.ShowDialog($form)
    $sel = $null
    if ($res -eq [Windows.Forms.DialogResult]::OK) {
        $sel = @{}
        foreach ($c in $script:OptBoxes) { if ($c.Checked) { $sel[[string]$c.Tag] = $true } }
    }
    $dlg.Dispose()
    return $sel
}

# ---------------- ДИАГНОСТИКА ----------------
function Do-System {
    Head 'СИСТЕМА / ПРОЦЕССОР'
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $up = (Get-Date) - $os.LastBootUpTime
    Out-Box @(
        "Модель:     $($cs.Manufacturer) $($cs.Model)",
        "Windows:    $($os.Caption) $($os.OSArchitecture), сборка $($os.BuildNumber)",
        "BIOS:       $($bios.SMBIOSBIOSVersion) от $($bios.ReleaseDate)",
        "Процессор:  $($cpu.Name.Trim())",
        "            $($cpu.NumberOfCores) ядер / $($cpu.NumberOfLogicalProcessors) потоков, базовая $($cpu.MaxClockSpeed) МГц",
        "Без перезагрузки: $([int]$up.TotalDays) д $($up.Hours) ч"
    )
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop; Out-Box "Secure Boot: $(if ($sb) {'включён'} else {'выключен'})" }
    catch { Out-Box 'Secure Boot: не определить (Legacy/CSM?)' }
    try { $tpm = Get-Tpm -ErrorAction Stop; Out-Box "TPM: $(if ($tpm.TpmReady) {'готов'} elseif ($tpm.TpmPresent) {'есть, не готов'} else {'нет'})" }
    catch { Out-Box 'TPM: не определить' }
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ($dg.VirtualizationBasedSecurityStatus -eq 2) {
            Out-Box 'VBS / Целостность памяти: ВКЛ (защита лучше, но в части игр -5..10% FPS; отключать - на свой риск)'
        } else { Out-Box 'VBS / Целостность памяти: выкл' }
    } catch { }
}

function Do-Ram {
    Head 'ОПЕРАТИВНАЯ ПАМЯТЬ'
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
    $total = 0
    foreach ($m in $mods) {
        $total += $m.Capacity
        Out-Box "$($m.DeviceLocator): $(GB $m.Capacity) ГБ, $($m.ConfiguredClockSpeed) MT/s (номинал $($m.Speed)) - $($m.Manufacturer) $("$($m.PartNumber)".Trim())"
    }
    Out-Box "Всего: $(GB $total) ГБ, занято слотов: $($mods.Count) из $(if ($slots) {$slots} else {'?'})"
    if ($mods.Count -eq 1) {
        Out-Box @('',
            '!!! ОДНОКАНАЛЬНЫЙ РЕЖИМ. Это главный тормоз этого ноутбука.',
            '    Купите вторую такую же планку: 16 ГБ DDR5-5600 SODIMM (лучше той же марки).',
            '    Двухканал = +10..30% FPS в играх, упирающихся в процессор, и намного быстрее встроенная графика.')
    }
    $low = $mods | Where-Object { $_.ConfiguredClockSpeed -and $_.Speed -and $_.ConfiguredClockSpeed -lt $_.Speed }
    if ($low) { Out-Box '[!] Память работает ниже номинала - проверьте BIOS / обновите BIOS.' }
    Out-Box 'Полный тест памяти - кнопка «Тест RAM (перезагрузка)».'
}

function Do-Gpu {
    Head 'ВИДЕОКАРТЫ'
    Get-CimInstance Win32_VideoController | ForEach-Object {
        $d = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '?' }
        Out-Box "$($_.Name) | драйвер $($_.DriverVersion) от $d"
    }
    $hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue).HwSchMode
    Out-Box "Аппаратное планирование GPU (HAGS): $(if ($hags -eq 2) {'вкл'} else {'выкл'})"
    Out-Box "Режим графики: $(Get-GraphicsModeText)"
    if (-not $Smi) { Out-Box '[!] nvidia-smi не найден - установите драйвер NVIDIA (кнопка «Драйверы NVIDIA / AMD»).'; return }
    $fields = 'name', 'driver_version', 'pstate', 'temperature.gpu', 'utilization.gpu', 'power.draw',
              'enforced.power.limit', 'power.max_limit', 'clocks.gr', 'clocks.max.gr', 'clocks.mem', 'memory.used', 'memory.total'
    $labels = 'Модель', 'Драйвер', 'P-state (P8 = спит)', 'Температура, °C', 'Загрузка, %', 'Потребление, Вт',
              'Текущий лимит, Вт', 'Потолок мощности, Вт', 'Частота ядра, МГц', 'Макс. частота, МГц', 'Частота памяти, МГц', 'VRAM занято, МБ', 'VRAM всего, МБ'
    $v = Get-SmiValues $fields
    Out-Box ''
    for ($i = 0; $i -lt $fields.Count; $i++) { Out-Box ('  {0,-22} {1}' -f $labels[$i], $v[$fields[$i]]) }
    Out-Dim '  Мощность и 140 Вт подробно - раздел ВИДЕОКАРТА 140 ВТ.'
}

function Do-Disk {
    Head 'ДИСКИ'
    Get-PhysicalDisk | ForEach-Object {
        Out-Box "$($_.FriendlyName) | $(GB $_.Size) ГБ | $($_.MediaType) / $($_.BusType) | Здоровье: $($_.HealthStatus)"
        $r = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($r) {
            Out-Box "    Температура: $($r.Temperature) °C | Износ: $($r.Wear) % | Часов работы: $($r.PowerOnHours) | Неисправимых ошибок чтения: $($r.ReadErrorsUncorrected)"
        }
    }
    Out-Box ''
    Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter | ForEach-Object {
        $pct = if ($_.Size) { [math]::Round($_.SizeRemaining * 100 / $_.Size) } else { 0 }
        $warn = if ($pct -lt 15) { '  <-- мало места!' } else { '' }
        Out-Box "$($_.DriveLetter): свободно $(GB $_.SizeRemaining) из $(GB $_.Size) ГБ ($pct %)$warn"
    }
    $trim = fsutil behavior query DisableDeleteNotify | Select-Object -First 1
    Out-Box "TRIM для SSD: $(if ("$trim" -match '=\s*0') {'включён'} else {'проверьте: ' + $trim})"
    Out-Box 'Подробный SMART - CrystalDiskInfo, скорость - кнопка «Тест скорости диска».'
}

function Do-Battery([switch]$NoOpen) {
    Head 'БАТАРЕЯ'
    $b = Get-CimInstance Win32_Battery | Select-Object -First 1
    if (-not $b) { Out-Box 'Батарея не найдена.'; return }
    Out-Box "Заряд: $($b.EstimatedChargeRemaining) %"
    try {
        $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
        $cyc = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Select-Object -First 1).CycleCount
        if ($design -gt 0 -and $full -gt 0) {
            $wear = [math]::Round(100 - $full * 100 / $design, 1)
            Out-Box "Ёмкость: $full из $design мВт·ч (износ $wear %)$(if ($cyc) {", циклов: $cyc"})"
            if ($wear -gt 20) { Out-Box '[!] Износ больше 20% - для нового ноутбука это много.' }
        }
    } catch { Out-Box 'Детальные данные недоступны - смотрите HTML-отчёт.' }
    $p = Join-Path $ReportDir 'battery_report.html'
    powercfg /batteryreport /output "$p" | Out-Null
    Out-Box "HTML-отчёт: $p"
    if (-not $NoOpen -and (Test-Path $p)) { Start-Process $p }
}

function Do-Drivers {
    Head 'ПРОБЛЕМНЫЕ УСТРОЙСТВА'
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    if ($bad.Count -eq 0) { Out-Ok 'Проблемных устройств нет.'; return }
    foreach ($d in $bad) { Out-Box "[!] $($d.Name) - код ошибки $($d.ConfigManagerErrorCode) ($($d.PNPDeviceID))" }
    Out-Box 'Код 28 = нет драйвера, 22 = отключено, 10/43 = сбой. Решение - кнопка «Драйверы NVIDIA / AMD».'
}

function Do-Events {
    Head 'ЖУРНАЛ СБОЕВ ЗА 30 ДНЕЙ'
    $since = (Get-Date).AddDays(-30)
    $checks = @(
        @{ N = 'Синие экраны (BSOD)';            F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } },
        @{ N = 'Внезапные выключения/зависания'; F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } },
        @{ N = 'Аппаратные ошибки WHEA';         F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } },
        @{ N = 'Сбои видеодрайвера (TDR)';       F = @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since } },
        @{ N = 'Ошибки диска/файловой системы';  F = @{ LogName = 'System'; ProviderName = 'disk', 'Microsoft-Windows-Ntfs'; Level = 2, 3; StartTime = $since } }
    )
    foreach ($c in $checks) {
        $ev = @(Get-WinEvent -FilterHashtable $c.F -MaxEvents 50 -ErrorAction SilentlyContinue)
        if ($ev.Count -eq 0) { Out-Box ('{0,-32} {1}' -f $c.N, '0 - ок') } else { Out-Warn ('{0,-32} {1}' -f $c.N, $ev.Count) }
        $ev | Select-Object -First 3 | ForEach-Object {
            $msg = ("$($_.Message)" -split "`n")[0].Trim()
            if ($msg.Length -gt 140) { $msg = $msg.Substring(0, 140) + '...' }
            Out-Dim "    $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm')) $msg"
        }
    }
    $dumps = @(Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue)
    Out-Box "Дампов синих экранов: $($dumps.Count)$(if ($dumps.Count) {' (разобрать: программа BlueScreenView / WinDbg)'})"
}

function Do-Full {
    $box.Clear(); [void]$script:Log.Clear()
    Out-Box "ПОЛНАЯ ПРОВЕРКА - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Do-System; Do-Ram; Do-Gpu; Do-GpuCheck; Do-Disk; Do-Battery -NoOpen; Do-PowerStatus; Do-Drivers; Do-Events; Do-AvStatus
    Do-Save
}

# ---------------- ВИДЕОКАРТА 140 ВТ ----------------
function Get-SmiValues([string[]]$fields) {
    $h = @{}
    foreach ($f in $fields) { $h[$f] = 'н/д' }
    if (-not $Smi) { return $h }
    $out = @(& $Smi "--query-gpu=$($fields -join ',')" --format=csv,noheader,nounits 2>$null)
    $raw = $out | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $raw) {
        $v = "$raw" -split ',\s*'
        for ($i = 0; $i -lt $fields.Count -and $i -lt $v.Count; $i++) { $h[$fields[$i]] = $v[$i].Trim() }
        return $h
    }
    # старый драйвер не знает какое-то поле - спрашиваем по одному
    foreach ($f in $fields) {
        $one = @(& $Smi "--query-gpu=$f" --format=csv,noheader,nounits 2>$null)
        if ($LASTEXITCODE -eq 0 -and $one.Count) { $h[$f] = "$($one[0])".Trim() }
    }
    return $h
}
function Num($s) {
    $d = 0.0
    if ([double]::TryParse("$s".Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Get-GraphicsMode {
    $nv = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if (-not $nv) { return 'none' }
    if ($nv.CurrentHorizontalResolution) { return 'dgpu' }
    return 'hybrid'
}
function Get-GraphicsModeText {
    switch (Get-GraphicsMode) {
        'dgpu'   { 'экран выводит RTX 4070 (MUX «Только дискретная» или внешний монитор) - максимум FPS, но на батарее расход сильно выше' }
        'hybrid' { 'гибридный (Optimus): экран на Radeon 780M, RTX 4070 включается только для игр - лучший вариант для батареи' }
        default  { 'NVIDIA не видна (драйвер не установлен или видеокарта отключена)' }
    }
}

function Get-Nvpcf {
    @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.Present -and ($_.InstanceId -like 'ACPI\NVDA0820*' -or $_.FriendlyName -match 'Platform Controllers and Framework') })
}

# Код проблемы устройства (22 = отключено, 28 = нет драйвера); тип свойства зависит от версии Windows.
function Get-CmCode($dev) {
    $c = $dev.ConfigManagerErrorCode
    $n = 0
    if ([int]::TryParse("$c", [ref]$n)) { return $n }
    try { return [int]$c } catch { }
    if ("$c" -match 'DISABLED') { return 22 }
    if ("$c" -match 'NOT_CONFIGURED|FAILED_INSTALL') { return 28 }
    return -1
}

function Show-GpuPower([switch]$Fix) {
    Head 'МОЩНОСТЬ ВИДЕОКАРТЫ (цель: 140 Вт = 115 Вт база + 25 Вт Dynamic Boost)'
    if (-not $Smi) { Out-Box '!!! Драйвер NVIDIA не найден (нет nvidia-smi). Кнопка «Драйверы NVIDIA / AMD».'; return }
    $v = Get-SmiValues @('name', 'driver_version', 'power.draw', 'enforced.power.limit', 'power.default_limit', 'power.max_limit', 'pstate')
    Out-Box @(
        "  Видеокарта:          $($v['name']), драйвер $($v['driver_version'])",
        "  Потребление сейчас:  $($v['power.draw']) Вт ($($v['pstate']))",
        "  Текущий лимит:       $($v['enforced.power.limit']) Вт",
        "  Заводской лимит:     $($v['power.default_limit']) Вт",
        "  Потолок (vBIOS):     $($v['power.max_limit']) Вт")
    $ac = [LTK.Pwr]::OnAC()
    if ($ac -eq 1) { Out-Ok '  + Питание от сети' } else { Out-Box '  [!] Ноутбук на батарее: видеокарта урезана до ~50-80 Вт. 140 Вт - только от сети с родным блоком питания.' }

    # Dynamic Boost (+25 Вт) работает только через NVIDIA Platform Controllers and Framework.
    $pcf = Get-Nvpcf
    if (-not $pcf.Count) {
        Out-Box '  [!] Dynamic Boost: компонент «NVIDIA Platform Controllers and Framework» не найден.',
                '      Без него видеокарта не поднимется выше базовых ~115 Вт. Решение: обновить BIOS с сайта Skytech',
                '      и переустановить драйвер NVIDIA (NVIDIA App -> Драйверы -> Переустановить -> «Чистая установка»).'
    }
    foreach ($d in $pcf) {
        $code = Get-CmCode $d
        if ("$($d.Status)" -eq 'OK') { Out-Ok "  + Dynamic Boost: работает ($($d.FriendlyName))" }
        elseif ($code -eq 22 -and $Fix) {
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            Out-Ok '  + Dynamic Boost был ОТКЛЮЧЁН в Диспетчере устройств - включил.'
        }
        elseif ($code -eq 22) { Out-Box '  [!] Dynamic Boost отключён в Диспетчере устройств - кнопка «140 Вт: разблокировать» включит его.' }
        elseif ($code -eq 28) { Out-Box '  [!] Dynamic Boost: нет драйвера. Переустановите драйвер NVIDIA (чистая установка) - компонент ставится вместе с ним.' }
        else { Out-Box "  [!] Dynamic Boost: ошибка устройства, код $code. Переустановите драйвер NVIDIA (чистая установка)." }
    }

    # Службу NVIDIA часто отключают «оптимизаторы» - без неё ломаются Панель NVIDIA и управление питанием.
    $svc = Get-Service 'NVDisplay.ContainerLocalSystem' -ErrorAction SilentlyContinue
    if ($svc) {
        if ("$($svc.StartType)" -ne 'Automatic' -or "$($svc.Status)" -ne 'Running') {
            if ($Fix) {
                Set-Service $svc.Name -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service $svc.Name -ErrorAction SilentlyContinue
                Out-Ok '  + Служба NVIDIA Display Container была выключена - включил и запустил.'
            } else { Out-Box "  [!] Служба NVIDIA Display Container: $($svc.Status) / $($svc.StartType) - должна работать (кнопка «140 Вт: разблокировать»)." }
        } else { Out-Ok '  + Служба NVIDIA Display Container работает' }
    }

    $ov = [LTK.Pwr]::GetOverlay()
    $ovName = if ($OverlayNames.ContainsKey($ov)) { $OverlayNames[$ov] } else { 'н/д' }
    if ($ac -eq 1 -and $ov -ne $OV_PERF) { Out-Box "  [!] Режим питания Windows: $ovName (нужно «Максимальная производительность»)" }
    else { Out-Box "  Режим питания Windows: $ovName" }
    Out-Box "  Режим графики: $(Get-GraphicsModeText)"
}

function Show-GpuVerdict {
    $v = Get-SmiValues @('power.max_limit', 'power.default_limit')
    $max = Num $v['power.max_limit']; $def = Num $v['power.default_limit']
    Out-Box ''
    if ($max -ge 139) {
        Out-Ok "ИТОГ: потолок видеокарты $max Вт - 140 Вт ДОСТУПНЫ."
        Out-Box '  Dynamic Boost добавляет до +25 Вт автоматически в тяжёлых играх, когда процессор не загружен на полную.',
                '  Поэтому постоянные 140 Вт будут не всегда - это нормальная работа, а не ограничение.'
    } elseif ($max -ge 100) {
        Out-Warn "ИТОГ: драйвер сообщает потолок $max Вт (база). Dynamic Boost добавляет сверху до +25 Вт динамически."
        Out-Box '  Проверьте реальный максимум: кнопка «Замер пиковой мощности GPU» + игра или FurMark 2 на 3-5 минут.',
                '  Если пик держится около базы - в фирменной утилите / BIOS не включён режим Turbo (Performance).'
    } elseif ($max) {
        Out-Box "!!! ИТОГ: прошивка (vBIOS) этого ноутбука ограничивает видеокарту $max Вт."
        Out-Box '  Программно поднять выше нельзя. Прошивка чужого vBIOS может «окирпичить» видеокарту, перегреть',
                '  цепи питания и лишает гарантии - эта программа так не делает. Проверьте обновление BIOS у Skytech.'
    } else {
        Out-Box '[!] ИТОГ: драйвер не сообщает лимиты. Посмотрите: Панель управления NVIDIA -> Справка -> Информация о системе',
                '    -> строка «Максимальная мощность графики» (Maximum Graphics Power). Должно быть 140 W.'
    }
    if ($def -and $max -and $def -lt $max) { Out-Dim "  (заводской лимит $def Вт + Dynamic Boost = до $max Вт)" }
}

function Do-GpuCheck { Show-GpuPower; Show-GpuVerdict }

function Do-Gpu140 {
    if (-not $Smi) { Head 'ВИДЕОКАРТА 140 ВТ'; Out-Box '!!! Драйвер NVIDIA не найден (нет nvidia-smi). Кнопка «Драйверы NVIDIA / AMD».'; return }
    $msg = "RTX 4070 Laptop в Skytech Noir рассчитана на 140 Вт = 115 Вт база + 25 Вт Dynamic Boost.`n`n" +
           "Программа:`n- включит Dynamic Boost (NVIDIA Platform Controllers), если он отключён`n" +
           "- включит службу NVIDIA, если её выключил «оптимизатор»`n" +
           "- поставит режим Windows «Максимальная производительность» от сети`n  (и будет возвращать его при каждом подключении зарядки)`n" +
           "- попробует поднять лимит драйвера до потолка прошивки`n`n" +
           "Прошивку (vBIOS) программа НЕ трогает: выше заводского потолка - только риск поломки.`nПродолжить?"
    if (-not (Ask-User $msg 'Видеокарта: 140 Вт')) { return }
    $script:Cat = 'gpu'
    Show-GpuPower -Fix
    Out-Box '', 'Применяю:'
    Install-Agent @{ AcOverlay = $OV_PERF }
    if ([LTK.Pwr]::OnAC() -eq 1) {
        $r = [LTK.Pwr]::SetOverlay($OV_PERF)
        if ($r -eq 0) { Out-Ok '  + Режим Windows: «Максимальная производительность»' } else { Out-Box "  [!] Режим Windows не переключился (код $r)" }
    }
    $v = Get-SmiValues @('enforced.power.limit', 'power.max_limit')
    $cur = Num $v['enforced.power.limit']; $max = Num $v['power.max_limit']
    if ($cur -and $max -and $cur -lt $max) {
        $out = & $Smi -pl ([int]$max) 2>&1
        if ($LASTEXITCODE -eq 0) { Out-Ok "  + Лимит драйвера поднят до $([int]$max) Вт (до перезагрузки, после неё его держит Dynamic Boost)" }
        else { Out-Dim "  - Ручной лимит ноутбучная видеокарта не принимает - это нормально, мощностью управляет Dynamic Boost. ($("$out".Trim()))" }
    }
    Show-GpuVerdict
    Out-Box '', 'ЧТОБЫ ВИДЕТЬ 140 ВТ В ИГРАХ:',
        '  1. Только от сети, родной блок питания.',
        '  2. Фирменная утилита ноутбука / BIOS / сочетание клавиш - режим Turbo (Performance). Без него EC держит меньше.',
        '  3. Охлаждение: подставка, чистые решётки. При 87 °C+ видеокарта сама снижает мощность.',
        '  4. Панель NVIDIA -> Управление режимом дисплея -> «Только дискретная графика» даёт ещё +5..15% FPS',
        '     (но на батарее верните «Автоматический выбор» - иначе заряд уходит в разы быстрее).',
        '  5. В Chris Titus WinUtil и подобных не отключайте службы NVIDIA - пропадёт Dynamic Boost.',
        '  Проверка: кнопка «Замер пиковой мощности GPU».'
}

function Do-GpuPeak {
    Head 'ЗАМЕР ПИКОВОЙ МОЩНОСТИ GPU'
    if (-not $Smi) { Out-Box '!!! nvidia-smi не найден.'; return }
    if ([LTK.Pwr]::OnAC() -ne 1) { Out-Box '[!] Подключите зарядку: на батарее 140 Вт недостижимы.' }
    $script:GpuPeak = 0.0
    $chkGpu.Checked = $true
    Out-Box 'Мониторинг GPU включён, пик обнулён. Запустите тяжёлую игру или FurMark 2 на 3-5 минут',
            'и смотрите строку GPU сверху: «пик» - максимальное потребление за замер.',
            '  ~140 Вт - всё работает; ~115 Вт - не работает Dynamic Boost или не включён режим Turbo;',
            '  ниже - перегрев, батарея или процессор забирает общий бюджет мощности.'
}

function Do-GpuHolders {
    Head 'ЧТО НЕ ДАЁТ ВИДЕОКАРТЕ УСНУТЬ'
    if (-not $Smi) { Out-Box '!!! nvidia-smi не найден.'; return }
    Out-Dim 'Сам этот опрос на несколько секунд будит RTX 4070 - потом она снова уснёт.'
    $txt = @(& $Smi 2>$null)
    $rx = '^\|\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(C\+G|C|G)\s+(.+?)\s+(N/A|\d+\s*MiB)\s+\|'
    $apps = @()
    foreach ($l in $txt) {
        if ($l -match $rx) {
            $procId = [int]$Matches[1]
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $path = if ($p -and $p.Path) { $p.Path } else { $Matches[3].Trim() }
            $apps += [pscustomobject]@{ Pid = $procId; Name = $(if ($p) { $p.ProcessName } else { '?' }); Path = $path }
        }
    }
    $ps = Get-SmiValues @('pstate', 'power.draw')
    Out-Box "Состояние: $($ps['pstate']) (P8 = простой), потребление $($ps['power.draw']) Вт"
    if (-not $apps.Count) { Out-Ok 'Ни одна программа не использует RTX 4070 - она может спать.'; return }
    foreach ($a in $apps) { Out-Box "[!] $($a.Name) (PID $($a.Pid)): $($a.Path)" }
    if ((Get-GraphicsMode) -eq 'dgpu') {
        Out-Box '', 'Экран сейчас выводит RTX 4070 - в этом режиме она не уснёт никогда. Для батареи включите гибридный режим.'
        return
    }
    $files = @($apps | Where-Object { $_.Path -like '*\*.exe' -and $_.Path -notmatch '\\Windows\\' } | Select-Object -ExpandProperty Path -Unique)
    if ($files.Count -and (Ask-User ("Назначить этим программам встроенную графику Radeon 780M (энергосбережение)?`n`n" + ($files -join "`n") +
            "`n`nИгры из списка лучше не трогать. Откат - «Откатить настройки батареи».") 'Видеокарта и батарея')) {
        $script:Cat = 'battery'
        foreach ($f in $files) { Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $f 'GpuPreference=1;' 'String'; Out-Ok "  + $f" }
        Out-Box 'Готово. Перезапустите эти программы.'
    }
}

# ---------------- БАТАРЕЯ / АВТОНОМНОСТЬ ----------------
function Get-LowPowerApps {
    $cand = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
        "$env:LOCALAPPDATA\Yandex\YandexBrowser\Application\browser.exe",
        "$env:LOCALAPPDATA\Programs\Opera\opera.exe",
        "$env:LOCALAPPDATA\Programs\Opera GX\opera.exe",
        "$env:APPDATA\Telegram Desktop\Telegram.exe",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
    )
    $found = @($cand | Where-Object { Test-Path $_ })
    $dc = Get-ChildItem "$env:LOCALAPPDATA\Discord\app-*\Discord.exe" -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
    if ($dc) { $found += $dc.FullName }
    return $found
}

function Do-BatteryOptimize {
    $apps = @(Get-LowPowerApps)
    $appNames = if ($apps.Count) { ($apps | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ', ' } else { 'не найдено' }
    $items = @(
        @{ Group = 'Процессор'; Key = 'boost'; On = $true; Text = 'Отключить турбобуст процессора на батарее'
           Hint = 'Ryzen 7 8845HS на батарее работает до базовых 3,8 ГГц вместо 5,1. Самый заметный прирост автономности; от сети турбобуст остаётся.' }
        @{ Group = 'Процессор'; Key = 'epp'; On = $true; Text = 'Процессор: приоритет энергосбережения (EPP 80%)'
           Hint = 'Частота мягче поднимается в лёгких задачах: браузер, видео, документы.' }
        @{ Group = 'Экран и режим Windows'; Key = 'refresh'; On = $true; Text = 'Экран 60 Гц на батарее, максимум (240 Гц) от сети - автоматически'
           Hint = '240 Гц заметно увеличивают расход. Частота переключается сама при отключении и подключении зарядки.' }
        @{ Group = 'Экран и режим Windows'; Key = 'overlay'; On = $true; Text = 'Режим Windows: «Лучшая энергоэффективность» на батарее, «Максимальная производительность» от сети'
           Hint = 'Тоже переключается автоматически вместе с зарядкой.' }
        @{ Group = 'Экран и режим Windows'; Key = 'saver'; On = $true; Text = 'Экономия энергии включается сразу при отключении зарядки'
           Hint = 'Windows ограничивает фоновую активность и синхронизацию, немного снижает яркость.' }
        @{ Group = 'Экран и режим Windows'; Key = 'screen'; On = $true; Text = 'На батарее: экран гаснет через 3 минуты, сон через 10 минут' ; Hint = '' }
        @{ Group = 'Сон'; Key = 'standby'; On = $true; Text = 'Во сне без интернета + гибернация через 1 час сна'
           Hint = 'Ноутбук не разряжается в рюкзаке за ночь: Wi-Fi во сне выключен, через час сна - гибернация (расход 0%).' }
        @{ Group = 'Устройства'; Key = 'devices'; On = $true; Text = 'Энергосбережение PCIe (ASPM), USB и Wi-Fi на батарее'
           Hint = 'Простаивающие SSD, Wi-Fi и USB засыпают. Если на батарее начнёт «подтормаживать» мышь или Wi-Fi - откатите.' }
        @{ Group = 'Устройства'; Key = 'video'; On = $true; Text = 'Видео на батарее: экономичная обработка'
           Hint = 'YouTube и фильмы на батарее воспроизводятся в экономичном режиме.' }
        @{ Group = 'Программы'; Key = 'gpuprefs'; On = $true; Text = 'Браузеры и мессенджеры - только на встроенной графике Radeon 780M'
           Hint = "Не будят RTX 4070 (проснувшаяся видеокарта сама по себе тратит несколько ватт). Найдено: $appNames." }
        @{ Group = 'Программы'; Key = 'edge'; On = $true; Text = 'Edge не работает в фоне после закрытия'
           Hint = 'Отключаются «Ускорение запуска» и фоновый режим Edge. В его настройках появится «Управляется организацией» - это нормально.' }
        @{ Group = 'Программы'; Key = 'bgapps'; On = $false; Text = 'Запретить фоновую работу приложений из Microsoft Store (агрессивно)'
           Hint = 'Экономит заряд, но приложения из Store (WhatsApp, Связь с телефоном, Почта) не будут присылать уведомления, пока закрыты.' }
    )
    $sel = Show-Options 'Максимальная автономность' ("Настройки действуют только на батарее - от сети ноутбук работает на полную.`n" +
        'Каждое изменение запоминается, вернуть всё можно кнопкой «Откатить настройки батареи».') $items
    if ($null -eq $sel) { return }
    if (-not $sel.Count) { Out-Box 'Ничего не выбрано.'; return }

    Head 'МАКСИМАЛЬНАЯ АВТОНОМНОСТЬ'
    $script:Cat = 'battery'
    if ($sel['boost']) {
        Set-Pow $PW.Proc $PW.Boost 0 'Турбобуст процессора на батарее: выкл'
        powercfg -attributes $PW.Proc $PW.Boost -ATTRIB_HIDE 2>&1 | Out-Null   # показать настройку в «Электропитании»
    }
    if ($sel['epp']) { Set-Pow $PW.Proc $PW.Epp 80 'Энергоэффективность процессора на батарее: 80%' }
    if ($sel['saver']) { Set-Pow $PW.Saver $PW.SaverAt 100 'Экономия энергии: всегда на батарее' }
    if ($sel['screen']) {
        Set-Pow $PW.Video $PW.ScreenOff 180 'Отключение экрана на батарее: 3 мин'
        Set-Pow $PW.Sleep $PW.SleepAfter 600 'Сон на батарее: 10 мин'
    }
    if ($sel['standby']) {
        $pk = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
        $wasOn = ($pk.HibernateEnabled -eq 1)
        Save-Original 'hib' @{ Kind = 'hib'; WasOn = $wasOn; WasType = $pk.HiberFileType }
        if (-not $wasOn) { powercfg /hibernate on 2>&1 | Out-Null }
        if ($pk.HiberFileType -eq 1) { powercfg /h /type full 2>&1 | Out-Null }
        Out-Ok '  + Гибернация доступна'
        Set-Pow $PW.None $PW.NetStandby 0 'Интернет во сне на батарее: выкл'
        Set-Pow $PW.Sleep $PW.HibAfter 3600 'Гибернация после 1 часа сна на батарее'
    }
    if ($sel['devices']) {
        Set-Pow $PW.Pcie $PW.Aspm 2 'PCIe ASPM на батарее: максимальное энергосбережение'
        Set-Pow $PW.Usb $PW.UsbSuspend 1 'Временное отключение USB-портов на батарее: вкл'
        Set-Pow $PW.Wifi $PW.WifiSave 3 'Wi-Fi на батарее: максимальное энергосбережение'
    }
    if ($sel['video']) { Set-Pow $PW.Media $PW.VideoPlay 2 'Воспроизведение видео на батарее: экономия энергии' }
    [void][LTK.Pwr]::Apply()

    if ($sel['gpuprefs']) {
        foreach ($a in $apps) { Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $a 'GpuPreference=1;' 'String' }
        if ($apps.Count) { Out-Ok "  + Встроенная графика для: $appNames (перезапустите эти программы)" } else { Out-Dim '  - Браузеры и мессенджеры не найдены' }
    }
    if ($sel['edge']) {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
        Out-Ok '  + Edge: ускорение запуска и фоновый режим выкл'
    }
    if ($sel['bgapps']) {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2
        Out-Ok '  + Фоновая работа приложений Store: запрещена'
    }
    if ($sel['refresh'] -or $sel['overlay']) {
        $ch = @{}
        if ($sel['refresh']) { $ch.Refresh = $true; $ch.DcHz = 60 }
        if ($sel['overlay']) { $ch.DcOverlay = $OV_EFF; $ch.AcOverlay = $OV_PERF }
        Install-Agent $ch
    }
    if ((Get-GraphicsMode) -eq 'dgpu') {
        Out-Box '', '!!! Сейчас экран выводит RTX 4070 (режим «Только дискретная»). На батарее это главный расход:',
                '    Панель NVIDIA -> Управление режимом дисплея -> «Автоматический выбор» (Optimus), затем перезагрузка.'
    }
    Out-Box '', 'Готово. Отключите зарядку - через пару секунд экран станет 60 Гц, а режим Windows - экономичным.',
        'Проверка: «Состояние питания сейчас» и «Журнал автопереключения».', '',
        'ВРУЧНУЮ (программа это сделать не может):',
        '  - NVIDIA App -> Настройки -> Battery Boost: вкл (ограничивает FPS игр на батарее).',
        '  - Подсветку клавиатуры на батарее - выключить (Fn + клавиша подсветки).',
        '  - Яркость 40-60% - экран главный потребитель после видеокарты.',
        '  - AMD Software -> Настройки -> Дисплей -> Vari-Bright: вкл.',
        '  - Steam, Discord, NVIDIA overlay и лишнее из автозагрузки - кнопка «Автозагрузка программ».'
}

function Do-BatteryUndo {
    Head 'ОТКАТ НАСТРОЕК БАТАРЕИ'
    $script:Cat = 'battery'
    $n = Undo-Journal 'battery'
    $cfg = Get-AgentConfig
    if ($cfg -and ($cfg.Refresh -or $cfg.DcOverlay)) {
        if ($cfg.AcOverlay) {
            Install-Agent @{ Refresh = $false; DcOverlay = '' }
            $rates = @([LTK.Disp]::Rates()); if ($rates.Count) { [void][LTK.Disp]::Set($rates[-1]) }
            Out-Box '  Автопереключение оставлено только для режима «Максимальная производительность» от сети (140 Вт).'
        } else { Uninstall-Agent }
        $n++
    }
    if ($n) { Out-Ok "Возвращено исходных значений: $n." } else { Out-Box 'Изменений батареи от этой программы нет.' }
}

function Do-PowerStatus {
    Head 'ПИТАНИЕ СЕЙЧАС'
    $ac = [LTK.Pwr]::OnAC()
    $pct = [LTK.Pwr]::BatteryPercent()
    Out-Box "Источник:            $(if ($ac -eq 1) {'сеть'} elseif ($ac -eq 0) {'БАТАРЕЯ'} else {'?'})$(if ($pct -ge 0) {", заряд $pct %"})"
    $sch = (powercfg /getactivescheme | Out-String).Trim()
    Out-Box "Схема:               $(($sch -split ':', 2)[-1].Trim())"
    $ov = [LTK.Pwr]::GetOverlay()
    Out-Box "Режим Windows:       $(if ($OverlayNames.ContainsKey($ov)) { $OverlayNames[$ov] } else { 'н/д' })"
    $rates = @([LTK.Disp]::Rates())
    Out-Box "Экран:               $([LTK.Disp]::Current()) Гц (доступно: $($rates -join ', '))"
    Out-Box "Графика:             $(Get-GraphicsModeText)"
    $cfg = Get-AgentConfig
    if ((Test-AgentTask) -and $cfg) {
        $parts = @()
        if ($cfg.Refresh) { $parts += "экран $($cfg.DcHz) Гц на батарее" }
        if ($cfg.DcOverlay) { $parts += 'экономичный режим на батарее' }
        if ($cfg.AcOverlay) { $parts += 'производительность от сети' }
        Out-Ok "Автопереключение:    вкл ($($parts -join ', '))"
    } else { Out-Box 'Автопереключение:    выкл (кнопка «Максимальная автономность»)' }

    Out-Box '', 'На батарее (текущая схема):'
    $fmt = {
        param($sub, $set, $label, $conv)
        $v = Get-Pow $sub $set
        $t = if ($v -lt 0) { 'нет на этом ноутбуке' } else { & $conv $v }
        Out-Box ('  {0,-34} {1}' -f $label, $t)
    }
    $sec = { param($v) if ($v -eq 0) { 'никогда' } elseif ($v -ge 60) { "$([int]($v / 60)) мин" } else { "$v с" } }
    & $fmt $PW.Proc $PW.Boost 'Турбобуст процессора' { param($v) if ($v -eq 0) { 'выкл (экономия)' } else { "вкл (режим $v)" } }
    & $fmt $PW.Proc $PW.Epp 'Энергоэффективность процессора' { param($v) "$v %" }
    & $fmt $PW.Saver $PW.SaverAt 'Экономия энергии включается при' { param($v) if ($v -ge 100) { 'всегда на батарее' } else { "$v % заряда" } }
    & $fmt $PW.Video $PW.ScreenOff 'Отключение экрана' $sec
    & $fmt $PW.Sleep $PW.SleepAfter 'Сон' $sec
    & $fmt $PW.Sleep $PW.HibAfter 'Гибернация после сна' $sec
    & $fmt $PW.None $PW.NetStandby 'Интернет во сне' { param($v) switch ($v) { 0 { 'выкл' } 1 { 'вкл' } default { 'решает Windows' } } }
    & $fmt $PW.Pcie $PW.Aspm 'PCIe ASPM' { param($v) switch ($v) { 0 { 'выкл' } 1 { 'умеренное' } default { 'максимальное' } } }
    $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled
    Out-Box ('  {0,-34} {1}' -f 'Гибернация в системе', $(if ($hib -eq 1) { 'включена' } else { 'выключена' }))
}

function Do-AgentLog {
    Head 'ЖУРНАЛ АВТОПЕРЕКЛЮЧЕНИЯ'
    $p = Join-Path $DataDir 'agent.log'
    if (-not (Test-AgentTask)) { Out-Box 'Автопереключение не включено (кнопка «Максимальная автономность» или «140 Вт: разблокировать»).'; return }
    if (-not (Test-Path $p)) { Out-Box 'Записей пока нет - отключите и подключите зарядку.'; return }
    Out-Dim 'Код после стрелки: 0 = успешно.'
    Get-Content $p -Encoding UTF8 | Select-Object -Last 25 | ForEach-Object { Out-Box $_ }
}

function Do-EnergyReport {
    $p = Join-Path $ReportDir 'energy_report.html'
    if (-not (Ask-User ("Windows 60 секунд понаблюдает за системой и найдёт, что мешает энергосбережению`n" +
        "(драйверы, программы, устройства, которые не дают процессору и USB засыпать).`n`n" +
        "Лучше запускать на батарее и закрыть программы. Начать?") 'Энергоотчёт')) { return }
    Start-Console 'Энергоотчёт (60 секунд)' "Write-Host 'Не трогайте ноутбук 60 секунд...'; powercfg /energy /output '$p' /duration 60; Start-Process '$p'"
}

function Do-SleepStudy {
    Head 'РАСХОД ВО СНЕ (Sleep Study)'
    $p = Join-Path $ReportDir 'sleepstudy.html'
    powercfg /sleepstudy /output "$p" 2>&1 | Out-Null
    if (Test-Path $p) { Out-Box "Отчёт: $p", 'Смотрите сеансы с большим «Energy Drain» и «Top Offenders» - что не давало спать.'; Start-Process $p }
    else { Out-Box '[!] Отчёт недоступен (ноутбук не поддерживает современный режим сна).' }
}

# ---------------- ВИРУСЫ / БЕЗОПАСНОСТЬ ----------------
function Do-AvStatus {
    Head 'АНТИВИРУС'
    try {
        Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
            ForEach-Object { Out-Box "Установлен антивирус: $($_.displayName)" }
    } catch { }
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        Out-Box @(
            "Защитник Windows:          $(if ($s.AntivirusEnabled) {'вкл'} else {'ВЫКЛ'})",
            "Защита в реальном времени: $(if ($s.RealTimeProtectionEnabled) {'вкл'} else {'ВЫКЛ  <-- проверьте!'})",
            "Защита от изменений:       $(if ($s.IsTamperProtected) {'вкл'} else {'выкл'})",
            "Базы обновлены:            $($s.AntivirusSignatureLastUpdated)",
            "Быстрая проверка была:     $($s.QuickScanAge) дн. назад, полная: $(if ($s.FullScanAge -gt 10000) {'никогда'} else {"$($s.FullScanAge) дн. назад"})"
        )
        $names = @{}
        Get-MpThreat -ErrorAction SilentlyContinue | ForEach-Object { $names["$($_.ThreatID)"] = $_.ThreatName }
        $det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Sort-Object InitialDetectionTime -Descending | Select-Object -First 15)
        if ($det.Count) {
            Out-Box '', '[!] Найденные угрозы (история):'
            foreach ($d in $det) { Out-Box "  $($d.InitialDetectionTime) | $($names["$($d.ThreatID)"]) | $($d.Resources -join '; ')" }
        } else { Out-Ok 'Угроз в истории Защитника нет.' }
        $pref = Get-MpPreference -ErrorAction SilentlyContinue
        $ex = @($pref.ExclusionPath) + @($pref.ExclusionProcess) + @($pref.ExclusionExtension) | Where-Object { $_ }
        if ($ex) {
            Out-Box '', '!!! Есть исключения Защитника (вирусы часто добавляют себя сюда):'
            $ex | ForEach-Object { Out-Box "    $_" }
        }
    } catch { Out-Box "Защитник недоступен (возможно, стоит другой антивирус): $($_.Exception.Message)" }
}

function Do-QuickScan { Start-Console 'Быстрая проверка' 'Update-MpSignature; Start-MpScan -ScanType QuickScan; Get-MpThreatDetection | Format-List' }
function Do-FullScan {
    if (-not (Ask-User 'Полная проверка всех дисков займёт 1-3 часа. Запустить?')) { return }
    Start-Console 'Полная проверка' 'Update-MpSignature; Start-MpScan -ScanType FullScan; Get-MpThreatDetection | Format-List'
}
function Do-OfflineScan {
    if (-not (Ask-User "Автономная проверка Защитником ПЕРЕЗАГРУЗИТ ноутбук через несколько секунд и проверит его до загрузки Windows (~15 мин). Ловит руткиты.`n`nСохраните работу. Продолжить?")) { return }
    Start-MpWDOScan
}
function Do-Msert {
    $url = 'https://go.microsoft.com/fwlink/?LinkId=212732'   # Microsoft Safety Scanner x64
    Start-Console 'Microsoft Safety Scanner' ("[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; `$ProgressPreference = 'SilentlyContinue'; " +
        "Write-Host 'Скачивание Microsoft Safety Scanner (~200 МБ)...'; `$p = Join-Path `$env:TEMP 'msert.exe'; " +
        "Invoke-WebRequest '$url' -OutFile `$p -UseBasicParsing; Start-Process `$p -Wait; Remove-Item `$p -Force")
}
function Do-Kvrt {
    Out-Box 'Второе мнение: Kaspersky Virus Removal Tool или Dr.Web CureIt! - бесплатные сканеры без установки. Открываю страницу KVRT.'
    Start-Process 'https://www.kaspersky.ru/downloads/free-virus-removal-tool'
}

function Do-Suspicious {
    Head 'ПОИСК ПОДОЗРИТЕЛЬНОГО (автозагрузка, задачи, службы, процессы)'
    Out-Box '[?] = стоит проверить. Это не приговор: Discord, Telegram, Steam и т.п. тоже живут в AppData.'
    $susPath = '\\AppData\\|\\Temp\\|\\Users\\Public\\|\\ProgramData\\[^\\]+\.exe'
    $susCmd  = '(?i)powershell.*\s-(e|ec|enc|encodedcommand)\s|mshta|wscript|cscript|regsvr32.*http|bitsadmin|certutil.*-urlcache|\.vbs|\.js(\s|"|$)'
    function Mark([string]$s) { if ($s -match $susCmd) { '[!]' } elseif ($s -match $susPath) { '[?]' } else { '   ' } }

    Out-Box '', '--- Автозагрузка ---'
    Get-CimInstance Win32_StartupCommand | ForEach-Object { Out-Box "$(Mark $_.Command) $($_.Name): $($_.Command)" }

    Out-Box '', '--- Планировщик заданий (не Microsoft, активные) ---'
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' } | ForEach-Object {
        $act = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; '
        if ($_.TaskPath -eq '\LaptopToolkit\') { Out-Dim "    $($_.TaskPath)$($_.TaskName): автопереключение этой программы" }
        elseif ($act) { Out-Box "$(Mark $act) $($_.TaskPath)$($_.TaskName): $act" }
    }

    Out-Box '', '--- Службы из нестандартных папок ---'
    $svc = @(Get-CimInstance Win32_Service | Where-Object { "$($_.PathName)" -match $susPath -or "$($_.PathName)" -match $susCmd })
    if ($svc.Count) { $svc | ForEach-Object { Out-Box "$(Mark $_.PathName) $($_.Name) [$($_.State)]: $($_.PathName)" } } else { Out-Box '    нет' }

    Out-Box '', '--- Топ процессов по нагрузке CPU (скрытые майнеры) ---'
    Get-Process | Where-Object { $_.CPU } | Sort-Object CPU -Descending | Select-Object -First 12 | ForEach-Object {
        Out-Box ('{0} {1,-28} CPU {2,8:N0} c  {3}' -f (Mark "$($_.Path)"), $_.ProcessName, $_.CPU, $_.Path)
    }

    Out-Box '', '--- Файл hosts ---'
    $hosts = @(Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[^#\s]' })
    if ($hosts.Count) { $hosts | ForEach-Object { Out-Box "[?] $_" } } else { Out-Box '    чистый' }

    Out-Box '', '--- Прокси ---'
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($ie.ProxyEnable -eq 1 -or $ie.AutoConfigURL) { Out-Box "[?] Включён прокси: $($ie.ProxyServer) $($ie.AutoConfigURL)" } else { Out-Box '    не используется' }
    Out-Box '', 'Глубже: Sysinternals Autoruns (кнопка «Установить утилиты»).'
}

# ---------------- ОПТИМИЗАЦИЯ WINDOWS ----------------
function Do-Restore {
    Head 'ТОЧКА ВОССТАНОВЛЕНИЯ'
    $cat = $script:Cat; $script:Cat = $null   # служебная настройка, в откат не пишем
    try {
        # снимаем лимит Windows «не чаще раза в 24 часа»
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
    } finally { $script:Cat = $cat }
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
    $t = (Get-Date).AddMinutes(-2)
    Checkpoint-Computer -Description 'LaptopToolkit' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
    $last = Get-ComputerRestorePoint | Sort-Object SequenceNumber | Select-Object -Last 1
    if ($last -and [Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime) -ge $t) {
        Out-Ok "Точка создана: $($last.Description). Откат: Win+R -> rstrui"
    } else { Out-Box '[!] Точка НЕ создалась. Проверьте: Win+R -> SystemPropertiesProtection.' }
}

$Bloat = [ordered]@{
    'Microsoft.BingNews' = 'Новости'; 'Microsoft.BingWeather' = 'Погода'; 'Microsoft.GetHelp' = 'Техподдержка'
    'Microsoft.Getstarted' = 'Советы'; 'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire'; 'Microsoft.MicrosoftOfficeHub' = 'Office Hub'
    'Microsoft.People' = 'Люди'; 'Microsoft.PowerAutomateDesktop' = 'Power Automate'; 'Microsoft.Todos' = 'To Do'
    'Clipchamp.Clipchamp' = 'Clipchamp'; 'Microsoft.WindowsFeedbackHub' = 'Центр отзывов'; 'MicrosoftTeams' = 'Teams (личный)'
    'MSTeams' = 'Teams (новый)'; 'Microsoft.549981C3F5F10' = 'Cortana'; 'Microsoft.WindowsMaps' = 'Карты'
    'Microsoft.MixedReality.Portal' = 'Смешанная реальность'; 'Microsoft.SkypeApp' = 'Skype'; 'Microsoft.Copilot' = 'Copilot'
}

function Do-WinOptimize {
    $items = @(
        @{ Group = 'Игры'; Key = 'gamemode'; On = $true; Text = 'Игровой режим Windows: вкл'; Hint = 'Игре - приоритет, фоновые обновления не мешают.' }
        @{ Group = 'Игры'; Key = 'dvr'; On = $true; Text = 'Фоновая запись Xbox Game Bar: выкл'; Hint = 'Постоянная запись последних минут игры отнимает FPS. Сам Game Bar (Win+G) остаётся.' }
        @{ Group = 'Игры'; Key = 'hags'; On = $true; Text = 'Аппаратное планирование GPU (HAGS): вкл'; Hint = 'Меньше задержка, нужно для DLSS Frame Generation. Применится после перезагрузки.' }
        @{ Group = 'Приватность и реклама'; Key = 'telemetry'; On = $true; Text = 'Телеметрия: минимум, службы DiagTrack и dmwappushservice выкл'; Hint = 'Меньше фоновой отправки данных - и меньше расход батареи.' }
        @{ Group = 'Приватность и реклама'; Key = 'ads'; On = $true; Text = 'Реклама, «рекомендации» и автоустановка приложений: выкл'; Hint = 'Рекламный ID, предложения в Пуске и Параметрах, тихая установка Candy Crush и т.п.' }
        @{ Group = 'Приватность и реклама'; Key = 'bing'; On = $true; Text = 'Bing в поиске меню Пуск: выкл'; Hint = 'Поиск в Пуске ищет только на компьютере - быстрее и без лишнего трафика.' }
        @{ Group = 'Приватность и реклама'; Key = 'widgets'; On = $true; Text = 'Виджеты и новости на панели задач: выкл'; Hint = 'Убирает фоновые процессы виджетов (Edge WebView).' }
        @{ Group = 'Приватность и реклама'; Key = 'copilot'; On = $true; Text = 'Copilot: выкл'; Hint = 'Убирает кнопку и отключает Copilot политикой.' }
        @{ Group = 'Система'; Key = 'delivery'; On = $true; Text = 'Не раздавать обновления другим компьютерам'; Hint = 'Оптимизация доставки только качает, а не раздаёт ваш интернет чужим ПК.' }
        @{ Group = 'Система'; Key = 'debloat'; On = $true; Text = 'Удалить предустановленный мусор'
           Hint = "$(@($Bloat.Values) -join ', '). Без отката: вернуть можно из Microsoft Store." }
        @{ Group = 'Система'; Key = 'fileext'; On = $true; Text = 'Показывать расширения файлов'; Hint = 'Защита от вирусов вида «фото.jpg.exe».' }
        @{ Group = 'Система'; Key = 'transp'; On = $false; Text = 'Отключить прозрачность окон'; Hint = 'Чуть меньше нагрузка на графику и расход батареи, но интерфейс проще.' }
        @{ Group = 'Система'; Key = 'ctxmenu'; On = $false; Text = 'Классическое контекстное меню (как в Windows 10)'; Hint = 'Без «Показать дополнительные параметры». Применится после перезапуска Проводника.' }
    )
    $sel = Show-Options 'Оптимизация Windows' ("Выберите, что изменить. Всё, кроме удаления приложений, можно вернуть кнопкой «Откатить оптимизацию Windows».`n" +
        'Для батареи - отдельная кнопка «Максимальная автономность».') $items
    if ($null -eq $sel) { return }
    if (-not $sel.Count) { Out-Box 'Ничего не выбрано.'; return }
    if (Ask-User 'Создать точку восстановления перед изменениями? (рекомендуется)' 'Оптимизация Windows') {
        try { Do-Restore } catch { Out-Box "[!] Точка восстановления: $($_.Exception.Message)" }
    }
    Head 'ОПТИМИЗАЦИЯ WINDOWS'
    $script:Cat = 'windows'
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if ($sel['gamemode']) {
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
        Out-Ok '  + Игровой режим'
    }
    if ($sel['dvr']) {
        Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
        Out-Ok '  + Фоновая запись игр выкл'
    }
    if ($sel['hags']) { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2; Out-Ok '  + HAGS вкл (после перезагрузки)' }
    if ($sel['telemetry']) {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
        foreach ($s in 'DiagTrack', 'dmwappushservice') { [void](Set-Svc $s 'Disabled') }
        Out-Ok '  + Телеметрия минимум, службы выкл'
    }
    if ($sel['ads']) {
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
        $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($n in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'SubscribedContent-338388Enabled',
                       'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
                       'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled') { Set-Reg $cdm $n 0 }
        Set-Reg $adv 'Start_IrisRecommendations' 0
        Out-Ok '  + Реклама и рекомендации выкл'
    }
    if ($sel['bing']) {
        Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
        Out-Ok '  + Bing в поиске выкл'
    }
    if ($sel['widgets']) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0; Out-Ok '  + Виджеты выкл' }
    if ($sel['copilot']) {
        Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
        Set-Reg $adv 'ShowCopilotButton' 0
        Out-Ok '  + Copilot выкл'
    }
    if ($sel['delivery']) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0; Out-Ok '  + Раздача обновлений выкл' }
    if ($sel['fileext']) { Set-Reg $adv 'HideFileExt' 0; Out-Ok '  + Расширения файлов видны' }
    if ($sel['transp']) { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0; Out-Ok '  + Прозрачность выкл' }
    if ($sel['ctxmenu']) {
        Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String'
        Out-Ok '  + Классическое контекстное меню'
    }
    if ($sel['debloat']) {
        $removed = @()
        foreach ($k in $Bloat.Keys) {
            $pk = @(Get-AppxPackage -Name $k -ErrorAction SilentlyContinue)
            if (-not $pk.Count) { continue }
            $statusLbl.Text = "Удаляю: $($Bloat[$k])..."; [Windows.Forms.Application]::DoEvents()
            $pk | Remove-AppxPackage -ErrorAction SilentlyContinue
            if (-not (Get-AppxPackage -Name $k -ErrorAction SilentlyContinue)) { $removed += $Bloat[$k] }
        }
        if ($removed.Count) { Out-Ok "  + Удалено: $($removed -join ', ')" } else { Out-Dim '  - Лишних приложений не найдено' }
    }
    Out-Box '', 'Готово. Часть изменений применится после перезагрузки.'
    if ($sel['widgets'] -or $sel['copilot'] -or $sel['fileext'] -or $sel['ctxmenu'] -or $sel['ads']) {
        if (Ask-User 'Перезапустить Проводник, чтобы изменения панели задач применились сейчас? (окна папок закроются)' 'Оптимизация Windows') {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        }
    }
}

function Do-WinUndo {
    Head 'ОТКАТ ОПТИМИЗАЦИИ WINDOWS'
    $script:Cat = 'windows'
    $n = Undo-Journal 'windows'
    if ($n) { Out-Ok "Возвращено исходных значений: $n. Перезагрузите ноутбук." }
    else { Out-Box 'Изменений от этой программы нет. Более глубокий откат - точка восстановления: Win+R -> rstrui' }
}

function Do-Cleanup {
    Head 'ОЧИСТКА'
    $before = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
    foreach ($d in @($env:TEMP, "$env:SystemRoot\Temp")) {
        Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    $after = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
    Out-Ok "Временные файлы и корзина очищены, освобождено $([math]::Round(($after - $before) / 1MB)) МБ (занятые файлы пропущены)."
    if (Ask-User 'Дополнительно очистить старые обновления Windows (DISM, 5-15 минут)?') {
        Start-Console 'Очистка компонентов' 'DISM /Online /Cleanup-Image /StartComponentCleanup'
    }
}

function Do-Repair { Start-Console 'Ремонт Windows (DISM + SFC)' 'DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow' }

function Do-Update {
    Head 'ОБНОВЛЕНИЯ'
    if (Test-Winget) {
        Start-Console 'Обновление программ (winget)' 'winget upgrade --all --accept-package-agreements --accept-source-agreements'
    }
    Out-Box 'Открываю Центр обновления Windows - нажмите «Проверить наличие обновлений» и «Дополнительные обновления».'
    Start-Process 'ms-settings:windowsupdate'
}

function Do-DriversWeb {
    Out-Box @('', 'Драйверы:',
        '  NVIDIA - NVIDIA App (сама обновляет драйвер видеокарты; при проблемах с 140 Вт - «Чистая установка»)',
        '  AMD - Chipset + графика Radeon 780M: сайт AMD -> Ryzen 7 8845HS',
        '  BIOS и остальное - сайт поддержки Skytech (по серийному номеру)')
    Start-Process 'https://www.nvidia.com/en-us/software/nvidia-app/'
    Start-Process 'https://www.amd.com/en/support/download/drivers.html'
}

function Do-Startup {
    Out-Box 'Открываю Диспетчер задач -> Автозагрузка. Отключайте всё, что не нужно сразу после включения (Steam, Discord, лаунчеры).'
    Start-Process taskmgr.exe -ArgumentList '/0 /startup'
}

function Do-WinUtil {
    if (-not (Ask-User ("Chris Titus WinUtil - популярная открытая утилита для удаления мусора и твиков Windows.`n" +
        "Скрипт скачивается с christitus.com и выполняется с правами администратора.`n`n" +
        "ВАЖНО: не отключайте в ней службы NVIDIA и не ставьте схему «Ultimate Performance» -`n" +
        "пропадёт Dynamic Boost (140 Вт) и сильно упадёт время работы от батареи.`n`nЗапустить?"))) { return }
    Start-Console 'Chris Titus WinUtil' "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm 'https://christitus.com/win' | iex"
}

# ---------------- ТЕСТЫ ----------------
function Start-CpuStress([int]$sec) {
    if ($script:StressJobs.Count) { Out-Box 'Стресс-тест уже идёт.'; return }
    if (-not (Ask-User ("Нагрузка на все ядра процессора на $([int]($sec / 60)) мин.`n`n" +
        "Подключите зарядку. Температуру смотрите в HWiNFO64: до 95 °C для 8845HS норма.`n" +
        "Если ноутбук выключается или зависает - это проблема охлаждения/питания.`n`nЗапустить?") 'Стресс CPU')) { return }
    $script:StressGHz.Clear()
    $script:StressEnd = (Get-Date).AddSeconds($sec)
    $script:StressJobs = @(1..[Environment]::ProcessorCount | ForEach-Object {
        Start-Job -ArgumentList $sec -ScriptBlock {
            param($s)
            $end = [DateTime]::Now.AddSeconds($s); $x = 0.0
            while ([DateTime]::Now -lt $end) { for ($i = 1; $i -lt 200000; $i++) { $x = [Math]::Sqrt($i) * 1.0001 } }
        }
    })
    Head 'СТРЕСС CPU'
    Out-Box "Запущено $($script:StressJobs.Count) потоков нагрузки. Частота ядер видна в мониторе сверху."
}

function Stop-CpuStress([switch]$Finished) {
    if (-not $script:StressJobs.Count) { return }
    $script:StressJobs | Stop-Job -ErrorAction SilentlyContinue
    $script:StressJobs | Remove-Job -Force -ErrorAction SilentlyContinue
    $script:StressJobs = @()
    $g = $script:StressGHz
    Out-Box "Стресс-тест $(if ($Finished) {'завершён'} else {'остановлен'})."
    if ($g.Count -gt 5) {
        $tail = $g | Select-Object -Skip ([int]($g.Count / 2))
        $avg = [math]::Round(($tail | Measure-Object -Average).Average, 2)
        $min = [math]::Round(($tail | Measure-Object -Minimum).Minimum, 2)
        Out-Box "Частота под нагрузкой (вторая половина теста): средняя $avg ГГц, минимум $min ГГц."
        if ($avg -lt 3.3) { Out-Box '[!] Частота низкая - похоже на перегрев/троттлинг: чистка от пыли, подставка, режим Performance, работа от сети.' }
        else { Out-Ok 'Частота держится нормально.' }
    }
}

function Do-RamTest {
    if (-not (Ask-User 'Проверка памяти Windows перезагрузит ноутбук сразу (~20 мин). Результат появится после входа в Windows. Сохраните работу. Продолжить?')) { return }
    Start-Process mdsched.exe -ArgumentList '/r'
}
function Do-DiskSpeed { Start-Console 'Тест скорости диска' "winsat disk -drive $($env:SystemDrive.TrimEnd(':'))" }

# ---------------- УТИЛИТЫ ----------------
function Do-Tools {
    if (-not (Test-Winget)) { return }
    $tools = [ordered]@{
        'HWiNFO64 - все температуры и датчики'        = 'REALiX.HWiNFO'
        'MSI Afterburner - разгон/андервольт RTX 4070' = 'Guru3D.Afterburner'
        'OCCT - стресс CPU/GPU/RAM/БП'                 = 'OCBase.OCCT.Personal'
        'FurMark 2 - стресс видеокарты (замер 140 Вт)' = 'Geeks3D.FurMark.2'
        'Cinebench R23 - тест процессора'              = 'Maxon.CinebenchR23'
        'CPU-Z'                                        = 'CPUID.CPU-Z'
        'GPU-Z'                                        = 'TechPowerUp.GPU-Z'
        'CrystalDiskInfo - здоровье SSD'               = 'CrystalDewWorld.CrystalDiskInfo'
        'CrystalDiskMark - скорость SSD'               = 'CrystalDewWorld.CrystalDiskMark'
        'Sysinternals Autoruns - вся автозагрузка'     = 'Microsoft.Sysinternals.Autoruns'
        '7-Zip'                                        = '7zip.7zip'
    }
    $items = foreach ($k in $tools.Keys) { @{ Key = $k; Text = $k; On = ($k -match 'HWiNFO|Afterburner|OCCT|FurMark|CrystalDiskInfo') } }
    $sel = Show-Options 'Установить утилиты (winget)' 'Отмеченные программы установятся с официальных источников через winget в отдельном окне.' @($items) 'Установить'
    if ($null -eq $sel -or -not $sel.Count) { return }
    $cmds = foreach ($k in $tools.Keys) { if ($sel[$k]) { "winget install -e --id $($tools[$k]) --accept-package-agreements --accept-source-agreements" } }
    Start-Console 'Установка утилит' ($cmds -join '; ')
}

function Do-Afterburner {
    $p = "${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe"
    if (Test-Path $p) { Start-Process $p; Out-Box 'MSI Afterburner запущен.' }
    else { Out-Box 'MSI Afterburner не установлен - кнопка «Установить утилиты».' }
}

function Do-OcGuide {
    Head 'РАЗГОН И ПРОИЗВОДИТЕЛЬНОСТЬ'
    Out-Box @(
        'ПРОЦЕССОР (Ryzen 7 8845HS)',
        '  - Мобильный, множитель заблокирован: классический разгон невозможен.',
        '  - Возможен только андервольт (Curve Optimizer), если его открывает BIOS ноутбука.',
        '    Сторонние утилиты вроде UXTU - на свой риск.',
        '  - Реальные рычаги: режим Performance (фирменная утилита/BIOS), работа от сети,',
        '    охлаждающая подставка, чистка от пыли, новая термопаста раз в 1-2 года.',
        '',
        'ПАМЯТЬ (DDR5-5600, одна планка)',
        '  - BIOS ноутбука не даёт менять частоту/тайминги: разгона нет.',
        '  - ГЛАВНЫЙ апгрейд: вторая такая же планка 16 ГБ DDR5-5600 SODIMM = двухканал.',
        '',
        'ВИДЕОКАРТА (RTX 4070 Laptop) - MSI Afterburner',
        '  0. Сначала мощность: кнопка «140 Вт: разблокировать» (раздел ВИДЕОКАРТА 140 ВТ).',
        '  1. Установите Afterburner + HWiNFO + OCCT/FurMark (кнопка «Установить утилиты»).',
        '  2. Core Clock +100, Memory Clock +500 -> Apply -> тест 10 мин (FurMark 2 / OCCT / любимая игра).',
        '  3. Стабильно - поднимайте шагом +25 core / +250 mem.',
        '     Артефакты, вылет игры или драйвера -> шаг назад. Это и есть ваш предел.',
        '  4. Обычный итог для ноутбучной 4070: +125..+200 core, +800..+1500 mem.',
        '  5. Андервольт (тише и холоднее при том же FPS): Ctrl+F -> кривая,',
        '     зафиксировать ~2400-2550 МГц на 0.875-0.900 В, проверить стабильность.',
        '     Андервольт оставляет больше из 140 Вт на частоту - часто это лучше разгона.',
        '  6. Ползунок Power Limit в Afterburner на ноутбуке заблокирован - мощностью управляет Dynamic Boost.',
        '  Разгон видеокарты сбрасывается кнопкой Reset в Afterburner.',
        '',
        'БЕСПЛАТНЫЙ FPS',
        '  - Панель управления NVIDIA -> Управление режимом дисплея -> «Только дискретная графика» (если есть): +5..15%.',
        '    На батарее верните «Автоматический выбор» - иначе заряд уходит в разы быстрее.',
        '  - Играть только от сети: на батарее видеокарта сильно урезана.',
        '  - Кнопки «Оптимизация Windows» и «140 Вт: разблокировать» в этой программе.',
        '  - Свежие драйверы NVIDIA и AMD Chipset (кнопка «Драйверы NVIDIA / AMD»).'
    )
}

# ---------------- WINDOWS ----------------
function Do-DriverBackup {
    $dest = Join-Path $ReportDir 'DriversBackup'
    Start-Console 'Бэкап драйверов' "New-Item -ItemType Directory -Force -Path '$dest' | Out-Null; Export-WindowsDriver -Online -Destination '$dest' | Out-Null; Write-Host 'Драйверы сохранены в $dest' -ForegroundColor Green"
}

function Do-WinGuide {
    Head 'ЧИСТАЯ WINDOWS ВМЕСТО «КАСТОМНОЙ СБОРКИ»'
    Out-Box @(
        'Почему не сборки (Ghost Spectre, Tiny11, «Windows by ...»): неизвестный код, вырезаны защита и обновления,',
        'бывают майнеры и бэкдоры, ломаются драйверы и игровые античиты.',
        'Оригинальный образ + оптимизация этой программой = та же скорость без риска.',
        '',
        'ПЛАН',
        '  1. «Бэкап драйверов» -> скопируйте папку DriversBackup на флешку (особенно важен Wi-Fi!).',
        '  2. Сохраните личные файлы и пароли.',
        '  3. «Скачать Windows 11» -> Media Creation Tool -> флешка 8+ ГБ.',
        '  4. Загрузка с флешки (Boot Menu: F7/F11/F12/Esc при включении - зависит от модели),',
        '     удалить все разделы системного диска -> установка в незанятое место.',
        '  5. Драйверы: Диспетчер устройств -> Обновить драйвер -> папка с флешки; затем NVIDIA App и AMD.',
        '  6. Запустите этот Toolkit: Обновить всё -> 140 Вт: разблокировать -> Оптимизация Windows -> Максимальная автономность.'
    )
    try {
        $v = Get-CimInstance -Namespace root\cimv2\Security\MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
        if ($v.ProtectionStatus -eq 1) {
            Out-Box '', '!!! Диск зашифрован (BitLocker/шифрование устройства). ДО переустановки сохраните ключ восстановления:',
                    '    aka.ms/myrecoverykey (аккаунт Microsoft) или в командной строке: manage-bde -protectors -get C:'
        }
    } catch { }
}

# ---------------- ОТЧЁТ ----------------
function Do-Save {
    $p = Join-Path $ReportDir "Report_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"
    Write-Utf8 $p $script:Log.ToString()
    Out-Ok '', "Отчёт сохранён: $p"
}

# ---------------- КНОПКИ ----------------
Add-Section 'ДИАГНОСТИКА'
Add-Btn 'ПОЛНАЯ ПРОВЕРКА (всё + отчёт)' { Do-Full } 'Все проверки подряд и сохранение отчёта в папку LaptopToolkit на рабочем столе.' -Primary
Add-Btn 'Система / процессор' { Do-System }
Add-Btn 'Оперативная память' { Do-Ram }
Add-Btn 'Видеокарта' { Do-Gpu }
Add-Btn 'Диски / SSD' { Do-Disk }
Add-Btn 'Батарея (износ, отчёт)' { Do-Battery }
Add-Btn 'Проблемные драйверы' { Do-Drivers }
Add-Btn 'Журнал сбоев (BSOD, WHEA)' { Do-Events }

Add-Section 'ВИДЕОКАРТА 140 ВТ'
Add-Btn '140 Вт: разблокировать' { Do-Gpu140 } 'Включает Dynamic Boost, службы NVIDIA и режим «Максимальная производительность» от сети. vBIOS не трогает.' -Primary
Add-Btn 'Проверить мощность GPU' { Do-GpuCheck } 'Только показывает лимиты, Dynamic Boost и режимы - ничего не меняет.'
Add-Btn 'Замер пиковой мощности GPU' { Do-GpuPeak } 'Включает мониторинг GPU и показывает пик ватт, пока вы играете или гоняете FurMark.'

Add-Section 'БАТАРЕЯ / АВТОНОМНОСТЬ'
Add-Btn 'Максимальная автономность' { Do-BatteryOptimize } 'Настройки, которые действуют только на батарее: 60 Гц, без турбобуста, экономия энергии, сон, устройства.' -Primary
Add-Btn 'Состояние питания сейчас' { Do-PowerStatus } 'Источник питания, режим Windows, частота экрана и все настройки батареи.'
Add-Btn 'Что не даёт видеокарте уснуть' { Do-GpuHolders } 'Какие программы держат RTX 4070 включённой и садят батарею.'
Add-Btn 'Энергоотчёт (что мешает экономии)' { Do-EnergyReport } 'powercfg /energy: 60 секунд наблюдения, HTML-отчёт с проблемами.'
Add-Btn 'Расход во сне (Sleep Study)' { Do-SleepStudy } 'Сколько заряда ушло во сне и что не давало спать.'
Add-Btn 'Журнал автопереключения' { Do-AgentLog } 'Когда и что переключалось при подключении/отключении зарядки.'
Add-Btn 'Откатить настройки батареи' { Do-BatteryUndo } 'Возвращает исходные значения всего, что изменила «Максимальная автономность».'

Add-Section 'ОПТИМИЗАЦИЯ WINDOWS'
Add-Btn 'Оптимизация Windows' { Do-WinOptimize } 'Игры, приватность, реклама, мусорные приложения - с выбором галочками.' -Primary
Add-Btn 'Точка восстановления' { Do-Restore }
Add-Btn 'Автозагрузка программ' { Do-Startup }
Add-Btn 'Очистка диска' { Do-Cleanup }
Add-Btn 'Ремонт Windows (DISM+SFC)' { Do-Repair }
Add-Btn 'Обновить всё' { Do-Update }
Add-Btn 'Драйверы NVIDIA / AMD' { Do-DriversWeb }
Add-Btn 'Chris Titus WinUtil' { Do-WinUtil }
Add-Btn 'Откатить оптимизацию Windows' { Do-WinUndo } 'Возвращает исходные значения всего, что изменила «Оптимизация Windows» (кроме удалённых приложений).'

Add-Section 'ВИРУСЫ'
Add-Btn 'Статус антивируса и угрозы' { Do-AvStatus }
Add-Btn 'Поиск подозрительного' { Do-Suspicious }
Add-Btn 'Быстрая проверка Защитником' { Do-QuickScan }
Add-Btn 'Полная проверка Защитником' { Do-FullScan }
Add-Btn 'Автономная проверка (ребут)' { Do-OfflineScan }
Add-Btn 'Microsoft Safety Scanner' { Do-Msert }
Add-Btn 'Второе мнение (KVRT)' { Do-Kvrt }

Add-Section 'ТЕСТЫ'
Add-Btn 'Стресс CPU 1 мин' { Start-CpuStress 60 }
Add-Btn 'Стресс CPU 10 мин' { Start-CpuStress 600 }
Add-Btn 'Остановить стресс' { Stop-CpuStress }
Add-Btn 'Тест RAM (перезагрузка)' { Do-RamTest }
Add-Btn 'Тест скорости диска' { Do-DiskSpeed }

Add-Section 'РАЗГОН'
Add-Btn 'Гайд по разгону' { Do-OcGuide }
Add-Btn 'Установить утилиты' { Do-Tools }
Add-Btn 'Запустить MSI Afterburner' { Do-Afterburner }

Add-Section 'WINDOWS'
Add-Btn 'Как поставить чистую Windows' { Do-WinGuide }
Add-Btn 'Бэкап драйверов' { Do-DriverBackup }
Add-Btn 'Скачать Windows 11 (офиц.)' { Start-Process 'https://www.microsoft.com/software-download/windows11'; Out-Box 'Открыт сайт Microsoft.' }

Add-Section 'ОТЧЁТ'
Add-Btn 'Сохранить отчёт' { Do-Save }
Add-Btn 'Открыть папку отчётов' { Start-Process explorer.exe $ReportDir }
Add-Btn 'Очистить экран' { $box.Clear(); [void]$script:Log.Clear() }

# ---------------- МОНИТОР ----------------
function Update-State {
    $ac = [LTK.Pwr]::OnAC()
    $ov = [LTK.Pwr]::GetOverlay()
    $ovName = if ($OverlayNames.ContainsKey($ov)) { $OverlayNames[$ov] } else { 'н/д' }
    $agent = if ($script:AgentOn) { 'вкл' } else { 'выкл' }
    $stateLbl.Text = "Питание: $(if ($ac -eq 1) {'сеть'} elseif ($ac -eq 0) {'батарея'} else {'?'})   |   Режим: $ovName   |   Экран: $([LTK.Disp]::Current()) Гц   |   Автопереключение: $agent"
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    $timer.Stop()   # Out-Box вызывает DoEvents - не даём тику войти сам в себя
    try {
        if ($form.WindowState -eq 'Minimized') { return }   # свёрнуто - не тратим батарею на опрос
        $ac = [LTK.Pwr]::OnAC()
        $timer.Interval = if ($ac -eq 0) { 5000 } else { 2000 }

        $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
        $ghz = [math]::Round($MaxMHz * $p.PercentProcessorPerformance / 100 / 1000, 2)
        $mem = [LTK.Win]::Memory()
        $tot = [math]::Round($mem[0] / 1GB, 1)
        $used = [math]::Round(($mem[0] - $mem[1]) / 1GB, 1)
        $b = ''
        if ([LTK.Pwr]::HasBattery()) {
            $b = "   Батарея: $([LTK.Pwr]::BatteryPercent())%"
            if ($ac -eq 1) { $b += ' (сеть)' }
            else {
                $sec = [LTK.Pwr]::BatterySeconds()
                if ($sec -gt 0) { $b += " (~$([int][math]::Floor($sec / 3600)) ч $([int](($sec % 3600) / 60)) мин)" }
                if (-not $script:NoBatWmi) {
                    try {
                        $bs = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
                        if ($bs.DischargeRate -gt 0) { $b += "  расход $([math]::Round($bs.DischargeRate / 1000, 1)) Вт" }
                    } catch { $script:NoBatWmi = $true }
                }
            }
        }
        $line1 = "CPU: $($p.PercentProcessorTime)% @ $ghz ГГц   RAM: $used / $tot ГБ$b"

        if ($ac -eq 0 -and $chkGpu.Checked) {
            $chkGpu.Checked = $false
            Out-Dim 'Мониторинг GPU выключен: на батарее он не даёт видеокарте уснуть.'
        }
        $line2 = 'GPU: мониторинг выкл (галочка справа)'
        if ($chkGpu.Checked -and $Smi) {
            $q = & $Smi --query-gpu=temperature.gpu,utilization.gpu,power.draw,enforced.power.limit,clocks.gr --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($q) {
                $v = "$q" -split ',\s*'
                $w = Num $v[2]
                if ($w -gt $script:GpuPeak) { $script:GpuPeak = $w }
                $line2 = "GPU: $($v[0]) °C | $($v[1]) % | $($v[2]) Вт (лимит $($v[3]), пик $([math]::Round($script:GpuPeak, 1))) | $($v[4]) МГц"
            }
        }
        if ($script:StressJobs.Count) {
            $script:StressGHz.Add($ghz)
            $left_s = [int]($script:StressEnd - (Get-Date)).TotalSeconds
            $line2 += "      СТРЕСС-ТЕСТ: осталось $([math]::Max(0, $left_s)) с"
            if ((Get-Date) -gt $script:StressEnd.AddSeconds(3)) { Stop-CpuStress -Finished }
        }
        $mon.Text = "$line1`r`n$line2"
        Update-State
    } catch { $mon.Text = "Монитор: $($_.Exception.Message)" }
    finally { $timer.Start() }
})

$form.Add_Shown({
    $script:AgentOn = Test-AgentTask
    Update-State
    $timer.Start()
    Out-Box "Laptop Toolkit v$Version" $accent
    Out-Box 'С чего начать:',
        '  1. «ПОЛНАЯ ПРОВЕРКА» - отчёт сохранится в папку LaptopToolkit на рабочем столе.',
        '  2. «140 Вт: разблокировать» - полная мощность RTX 4070 от сети.',
        '  3. «Оптимизация Windows» и «Максимальная автономность» - быстрее от сети, дольше от батареи.',
        'Наведите курсор на кнопку - появится подсказка.'
    Invoke-Safe 'Система' { Do-System; Do-Ram }
})
$form.Add_FormClosing({
    $timer.Stop()
    Get-Job | Stop-Job -ErrorAction SilentlyContinue
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
})

try { [void]$form.ShowDialog() }
finally { [Environment]::Exit(0) }
