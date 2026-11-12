# LaptopToolkit v4.1 - Skytech Noir (Ryzen 7 8845HS / DDR5-5600 / RTX 4070 Laptop до 140 Вт)
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
$Version = '4.1'

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
            if (string.IsNullOrEmpty(scheme)) return -1;
            Guid sc = new Guid(scheme), s = new Guid(sub), st = new Guid(setting);
            uint v;
            uint r = dc ? PowerReadDCValueIndex(IntPtr.Zero, ref sc, ref s, ref st, out v)
                        : PowerReadACValueIndex(IntPtr.Zero, ref sc, ref s, ref st, out v);
            return r == 0 ? (long)v : -1;
        }
        public static uint Write(string scheme, string sub, string setting, bool dc, uint value)
        {
            if (string.IsNullOrEmpty(scheme)) return 87;
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

$MaxMHz = 0
try { $MaxMHz = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).MaxClockSpeed } catch { }
if (-not $MaxMHz) { $MaxMHz = (Get-ItemProperty "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -ErrorAction SilentlyContinue).'~MHz' }
$OsBuild = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).CurrentBuildNumber
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

# ---------------- окно: элементы интерфейса ----------------
# Рисуемые элементы (карточки, плитки, навигация) - на C#: так они плавные и без мерцания.
$UiSource = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace LTK.UI
{
    public static class Theme
    {
        public static float Scale = 1f;
        public static int S(float v) { return (int)Math.Round(v * Scale); }
        public static Color Bg       = Color.FromArgb(16, 18, 22);
        public static Color Surface  = Color.FromArgb(25, 28, 34);
        public static Color Surface2 = Color.FromArgb(35, 39, 47);
        public static Color Border   = Color.FromArgb(45, 50, 60);
        public static Color Accent   = Color.FromArgb(0, 200, 172);
        public static Color Fore     = Color.FromArgb(232, 234, 237);
        public static Color Dim      = Color.FromArgb(148, 155, 167);
        public static Color Ok = Color.FromArgb(92, 210, 130), Warn = Color.FromArgb(245, 180, 65), Bad = Color.FromArgb(245, 100, 100);

        public static Color Mix(Color a, Color b, float t)
        {
            return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }
        public static GraphicsPath Round(RectangleF r, float rad)
        {
            GraphicsPath p = new GraphicsPath();
            float d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
            if (d <= 1) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
        public static void FillRound(Graphics g, RectangleF r, float rad, Color fill, Color line)
        {
            using (GraphicsPath p = Round(r, rad))
            {
                using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
                if (line != Color.Empty) using (Pen pen = new Pen(line, 1f)) g.DrawPath(pen, p);
            }
        }

        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);

        // Тёмный заголовок окна (Windows 10 20H1+) и его цвет (Windows 11).
        public static void DarkTitle(IntPtr h, Color caption)
        {
            int on = 1;
            try { if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4); } catch { }
            try { int c = caption.R | (caption.G << 8) | (caption.B << 16); DwmSetWindowAttribute(h, 35, ref c, 4); } catch { }
        }
        // Тёмные полосы прокрутки у стандартных элементов.
        public static void DarkScroll(Control c) { try { SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch { } }
    }

    public class Smooth : Control
    {
        protected bool Hot, Pressed;
        public Smooth()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        }
        protected override void OnMouseEnter(EventArgs e) { Hot = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { Hot = false; Pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { Pressed = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { Pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
        protected Graphics Begin(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(Parent != null ? Parent.BackColor : Theme.Bg);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            return g;
        }
        protected static void Draw(Graphics g, string s, Font f, Rectangle r, Color c, TextFormatFlags extra)
        {
            if (string.IsNullOrEmpty(s) || f == null || r.Width <= 0 || r.Height <= 0) return;
            TextRenderer.DrawText(g, s, f, r, c, TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | extra);
        }
    }


    // Строка состояния: значок (✓ ! ✕ i …), заголовок, пояснение, значение и кнопка или переключатель справа.
    public class Row : Smooth
    {
        public string Title = "", Desc = "", Value = "", Action = "";
        public int State = 4;   // 0 - инфо, 1 - хорошо, 2 - внимание, 3 - плохо, 4 - проверяю, 5 - недоступно
        public bool Switch, On, Primary;
        public Font TitleFont, DescFont, ValueFont, ActionFont;
        public event EventHandler ActionClick;
        Rectangle act = Rectangle.Empty;
        bool actHot;

        bool Clickable() { return State != 4 && (Switch ? State != 5 : Action.Length > 0); }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            bool h = act.Contains(e.Location) && Clickable();
            if (h != actHot) { actHot = h; Cursor = h ? Cursors.Hand : Cursors.Default; Invalidate(); }
            base.OnMouseMove(e);
        }
        protected override void OnMouseLeave(EventArgs e) { actHot = false; Cursor = Cursors.Default; base.OnMouseLeave(e); }
        protected override void OnMouseClick(MouseEventArgs e)
        {
            base.OnMouseClick(e);
            if (e.Button == MouseButtons.Left && act.Contains(e.Location) && Clickable() && ActionClick != null) ActionClick(this, EventArgs.Empty);
        }
        public static Color StateColor(int s)
        {
            switch (s) { case 1: return Theme.Ok; case 2: return Theme.Warn; case 3: return Theme.Bad; case 0: return Theme.Accent; default: return Theme.Dim; }
        }

        static void Mark(Graphics g, Rectangle r, int s, Color c)
        {
            float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f, u = r.Width / 28f;
            using (Pen p = new Pen(c, Math.Max(1.6f, 2.3f * u)))
            using (SolidBrush b = new SolidBrush(c))
            {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                switch (s)
                {
                    case 1: g.DrawLines(p, new PointF[] { new PointF(cx - 6 * u, cy + 0.5f * u), new PointF(cx - 1.5f * u, cy + 5 * u), new PointF(cx + 6.5f * u, cy - 4.5f * u) }); break;
                    case 2: g.DrawLine(p, cx, cy - 6 * u, cx, cy + 1.5f * u); g.FillEllipse(b, cx - 1.7f * u, cy + 4 * u, 3.4f * u, 3.4f * u); break;
                    case 3: g.DrawLine(p, cx - 5 * u, cy - 5 * u, cx + 5 * u, cy + 5 * u); g.DrawLine(p, cx + 5 * u, cy - 5 * u, cx - 5 * u, cy + 5 * u); break;
                    case 0: g.DrawLine(p, cx, cy - 1 * u, cx, cy + 6 * u); g.FillEllipse(b, cx - 1.7f * u, cy - 7.5f * u, 3.4f * u, 3.4f * u); break;
                    case 5: g.DrawLine(p, cx - 5 * u, cy, cx + 5 * u, cy); break;
                    default: for (int i = -1; i <= 1; i++) g.FillEllipse(b, cx + i * 6 * u - 1.7f * u, cy - 1.7f * u, 3.4f * u, 3.4f * u); break;
                }
            }
        }

        void DrawSwitch(Graphics g, Rectangle r, Color back)
        {
            bool dis = State == 4;
            Color track = On ? Theme.Accent : Theme.Mix(back, Theme.Fore, 0.08f);
            if (actHot) track = On ? Theme.Mix(Theme.Accent, Color.White, 0.15f) : Theme.Mix(back, Theme.Fore, 0.16f);
            if (dis) track = Theme.Mix(track, back, 0.6f);
            Theme.FillRound(g, r, r.Height / 2f, track, On ? Color.Empty : Theme.Mix(back, Theme.Fore, 0.35f));
            int k = r.Height - Theme.S(10);
            int kx = On ? r.Right - Theme.S(5) - k : r.X + Theme.S(5);
            using (SolidBrush b = new SolidBrush(On ? Theme.Bg : Theme.Mix(Theme.Dim, Theme.Fore, 0.4f)))
                g.FillEllipse(b, kx, r.Y + Theme.S(5), k, k);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            Color back = Primary ? Theme.Mix(Theme.Surface, Theme.Accent, 0.09f) : Theme.Surface;
            Color line = Primary ? Theme.Mix(Theme.Border, Theme.Accent, 0.5f) : Theme.Border;
            Theme.FillRound(g, new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.S(10), back, line);

            int pad = Theme.S(16);
            Color sc = StateColor(State);
            int d = Theme.S(Primary ? 34 : 28);
            Rectangle ic = new Rectangle(pad, (Height - d) / 2, d, d);
            using (SolidBrush b = new SolidBrush(Theme.Mix(back, sc, 0.22f))) g.FillEllipse(b, ic);
            Mark(g, ic, State, sc);

            Font af = ActionFont ?? Font;
            int right = Width - pad;
            act = Rectangle.Empty;
            if (Switch && State != 5)
            {
                int sw = Theme.S(48), sh = Theme.S(26);
                act = new Rectangle(right - sw, (Height - sh) / 2, sw, sh);
                DrawSwitch(g, act, back);
                right = act.X - Theme.S(14);
            }
            else if (Action.Length > 0)
            {
                Size ts = TextRenderer.MeasureText(g, Action, af, new Size(1000, 100), TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
                int bw = ts.Width + Theme.S(30), bh = Theme.S(34);
                act = new Rectangle(right - bw, (Height - bh) / 2, bw, bh);
                bool dis = State == 4;
                Color f, l;
                if (Primary) { f = actHot ? Theme.Mix(Theme.Accent, Color.White, 0.15f) : Theme.Accent; l = Color.Empty; }
                else { f = Theme.Mix(back, Theme.Fore, actHot ? 0.13f : 0.06f); l = Theme.Mix(back, Theme.Accent, actHot ? 0.9f : 0.45f); }
                if (dis) { f = Theme.Mix(f, back, 0.6f); l = Theme.Mix(back, Theme.Fore, 0.15f); }
                Theme.FillRound(g, act, Theme.S(8), f, l);
                Color tc = Primary ? Theme.Bg : Theme.Fore;
                if (dis) tc = Theme.Dim;
                Draw(g, Action, af, act, tc, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
                right = act.X - Theme.S(14);
            }

            int tx = ic.Right + Theme.S(14);
            if (Value.Length > 0 && ValueFont != null)
            {
                int maxw = Math.Max(Theme.S(60), (int)((right - tx) * 0.4));
                Size vs = TextRenderer.MeasureText(g, Value, ValueFont, new Size(2000, 100), TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
                int vw = Math.Min(maxw, vs.Width + Theme.S(2));
                Rectangle vr = new Rectangle(right - vw, 0, vw, Height);
                Color vc = (State == 2 || State == 3) ? sc : Theme.Mix(Theme.Dim, Theme.Fore, 0.5f);
                Draw(g, Value, ValueFont, vr, vc, TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
                right = vr.X - Theme.S(14);
            }

            int tw = Math.Max(10, right - tx);
            int th = TitleFont != null ? TitleFont.Height : Theme.S(18);
            int dh = 0;
            if (Desc.Length > 0 && DescFont != null)
            {
                Size ds = TextRenderer.MeasureText(g, Desc, DescFont, new Size(tw, 1000), TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.TextBoxControl);
                dh = Math.Min(ds.Height, Math.Max(DescFont.Height, Height - th - Theme.S(18)));
            }
            int total = th + (dh > 0 ? Theme.S(3) + dh : 0);
            int ty = (Height - total) / 2;
            Draw(g, Title, TitleFont, new Rectangle(tx, ty, tw, th), Theme.Fore, TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            if (dh > 0)
                Draw(g, Desc, DescFont, new Rectangle(tx, ty + th + Theme.S(3), tw, dh), Theme.Dim,
                     TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.TextBoxControl);
        }
    }
    // Плитка монитора: заголовок, крупное значение, подпись, полоска.
    public class Tile : Smooth
    {
        public string Title = "", Value = "-", Sub = "";
        public float Percent = -1;
        public Color Bar = Theme.Accent;
        public bool Clickable;
        public Font TitleFont, ValueFont, SubFont;
        public void Set(string value, string sub, float percent, Color bar)
        {
            if (value == Value && sub == Sub && percent == Percent && bar == Bar) return;
            Value = value; Sub = sub; Percent = percent; Bar = bar; Invalidate();
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            Color line = (Clickable && Hot) ? Theme.Accent : Theme.Border;
            Theme.FillRound(g, new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.S(10), Theme.Surface, line);
            int pad = Theme.S(14), w = Width - pad * 2, y = Theme.S(11);
            using (SolidBrush b = new SolidBrush(Bar)) g.FillEllipse(b, pad, y + Theme.S(5), Theme.S(7), Theme.S(7));
            int th = TitleFont != null ? TitleFont.Height : Theme.S(16);
            Draw(g, Title, TitleFont, new Rectangle(pad + Theme.S(13), y, w - Theme.S(13), th), Theme.Dim, TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            y += th + Theme.S(2);
            int vh = ValueFont != null ? ValueFont.Height : Theme.S(30);
            Draw(g, Value, ValueFont, new Rectangle(pad, y, w, vh), Theme.Fore, TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            y += vh;
            int sh = SubFont != null ? SubFont.Height : Theme.S(16);
            Draw(g, Sub, SubFont, new Rectangle(pad, y, w, sh), Theme.Dim, TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            if (Percent >= 0)
            {
                float bh = Theme.S(4), by = Height - pad + Theme.S(2) - bh;
                Theme.FillRound(g, new RectangleF(pad, by, w, bh), bh / 2, Theme.Surface2, Color.Empty);
                float fw = Math.Max(bh, w * Math.Min(100f, Percent) / 100f);
                Theme.FillRound(g, new RectangleF(pad, by, fw, bh), bh / 2, Bar, Color.Empty);
            }
        }
    }

    // Пункт навигации слева.
    public class NavItem : Smooth
    {
        public string Glyph = "";
        public bool Selected, Dot;
        public Font GlyphFont;
        public NavItem() { Cursor = Cursors.Hand; }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            if (Selected || Hot)
            {
                Color f = Selected ? Theme.Mix(Theme.Surface2, Theme.Accent, 0.14f) : Theme.Surface2;
                Theme.FillRound(g, new RectangleF(0, 0, Width - 1, Height - 1), Theme.S(8), f, Color.Empty);
            }
            if (Selected)
                Theme.FillRound(g, new RectangleF(Theme.S(3), Height * 0.28f, Theme.S(3), Height * 0.44f), Theme.S(2), Theme.Accent, Color.Empty);
            Rectangle gr = new Rectangle(Theme.S(12), 0, Theme.S(26), Height);
            Draw(g, Glyph, GlyphFont, gr, Selected ? Theme.Accent : Theme.Dim,
                 TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            if (Dot)
            {
                int dd = Theme.S(8);
                using (SolidBrush b = new SolidBrush(Theme.Accent)) g.FillEllipse(b, Width - Theme.S(18), (Height - dd) / 2f, dd, dd);
            }
            Rectangle tr = new Rectangle(Theme.S(46), 0, Width - Theme.S(52), Height);
            Draw(g, base.Text, Font, tr, Selected ? Theme.Fore : Theme.Mix(Theme.Dim, Theme.Fore, 0.35f),
                 TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    // Значок-«таблетка» с цветной точкой (питание, режим).
    public class Badge : Smooth
    {
        public Color Tone = Theme.Accent;
        public void Set(string text, Color tone)
        {
            if (text == base.Text && tone == Tone) return;
            Tone = tone; base.Text = text; Invalidate();
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            Color pb = Parent != null ? Parent.BackColor : Theme.Bg;
            Theme.FillRound(g, new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), (Height - 1) / 2f,
                            Theme.Mix(pb, Tone, 0.14f), Theme.Mix(pb, Tone, 0.45f));
            int d = Theme.S(8), x = Theme.S(12);
            using (SolidBrush b = new SolidBrush(Tone)) g.FillEllipse(b, x, (Height - d) / 2f, d, d);
            Draw(g, base.Text, Font, new Rectangle(x + d + Theme.S(8), 0, Width - x - d - Theme.S(16), Height), Theme.Mix(Tone, Theme.Fore, 0.45f),
                 TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    // Небольшая кнопка; умеет быть кнопкой «ОК/Отмена» в диалогах.
    public class Chip : Smooth, IButtonControl
    {
        public bool Primary;
        private DialogResult result = DialogResult.None;
        public DialogResult DialogResult { get { return result; } set { result = value; } }
        public void NotifyDefault(bool value) { }
        public void PerformClick() { OnClick(EventArgs.Empty); }
        public Chip() { Cursor = Cursors.Hand; }
        protected override void OnClick(EventArgs e)
        {
            base.OnClick(e);
            Form f = FindForm();
            if (f != null && result != DialogResult.None) f.DialogResult = result;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            Color pb = Parent != null ? Parent.BackColor : Theme.Bg;
            Color fill = Primary ? Theme.Accent : Theme.Mix(pb, Theme.Fore, 0.06f);
            if (Hot) fill = Primary ? Theme.Mix(Theme.Accent, Color.White, 0.15f) : Theme.Mix(pb, Theme.Fore, 0.12f);
            if (Pressed) fill = Primary ? Theme.Mix(Theme.Accent, Color.Black, 0.15f) : Theme.Mix(pb, Theme.Accent, 0.25f);
            Theme.FillRound(g, new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.S(7), fill,
                            Primary ? Color.Empty : Theme.Mix(pb, Theme.Fore, 0.14f));
            Draw(g, base.Text, Font, ClientRectangle, Primary ? Theme.Bg : Theme.Fore,
                 TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }

    // Панель со скруглёнными углами (подложка журнала).
    public class RoundPanel : Panel
    {
        public Color Fill = Theme.Surface, Line = Theme.Border;
        public RoundPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(Parent != null ? Parent.BackColor : Theme.Bg);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Theme.FillRound(g, new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.S(10), Fill, Line);
        }
    }
}
'@
$uiRefs = @('System.Windows.Forms', 'System.Drawing')
if ($PSVersionTable.PSEdition -eq 'Core') {
    # PowerShell 7 (не основной сценарий): ссылки на уже загруженные сборки WinForms.
    $uiRefs = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
        -not $_.IsDynamic -and $_.Location -and $_.GetName().Name -match '^(System\.(Windows\.Forms|Drawing|ComponentModel|Runtime|Collections|Private\.Windows)|Microsoft\.Win32\.Primitives|netstandard)' } |
        ForEach-Object Location)
}
Add-Type -TypeDefinition $UiSource -ReferencedAssemblies $uiRefs -IgnoreWarnings

# ---------------- окно ----------------
$g0 = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = [math]::Max(1.0, $g0.DpiX / 96.0)
$g0.Dispose()
[LTK.UI.Theme]::Scale = $script:Scale
function Px([double]$n) { [int][math]::Round($n * $script:Scale) }
function Sz([double]$w, [double]$h) { New-Object Drawing.Size((Px $w), (Px $h)) }
function Pad([double]$l, [double]$t, [double]$r, [double]$b) { New-Object Windows.Forms.Padding((Px $l), (Px $t), (Px $r), (Px $b)) }

$bg      = [LTK.UI.Theme]::Bg
$panel   = [LTK.UI.Theme]::Surface
$panel2  = [LTK.UI.Theme]::Surface2
$accent  = [LTK.UI.Theme]::Accent
$fg      = [LTK.UI.Theme]::Fore
$cDim    = [LTK.UI.Theme]::Dim
$cOk     = [Drawing.Color]::FromArgb(92, 210, 130)
$cWarn   = [Drawing.Color]::FromArgb(245, 180, 65)
$cErr    = [Drawing.Color]::FromArgb(245, 100, 100)

$fontNames = @((New-Object Drawing.Text.InstalledFontCollection).Families | ForEach-Object Name)
$semi = if ($fontNames -contains 'Segoe UI Semibold') { 'Segoe UI Semibold' } else { 'Segoe UI' }
$HasIcons = $fontNames -contains 'Segoe MDL2 Assets'
function New-Font([string]$name, [double]$size, [Drawing.FontStyle]$style = 'Regular') { New-Object Drawing.Font($name, [single]$size, $style) }
$fUi      = New-Font 'Segoe UI' 9.5
$fSmall   = New-Font 'Segoe UI' 8.5
$fSemi    = New-Font $semi 10
$fTitle   = New-Font $semi 15
$fPage    = New-Font $semi 17
$fValue   = New-Font $semi 17
$fTileCap = New-Font $semi 8
$fMono    = New-Font 'Consolas' 10
$fTitleRow = New-Font $semi 12
$fSemiSm  = New-Font $semi 9
$fIcon    = if ($HasIcons) { New-Font 'Segoe MDL2 Assets' 14 } else { New-Font 'Segoe UI' 13 }
$fIconNav = if ($HasIcons) { New-Font 'Segoe MDL2 Assets' 12 } else { New-Font 'Segoe UI' 11 }

# Значки разделов: Segoe MDL2 Assets (есть в Windows 10/11), запасной вариант - обычные символы.
$Icons = @{
    home = 0xE80F, '⌂'; diag = 0xE9D9, '✚'; gpu = 0xE7FC, '▣'; battery = 0xE83F, '▮'; windows = 0xE713, '⚙'
    security = 0xEA18, '◈'; tests = 0xEC4A, '◷'; oc = 0xE945, '⚡'; install = 0xE7F8, '▭'; report = 0xE8A5, '☰'
}
function Ico([string]$key) {
    $i = $Icons[$key]
    if ($HasIcons) { [string][char]$i[0] } else { $i[1] }
}

$form = New-Object Windows.Forms.Form
$form.Text = "Laptop Toolkit v$Version - Skytech Noir"
$form.AutoScaleMode = 'None'
$form.Size = Sz 1280 860
$form.MinimumSize = Sz 1000 680
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$form.ForeColor = $fg
$form.Font = $fUi
$form.Add_HandleCreated({ [LTK.UI.Theme]::DarkTitle($form.Handle, $panel) })

$tips = New-Object Windows.Forms.ToolTip
$tips.AutoPopDelay = 20000; $tips.InitialDelay = 500

# --- шапка ---
$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = Px 68; $header.BackColor = $panel
$logo = New-Object Windows.Forms.Label
$logo.Text = Ico 'oc'; $logo.Font = $(if ($HasIcons) { New-Font 'Segoe MDL2 Assets' 20 } else { New-Font 'Segoe UI' 20 })
$logo.ForeColor = $accent; $logo.TextAlign = 'MiddleCenter'
$logo.Location = New-Object Drawing.Point((Px 18), (Px 14)); $logo.Size = Sz 40 40
$appTitle = New-Object Windows.Forms.Label
$appTitle.Text = 'Laptop Toolkit'; $appTitle.Font = $fTitle; $appTitle.ForeColor = $fg; $appTitle.AutoSize = $true
$appTitle.Location = New-Object Drawing.Point((Px 64), (Px 10))
$appSub = New-Object Windows.Forms.Label
$appSub.Text = "Skytech Noir  ·  Ryzen 7 8845HS  ·  RTX 4070 Laptop 140 Вт  ·  v$Version"
$appSub.Font = $fSmall; $appSub.ForeColor = $cDim; $appSub.AutoSize = $true
$appSub.Location = New-Object Drawing.Point((Px 66), (Px 40))
$badges = New-Object Windows.Forms.FlowLayoutPanel
$badges.Dock = 'Right'; $badges.Width = Px 560; $badges.FlowDirection = 'RightToLeft'; $badges.WrapContents = $false
$badges.Padding = Pad 0 19 14 0; $badges.BackColor = $panel
$badgePower = New-Object LTK.UI.Badge
$badgePower.Size = Sz 150 30; $badgePower.Font = $fSmall; $badgePower.Margin = Pad 8 0 0 0
$badgeMode = New-Object LTK.UI.Badge
$badgeMode.Size = Sz 300 30; $badgeMode.Font = $fSmall; $badgeMode.Margin = Pad 8 0 0 0
$badges.Controls.AddRange(@($badgePower, $badgeMode))
$header.Controls.AddRange(@($logo, $appTitle, $appSub, $badges))

# --- навигация ---
$nav = New-Object Windows.Forms.Panel
$nav.Dock = 'Left'; $nav.Width = Px 236; $nav.BackColor = $panel
$navFlow = New-Object Windows.Forms.FlowLayoutPanel
$navFlow.Dock = 'Fill'; $navFlow.FlowDirection = 'TopDown'; $navFlow.WrapContents = $false; $navFlow.AutoScroll = $true
$navFlow.Padding = Pad 12 10 8 10; $navFlow.BackColor = $panel
$navHint = New-Object Windows.Forms.Label
$navHint.Dock = 'Bottom'; $navHint.Height = Px 62; $navHint.Padding = Pad 18 0 12 12
$navHint.ForeColor = $cDim; $navHint.Font = $fSmall; $navHint.TextAlign = 'BottomLeft'
$navHint.Text = "Все изменения запоминаются`nи откатываются одной кнопкой."
$nav.Controls.Add($navFlow); $nav.Controls.Add($navHint)

# --- строка состояния ---
$bottom = New-Object Windows.Forms.Panel
$bottom.Dock = 'Bottom'; $bottom.Height = Px 28; $bottom.BackColor = $panel
$statusLbl = New-Object Windows.Forms.Label
$statusLbl.Dock = 'Left'; $statusLbl.Width = Px 460; $statusLbl.TextAlign = 'MiddleLeft'; $statusLbl.Font = $fSmall
$statusLbl.Padding = Pad 14 0 0 0; $statusLbl.ForeColor = $cDim; $statusLbl.Text = 'Готово.'; $statusLbl.AutoEllipsis = $true
$stateLbl = New-Object Windows.Forms.Label
$stateLbl.Dock = 'Fill'; $stateLbl.TextAlign = 'MiddleRight'; $stateLbl.Font = $fSmall
$stateLbl.Padding = Pad 0 0 14 0; $stateLbl.ForeColor = $cDim; $stateLbl.AutoEllipsis = $true
$bottom.Controls.Add($stateLbl)
$bottom.Controls.Add($statusLbl)

# --- основная область ---
$main = New-Object Windows.Forms.Panel
$main.Dock = 'Fill'; $main.BackColor = $bg; $main.Padding = Pad 22 16 8 0

$tiles = New-Object Windows.Forms.TableLayoutPanel
$tiles.Dock = 'Top'; $tiles.Height = Px 104; $tiles.ColumnCount = 4; $tiles.RowCount = 1; $tiles.BackColor = $bg
$tiles.Margin = Pad 0 0 0 0; $tiles.Padding = Pad 0 0 14 0
for ($i = 0; $i -lt 4; $i++) { [void]$tiles.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 25))) }
[void]$tiles.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
function New-Tile([string]$title, [int]$col) {
    $t = New-Object LTK.UI.Tile
    $t.Title = $title; $t.Dock = 'Fill'
    $t.Margin = New-Object Windows.Forms.Padding($(if ($col -eq 0) { 0 } else { Px 6 }), 0, $(if ($col -eq 3) { 0 } else { Px 6 }), 0)
    $t.TitleFont = $fTileCap; $t.ValueFont = $fValue; $t.SubFont = $fSmall
    $tiles.Controls.Add($t, $col, 0)
    $t
}
$tileCpu = New-Tile 'ПРОЦЕССОР' 0
$tileRam = New-Tile 'ПАМЯТЬ' 1
$tileBat = New-Tile 'БАТАРЕЯ' 2
$tileGpu = New-Tile 'ВИДЕОКАРТА' 3
$tileGpu.Clickable = $true; $tileGpu.Cursor = [Windows.Forms.Cursors]::Hand
$tips.SetToolTip($tileGpu, 'Нажмите, чтобы включить/выключить слежение за RTX 4070. Опрос будит видеокарту - на батарее выключается сам.')

$gap1 = New-Object Windows.Forms.Panel
$gap1.Dock = 'Top'; $gap1.Height = Px 4; $gap1.BackColor = $bg

$pageHost = New-Object Windows.Forms.Panel
$pageHost.Dock = 'Fill'; $pageHost.BackColor = $bg

$main.Controls.Add($pageHost)
$main.Controls.Add($gap1)
$main.Controls.Add($tiles)

$form.Controls.Add($main)
$form.Controls.Add($nav)
$form.Controls.Add($bottom)
$form.Controls.Add($header)

function New-Chip([string]$text, [double]$w, [switch]$Primary) {
    $c = New-Object LTK.UI.Chip
    $c.Text = $text; $c.Size = Sz $w 30; $c.Font = $fSmall; $c.Primary = [bool]$Primary; $c.Margin = Pad 6 0 0 0
    $c
}

# Журнал - отдельная страница: подробный текст всех действий.
$logPage = New-Object Windows.Forms.Panel
$logPage.Dock = 'Fill'; $logPage.BackColor = $bg; $logPage.Visible = $false; $logPage.Padding = Pad 0 0 14 14
$logTop = New-Object Windows.Forms.Panel
$logTop.Dock = 'Top'; $logTop.Height = Px 84; $logTop.BackColor = $bg
$logTitle = New-Object Windows.Forms.Label
$logTitle.Text = 'Журнал'; $logTitle.Font = $fPage; $logTitle.ForeColor = $fg; $logTitle.AutoSize = $true
$logTitle.Location = New-Object Drawing.Point(0, (Px 12))
$logDesc = New-Object Windows.Forms.Label
$logDesc.Text = 'Подробности всех действий и проверок. Отсюда же сохраняется отчёт.'
$logDesc.Font = $fUi; $logDesc.ForeColor = $cDim; $logDesc.AutoSize = $true
$logDesc.Location = New-Object Drawing.Point((Px 2), (Px 46))
$logTools = New-Object Windows.Forms.FlowLayoutPanel
$logTools.Dock = 'Right'; $logTools.Width = Px 420; $logTools.FlowDirection = 'RightToLeft'; $logTools.WrapContents = $false
$logTools.BackColor = $bg; $logTools.Padding = Pad 0 40 0 0
$chipClear = New-Chip 'Очистить' 96
$chipFolder = New-Chip 'Папка отчётов' 124
$chipSave = New-Chip 'Сохранить отчёт' 140 -Primary
$logTools.Controls.AddRange(@($chipClear, $chipFolder, $chipSave))
$logTop.Controls.AddRange(@($logTitle, $logDesc, $logTools))
$logCard = New-Object LTK.UI.RoundPanel
$logCard.Dock = 'Fill'; $logCard.Padding = Pad 16 12 6 10
$box = New-Object Windows.Forms.RichTextBox
$box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.DetectUrls = $false
$box.Dock = 'Fill'; $box.BackColor = $panel; $box.ForeColor = $fg
$box.Font = $fMono
$box.BorderStyle = 'None'
$logCard.Controls.Add($box)
$logPage.Controls.Add($logCard)
$logPage.Controls.Add($logTop)
$pageHost.Controls.Add($logPage)

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
    if ($script:PageKey -ne 'log' -and $script:LogNav -and -not $script:LogNav.Dot) {
        $script:LogNav.Dot = $true; $script:LogNav.Invalidate()
    }
    [Windows.Forms.Application]::DoEvents()
}
function Head([string]$t) { Out-Box @('', "■ $t") $accent }
function Out-Ok([object[]]$Lines)   { Out-Box $Lines $cOk }
function Out-Warn([object[]]$Lines) { Out-Box $Lines $cWarn }
function Out-Dim([object[]]$Lines)  { Out-Box $Lines $cDim }

function Ask-User([string]$msg, [string]$title = 'Подтверждение') {
    $r = [Windows.Forms.MessageBox]::Show($form, $msg, $title, 'YesNo', 'Question')
    return ($r -eq [Windows.Forms.DialogResult]::Yes)
}
function Show-Info([string]$msg, [string]$title = 'Laptop Toolkit') {
    [void][Windows.Forms.MessageBox]::Show($form, $msg, $title, 'OK', 'Information')
}
function Set-Status([string]$text, $color = $null) {
    $statusLbl.ForeColor = $(if ($color) { $color } else { $cDim })
    $statusLbl.Text = $text
}

function Invoke-Safe([string]$name, [scriptblock]$action) {
    if ($script:Busy) { Set-Status "Подождите: ещё выполняется «$($script:BusyName)»" $cWarn; return }
    $script:Busy = $true; $script:BusyName = $name
    Set-Status "● Выполняется: $name..." $accent
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $failed = $false
    try { & $action }
    catch { $failed = $true; Out-Box "ОШИБКА [$name]: $($_.Exception.Message)" }
    finally {
        $script:Busy = $false; $script:Cat = $null
        $form.Cursor = [Windows.Forms.Cursors]::Default
        if ($failed) { Set-Status "Ошибка: $name - подробности в «Журнале»" $cErr }
        elseif ($statusLbl.Text -like '● Выполняется*') { Set-Status "Готово: $name" }
    }
}

# Долгие команды идут в отдельном окне (права администратора наследуются).
function Start-Console([string]$title, [string]$command) {
    $cmd = "`$host.UI.RawUI.WindowTitle = '$title'; $command; Write-Host ''; Write-Host 'ГОТОВО. Окно можно закрыть.' -ForegroundColor Green"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand $enc"
    Out-Box "Открыто отдельное окно: $title"
    Set-Status "Открыто отдельное окно: $title"
}

function Test-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Out-Box 'winget не найден. Установите «Установщик приложений» (App Installer) из Microsoft Store.'
    Show-Info 'Для скачивания программ нужен «Установщик приложений» (winget) из Microsoft Store. Сейчас откроется его страница.'
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
    $entries = @($script:Journal | Where-Object { $_.Cat -like $cat })
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
function Test-AgentTask {
    Cached 'agenttask' 5 { try { [bool](Get-ScheduledTask -TaskName 'PowerAgent' -TaskPath '\LaptopToolkit\' -ErrorAction Stop) } catch { $false } }
}

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
    $script:Cache.Remove('agenttask')
    $script:AgentOn = $true
    Out-Ok '  + Автопереключение при подключении/отключении зарядки включено (Планировщик: \LaptopToolkit\PowerAgent)'
}

function Uninstall-Agent {
    Unregister-ScheduledTask -TaskName 'PowerAgent' -TaskPath '\LaptopToolkit\' -Confirm:$false -ErrorAction SilentlyContinue
    $script:Cache.Remove('agenttask')
    $script:AgentOn = $false
    foreach ($f in 'PowerAgent.ps1', 'agent.json', 'LTK.cs') { Remove-Item (Join-Path $DataDir $f) -Force -ErrorAction SilentlyContinue }
    $rates = @([LTK.Disp]::Rates())
    if ($rates.Count) { [void][LTK.Disp]::Set($rates[-1]) }
    Out-Ok '  + Автопереключение выключено, частота экрана возвращена на максимум.'
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
    if (-not $Smi) { Out-Box '[!] nvidia-smi не найден - установите драйвер NVIDIA (страница «Оптимизация Windows» -> «Драйверы NVIDIA и AMD»).'; return }
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
    Out-Box 'Код 28 = нет драйвера, 22 = отключено, 10/43 = сбой. Решение - страница «Оптимизация Windows» -> «Драйверы NVIDIA и AMD».'
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
    $vc = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $nv = $vc | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if (-not $nv) { return 'none' }
    if (-not $nv.CurrentHorizontalResolution) { return 'hybrid' }
    # Встроенный экран на Radeon, а RTX тоже выводит картинку - значит, к ней подключён внешний монитор.
    $igpu = $vc | Where-Object { $_.Name -match 'AMD|Radeon' } | Select-Object -First 1
    if ($igpu -and $igpu.CurrentHorizontalResolution) { return 'external' }
    return 'dgpu'
}
function Get-GraphicsModeText {
    switch (Get-GraphicsMode) {
        'dgpu'     { 'ТОЛЬКО ДИСКРЕТНАЯ: экран выводит RTX 4070 - максимум FPS, но она не засыпает и на батарее расход в разы выше' }
        'external' { 'гибридный, но внешний монитор подключён к RTX 4070 - пока он подключён, видеокарта не засыпает' }
        'hybrid'   { 'гибридный (Optimus): экран на Radeon 780M, RTX 4070 включается только для игр - лучший вариант для батареи' }
        default    { 'NVIDIA не видна (драйвер не установлен или видеокарта отключена)' }
    }
}

function Open-NvidiaPanel {
    try { Start-Process 'shell:AppsFolder\NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIACorp.NVIDIAControlPanel' -ErrorAction Stop; return }
    catch { }
    $exe = "$env:ProgramFiles\NVIDIA Corporation\Control Panel Client\nvcplui.exe"
    if (Test-Path $exe) { Start-Process $exe } else { Out-Box '[!] Панель управления NVIDIA не найдена - установите её из Microsoft Store.' }
}

function Show-HybridHelp {
    Out-Box '', 'КАК ВКЛЮЧИТЬ ГИБРИДНЫЙ РЕЖИМ (для батареи):',
        '  1. Панель управления NVIDIA -> Дисплей -> «Управление режимом дисплея» (если такой пункт есть)',
        '     -> «Оптимус NVIDIA» / «Автоматический выбор» -> перезагрузка.',
        '  2. Если пункта нет - переключатель графики в Control Center (утилита ноутбука, версия 5.x)',
        '     или в BIOS (обычно Advanced -> Display / Graphics Mode -> Hybrid, MSHybrid или Optimus).',
        '  3. Внешний монитор через HDMI обычно подключён прямо к RTX 4070 - на батарее отключайте его.',
        '  Для игр от сети можно снова включить «Только дискретная» - это +5..15% FPS.'
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

# Драйвер Dynamic Boost (nvpcf.inf) часто уже лежит в хранилище драйверов Windows или в распакованном
# пакете NVIDIA (C:\NVIDIA), но не привязан к устройству. Пробуем установить его оттуда.
function Repair-Nvpcf {
    $infs = @(Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" -Directory -Filter 'nvpcf.inf_*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object { Join-Path $_.FullName 'nvpcf.inf' } | Where-Object { Test-Path $_ })
    if (Test-Path 'C:\NVIDIA') {
        $infs += @(Get-ChildItem 'C:\NVIDIA' -Recurse -Filter 'nvpcf.inf' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object FullName)
    }
    if (-not $infs.Count) {
        Out-Dim '  - Драйвера Dynamic Boost (nvpcf.inf) на диске нет - установить автоматически не из чего.'
        return $false
    }
    foreach ($inf in $infs) {
        Out-Dim "  - Устанавливаю драйвер Dynamic Boost: $inf"
        & pnputil.exe /add-driver "$inf" /install 2>&1 | Out-Null
        & pnputil.exe /scan-devices 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        if ("$((@(Get-Nvpcf))[0].Status)" -eq 'OK') { return $true }
    }
    Out-Dim '  - Драйвер с диска не подошёл к устройству.'
    return $false
}

function Show-DbHelp {
    Out-Box '      КАК ПОЧИНИТЬ (по порядку, после каждого шага - перезагрузка и «Проверить мощность»):',
            '      1. Параметры -> Центр обновления Windows -> Дополнительные параметры -> Необязательные обновления',
            '         -> Обновления драйверов: установите всё от NVIDIA.',
            '      2. Драйвер с nvidia.com (GeForce RTX 4070 Laptop) -> при установке «Выборочная» -> «Чистая установка».',
            '         Устанавливайте именно полный пакет с сайта: Dynamic Boost ставится вместе с ним.',
            '      3. Обновить BIOS и драйверы с сайта поддержки Skytech (там бывает отдельный пакет Dynamic Boost / NVPCF).'
}

function Show-GpuPower([switch]$Fix) {
    Head 'МОЩНОСТЬ ВИДЕОКАРТЫ (цель: 140 Вт = 115 Вт база + 25 Вт Dynamic Boost)'
    if (-not $Smi) { Out-Box '!!! Драйвер NVIDIA не найден (нет nvidia-smi). Страница «Оптимизация Windows» -> «Драйверы NVIDIA и AMD».'; return }
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
    # @() обязателен: один найденный объект PowerShell 5.1 не считает массивом, и .Count у него пустой.
    $pcf = @(Get-Nvpcf)
    $script:DbState = 'missing'
    if ($pcf.Count) {
        $d = $pcf[0]
        $code = Get-CmCode $d
        if ("$($d.Status)" -eq 'OK') { $script:DbState = 'ok' }
        elseif ($code -eq 22) { $script:DbState = 'disabled' }
        elseif ($code -eq 28) { $script:DbState = 'nodriver' }
        else { $script:DbState = "error $code" }

        if ($script:DbState -eq 'disabled' -and $Fix) {
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if ("$((@(Get-Nvpcf))[0].Status)" -eq 'OK') { $script:DbState = 'ok'; Out-Ok '  + Dynamic Boost был ОТКЛЮЧЁН в Диспетчере устройств - включил.' }
        }
        if ($script:DbState -ne 'ok' -and $script:DbState -ne 'disabled' -and $Fix) {
            if (Repair-Nvpcf) { $script:DbState = 'ok'; Out-Ok '  + Драйвер Dynamic Boost установлен.' }
        }
    }
    switch -Wildcard ($script:DbState) {
        'ok'       { Out-Ok "  + Dynamic Boost: работает (+25 Вт в играх)" }
        'disabled' { Out-Box '  [!] Dynamic Boost отключён в Диспетчере устройств - кнопка «Включить» на странице «Видеокарта» включит его.' }
        'missing'  { Out-Box '  [!] Dynamic Boost: устройство «NVIDIA Platform Controllers and Framework» не найдено - видеокарта ограничена ~115 Вт.'; Show-DbHelp }
        default {
            $why = if ($script:DbState -eq 'nodriver') { 'у устройства нет драйвера' } else { "ошибка устройства ($($script:DbState))" }
            Out-Box "  [!] Dynamic Boost НЕ РАБОТАЕТ: $why. Пока это так, видеокарта не поднимется выше 115 Вт."
            if (-not $Fix) { Out-Box '      Кнопка «Исправить» на странице «Видеокарта» попробует установить драйвер сама.' }
            Show-DbHelp
        }
    }

    # Службу NVIDIA часто отключают «оптимизаторы» - без неё ломаются Панель NVIDIA и управление питанием.
    $svc = Get-Service 'NVDisplay.ContainerLocalSystem' -ErrorAction SilentlyContinue
    if ($svc) {
        if ("$($svc.StartType)" -ne 'Automatic' -or "$($svc.Status)" -ne 'Running') {
            if ($Fix) {
                Set-Service $svc.Name -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service $svc.Name -ErrorAction SilentlyContinue
                Out-Ok '  + Служба NVIDIA Display Container была выключена - включил и запустил.'
            } else { Out-Box "  [!] Служба NVIDIA Display Container: $($svc.Status) / $($svc.StartType) - должна работать (страница «Видеокарта» -> «Служба NVIDIA»)." }
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
    if ($max -ge 139 -and $script:DbState -ne 'ok') {
        Out-Box "!!! ИТОГ: прошивка разрешает $max Вт, но Dynamic Boost не работает - сейчас максимум $(if ($def) { $def } else { 115 }) Вт."
        Out-Box '  Почините драйвер Dynamic Boost (шаги выше), перезагрузитесь и нажмите «Проверить мощность» ещё раз.'
    } elseif ($max -ge 139) {
        Out-Ok "ИТОГ: потолок видеокарты $max Вт - 140 Вт ДОСТУПНЫ."
        Out-Box '  Dynamic Boost добавляет до +25 Вт автоматически в тяжёлых играх, когда процессор не загружен на полную.',
                '  Поэтому постоянные 140 Вт будут не всегда - это нормальная работа, а не ограничение.'
    } elseif ($max -ge 100) {
        Out-Warn "ИТОГ: драйвер сообщает потолок $max Вт (база). Dynamic Boost добавляет сверху до +25 Вт динамически."
        Out-Box '  Проверьте реальный максимум: кнопка «Замер пиковой мощности GPU» + игра или FurMark 2 на 3-5 минут.',
                '  Если пик держится около базы - в Control Center (утилита ноутбука) не включён режим Turbo (Performance).'
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
    if (-not $Smi) { Head 'ВИДЕОКАРТА 140 ВТ'; Out-Box '!!! Драйвер NVIDIA не найден (нет nvidia-smi). Страница «Оптимизация Windows» -> «Драйверы NVIDIA и AMD».'; return }
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
    if ($script:DbState -ne 'ok' -and (Ask-User ("Dynamic Boost не заработал автоматически - без него видеокарта ограничена 115 Вт.`n`n" +
            "Открыть «Необязательные обновления» Windows и страницу драйверов NVIDIA?`n" +
            "Порядок действий - в журнале программы («КАК ПОЧИНИТЬ»).") 'Dynamic Boost')) {
        Start-Process 'ms-settings:windowsupdate-optionalupdates'
        Start-Process 'https://www.nvidia.com/drivers/'
    }
    Out-Box '', 'ЧТОБЫ ВИДЕТЬ 140 ВТ В ИГРАХ:',
        '  1. Только от сети, родной блок питания.',
        '  2. Control Center (утилита ноутбука) - режим Turbo (Performance). Без него EC держит меньше.',
        '  3. Охлаждение: подставка, чистые решётки. При 87 °C+ видеокарта сама снижает мощность.',
        '  4. Панель NVIDIA -> Управление режимом дисплея -> «Только дискретная графика» даёт ещё +5..15% FPS',
        '     (но на батарее верните «Автоматический выбор» - иначе заряд уходит в разы быстрее).',
        '  5. В Chris Titus WinUtil и подобных не отключайте службы NVIDIA - пропадёт Dynamic Boost.',
        '  Проверка: кнопка «Замер пиковой мощности GPU».'
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
    $mode = Get-GraphicsMode
    if ($mode -eq 'dgpu' -or $mode -eq 'external') {
        Out-Box '', "[!] Главная причина: $(Get-GraphicsModeText)."
        Out-Box '    Пока это так, назначать программам встроенную графику бесполезно.'
        Show-HybridHelp
        if ($mode -eq 'dgpu' -and (Ask-User 'Открыть Панель управления NVIDIA, чтобы переключить режим дисплея?' 'Режим графики')) { Open-NvidiaPanel }
        return
    }
    $files = @($apps | Where-Object { $_.Path -like '*\*.exe' -and $_.Path -notmatch '\\Windows\\' } | Select-Object -ExpandProperty Path -Unique)
    if ($files.Count -and (Ask-User ("Назначить этим программам встроенную графику Radeon 780M (энергосбережение)?`n`n" + ($files -join "`n") +
            "`n`nИгры из списка лучше не трогать. Откат - переключатель «Браузеры и мессенджеры - без RTX 4070» на странице «Батарея».") 'Видеокарта и батарея')) {
        $script:Cat = 'battery:gpuprefs'
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
    } else { Out-Box 'Автопереключение:    выкл (страница «Батарея»)' }

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
    if (-not (Test-AgentTask)) { Out-Box 'Автопереключение не включено (страница «Батарея» -> «Экономия при работе от батареи»).'; return }
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
    Out-Box '', 'Глубже: Sysinternals Autoruns (страница «Инструменты»).'
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
        '  0. Сначала мощность: «Включить всё для 140 Вт» на странице «Видеокарта».',
        '  1. Установите Afterburner + HWiNFO + OCCT/FurMark (страница «Инструменты»).',
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
        '  - Страницы «Оптимизация Windows» и «Видеокарта» в этой программе.',
        '  - Свежие драйверы NVIDIA и AMD Chipset (страница «Оптимизация Windows» -> «Драйверы NVIDIA и AMD»).'
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
        '  6. Запустите этот Toolkit: Главная -> всё жёлтое и красное по кнопкам справа.'
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

# ================= СТРАНИЦЫ =================
# Каждая страница - список строк. Строка сама проверяет состояние (Load) и показывает ✓ / ! / ✕,
# а кнопка или переключатель справа сразу исправляет. Проверки идут в фоне по одной строке,
# поэтому окно не зависает.

$script:Pages = [ordered]@{}
$script:NavItems = @{}
$script:PageKey = $null
$script:Queue = New-Object Collections.ArrayList
$script:Cache = @{}

function Cached([string]$key, [int]$sec, [scriptblock]$get) {
    $c = $script:Cache[$key]
    if ($c -and ((Get-Date) - $c.T).TotalSeconds -lt $sec) { return $c.V }
    $v = & $get
    $script:Cache[$key] = @{ T = Get-Date; V = $v }
    return $v
}

function Add-Nav([string]$key, [string]$title, [string]$icon) {
    $n = New-Object LTK.UI.NavItem
    $n.Text = $title; $n.Glyph = Ico $icon; $n.GlyphFont = $fIconNav; $n.Font = $fUi
    $n.Size = Sz 208 42; $n.Margin = Pad 0 0 0 3; $n.Tag = $key
    $n.Add_Click({ param($s, $e) Show-Page $s.Tag })
    $navFlow.Controls.Add($n)
    $script:NavItems[$key] = $n
    $n
}

function Add-Page([string]$key, [string]$title, [string]$icon, [string]$desc) {
    [void](Add-Nav $key $title $icon)
    $flow = New-Object Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
    $flow.BackColor = $bg; $flow.Padding = Pad 0 0 14 18; $flow.Visible = $false
    $t = New-Object Windows.Forms.Label
    $t.Text = $title; $t.Font = $fPage; $t.ForeColor = $fg; $t.AutoSize = $true; $t.Margin = Pad 0 12 0 2
    $d = New-Object Windows.Forms.Label
    $d.Text = $desc; $d.Font = $fUi; $d.ForeColor = $cDim; $d.AutoSize = $true; $d.Margin = Pad 2 0 0 10; $d.Tag = 'wrap'
    $flow.Controls.AddRange(@($t, $d))
    $flow.Add_Resize({ param($s, $e) Update-PageWidth $s })
    $pageHost.Controls.Add($flow)
    $script:Pages[$key] = @{ Flow = $flow; Rows = (New-Object Collections.ArrayList) }
    $script:CurPage = $key
}

function Update-PageWidth($flow) {
    $w = $flow.ClientSize.Width - $flow.Padding.Horizontal - 2
    if ($w -lt 200) { return }
    $flow.SuspendLayout()
    foreach ($c in $flow.Controls) {
        if ($c -is [LTK.UI.Row]) { if ($c.Width -ne $w) { $c.Width = $w } }
        elseif ($c.Tag -eq 'wrap') { $c.MaximumSize = New-Object Drawing.Size($w, 0) }
    }
    $flow.ResumeLayout()
}

function Add-Section([string]$text, [string]$hint = '') {
    $flow = $script:Pages[$script:CurPage].Flow
    $l = New-Object Windows.Forms.Label
    $l.Text = $text.ToUpper(); $l.Font = $fTileCap; $l.ForeColor = $accent; $l.AutoSize = $true; $l.Margin = Pad 2 16 0 6
    $flow.Controls.Add($l)
    if ($hint) {
        $h = New-Object Windows.Forms.Label
        $h.Text = $hint; $h.Font = $fSmall; $h.ForeColor = $cDim; $h.AutoSize = $true; $h.Margin = Pad 2 0 0 8; $h.Tag = 'wrap'
        $flow.Controls.Add($h)
    }
}

# -Load { param($r) ... Set-Row $r ... } проверяет состояние; -Click { param($r) ... } выполняет действие.
# -ToLog: после действия открыть «Журнал» (там подробный текст).
function Add-Row([string]$title, [string]$desc, [string]$action = '', [scriptblock]$Load = $null, [scriptblock]$Click = $null,
                 [switch]$Switch, [switch]$Primary, [switch]$ToLog, [double]$H = 70) {
    $r = New-Object LTK.UI.Row
    $r.Title = $title; $r.Desc = $desc; $r.Action = $action; $r.Switch = [bool]$Switch; $r.Primary = [bool]$Primary
    $r.TitleFont = $(if ($Primary) { $fTitleRow } else { $fSemi }); $r.DescFont = $fSmall; $r.ValueFont = $fUi; $r.ActionFont = $fSemiSm
    $r.Height = Px $H; $r.Margin = Pad 0 0 0 8
    $r.State = $(if ($Load) { 4 } else { 0 })
    $r.Tag = @{ Load = $Load; Click = $Click; Name = $title; Page = $script:CurPage; ToLog = [bool]$ToLog; Loaded = $false }
    $r.Add_ActionClick({ param($s, $e) Invoke-RowClick $s })
    $p = $script:Pages[$script:CurPage]
    $p.Flow.Controls.Add($r)
    [void]$p.Rows.Add($r)
    $r
}

function Set-Row($r, [int]$State, $Value = $null, $Desc = $null, $On = $null, $Action = $null) {
    $r.State = $State
    if ($null -ne $Value) { $r.Value = $Value }
    if ($null -ne $Desc) { $r.Desc = $Desc }
    if ($null -ne $On) { $r.On = [bool]$On }
    if ($null -ne $Action) { $r.Action = $Action }
    $r.Invalidate()
}

function Load-Row($r) {
    $t = $r.Tag
    if (-not $t.Load) { return }
    try { & $t.Load $r; $t.Loaded = $true }
    catch { Set-Row $r 5 'не удалось проверить' "Причина: $($_.Exception.Message)" }
}

function Invoke-RowClick($r) {
    $t = $r.Tag
    if (-not $t.Click) { return }
    Invoke-Safe $t.Name { & $t.Click $r }
    $script:Cache.Clear()
    if ($t.ToLog) { Show-Page 'log' }
    else {
        if ($t.Load) { Load-Row $r }
        Queue-Page $t.Page -Front
    }
}

function Queue-Page([string]$key, [switch]$Front) {
    $p = $script:Pages[$key]
    if (-not $p) { return }
    $rows = @($p.Rows | Where-Object { $_.Tag.Load })
    foreach ($r in $rows) { $script:Queue.Remove($r) }
    if ($Front) { $script:Queue.InsertRange(0, $rows) } else { $script:Queue.AddRange($rows) }
}

function Show-Page([string]$key) {
    if ($script:PageKey -eq $key) { return }
    $script:PageKey = $key
    foreach ($k in $script:NavItems.Keys) { $script:NavItems[$k].Selected = ($k -eq $key); $script:NavItems[$k].Invalidate() }
    $pageHost.SuspendLayout()
    foreach ($k in $script:Pages.Keys) { $script:Pages[$k].Flow.Visible = ($k -eq $key) }
    $logPage.Visible = ($key -eq 'log')
    $pageHost.ResumeLayout()
    if ($key -eq 'log') {
        $script:LogNav.Dot = $false; $script:LogNav.Invalidate()
    } else {
        $f = $script:Pages[$key].Flow
        Update-PageWidth $f
        $f.AutoScrollPosition = New-Object Drawing.Point(0, 0)
        Queue-Page $key -Front
    }
}

$loader = New-Object Windows.Forms.Timer
$loader.Interval = 40
$loader.Add_Tick({
    if ($script:Busy -or -not $script:Queue.Count) { return }
    $loader.Stop()
    try {
        $r = $script:Queue[0]
        $script:Queue.RemoveAt(0)
        Load-Row $r
    } finally { $loader.Start() }
})

# ----- общие проверки -----
function Fmt-Sec($v) { if ($v -le 0) { 'никогда' } elseif ($v -ge 3600 -and $v % 3600 -eq 0) { "$($v / 3600) ч" } elseif ($v -ge 60) { "$([int]($v / 60)) мин" } else { "$v с" } }

function Get-DbState {
    $pcf = @(Get-Nvpcf)
    if (-not $pcf.Count) { return 'missing' }
    $d = $pcf[0]
    $code = Get-CmCode $d
    if ("$($d.Status)" -eq 'OK') { return 'ok' }
    if ($code -eq 22) { return 'disabled' }
    if ($code -eq 28) { return 'nodriver' }
    return "error $code"
}

function Get-GpuInfo {
    Cached 'gpu' 20 {
        $h = @{ Smi = [bool]$Smi; Db = (Get-DbState); Max = $null; Def = $null; Cur = $null; AC = ([LTK.Pwr]::OnAC() -eq 1) }
        # опрос nvidia-smi будит видеокарту - на батарее не трогаем
        if ($Smi -and $h.AC) {
            $v = Get-SmiValues @('enforced.power.limit', 'power.default_limit', 'power.max_limit')
            $h.Cur = Num $v['enforced.power.limit']; $h.Def = Num $v['power.default_limit']; $h.Max = Num $v['power.max_limit']
        }
        $h
    }
}

function Get-MpInfo { Cached 'mp' 30 { try { Get-MpComputerStatus -ErrorAction Stop } catch { $null } } }

# Control Center (Uniwill/Tongfang, на этой платформе - версия 5.x): в нём переключаются режим графики и Turbo.
function Find-ControlCenter {
    Cached 'cc' 30 {
        $id = $null
        try {
            $a = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match 'Control\s*Cent' -and $_.Name -notmatch 'NVIDIA|AMD|Radeon' } | Select-Object -First 1
            if ($a) { $id = "shell:AppsFolder\$($a.AppID)" }
        } catch { }
        if (-not $id) {
            try {
                $pk = Get-AppxPackage -ErrorAction Stop | Where-Object { $_.Name -match 'ControlCenter' -and $_.Name -notmatch 'NVIDIA' } | Select-Object -First 1
                if ($pk) { $id = "shell:AppsFolder\$($pk.PackageFamilyName)!App" }
            } catch { }
        }
        if (-not $id) {
            $app = Get-InstalledApps | Where-Object { $_.DisplayName -match 'Control\s*Cent' -and $_.DisplayName -notmatch 'NVIDIA|AMD' } | Select-Object -First 1
            if ($app) {
                $ico = "$($app.DisplayIcon)".Trim('"') -replace ',\s*-?\d+$', ''
                if ($ico -like '*.exe' -and (Test-Path $ico)) { $id = $ico }
            }
        }
        $id
    }
}
function Open-ControlCenter {
    $id = Find-ControlCenter
    if ($id) {
        try { Start-Process $id -ErrorAction Stop; Set-Status 'Открыт Control Center.' $cOk; return $true } catch { }
    }
    Show-Info ("Control Center (утилита ноутбука) не найден.`n`n" +
        "Установите его из файла ControlCenter_5.1.50.27_STD (с сайта поддержки Skytech): запустите установщик из папки, " +
        "затем перезагрузите ноутбук.`n`nВ Control Center переключаются режим графики (гибрид / только RTX 4070) и режим Turbo для 140 Вт.") 'Control Center'
    return $false
}

function Show-HybridDialog {
    $mode = Get-GraphicsMode
    if ($mode -eq 'hybrid') { Show-Info 'Уже гибридный режим: экран на встроенной Radeon 780M, RTX 4070 спит, пока не запущена игра. Ничего делать не нужно.' 'Режим графики'; return }
    $cc = [bool](Find-ControlCenter)
    $msg = "Сейчас: $(Get-GraphicsModeText).`n`n" +
           "КАК ВКЛЮЧИТЬ ГИБРИДНЫЙ РЕЖИМ:`n" +
           "1. Control Center -> переключатель графики (GPU Switch / iGPU-dGPU) -> гибридный режим (Hybrid / MSHybrid / Optimus) -> перезагрузка.`n" +
           "2. Нет такого переключателя - Панель управления NVIDIA -> «Управление режимом дисплея» -> «Оптимус NVIDIA», или BIOS -> Graphics Mode -> Hybrid.`n" +
           "3. Монитор по HDMI обычно подключён к RTX 4070 - на батарее отключайте его.`n`n" +
           "Для игр от сети можно вернуть «только dGPU» (+5..15% FPS).`n`n" +
           $(if ($cc) { 'Открыть Control Center?' } else { 'Control Center не найден. Открыть Панель управления NVIDIA?' })
    if (Ask-User $msg 'Режим графики') { if ($cc) { [void](Open-ControlCenter) } else { Open-NvidiaPanel } }
}

function Add-ControlCenterRow([string]$desc) {
    [void](Add-Row 'Control Center (утилита ноутбука)' $desc 'Открыть' -Load {
        param($r)
        if (Find-ControlCenter) { Set-Row $r 1 'установлен' -Action 'Открыть' }
        else { Set-Row $r 2 'не установлен' -Action 'Как установить' }
    } -Click { [void](Open-ControlCenter) })
}

function Set-GraphicsRow($r) {
    switch (Get-GraphicsMode) {
        'hybrid'   { Set-Row $r 1 'гибридный' 'Экран на встроенной Radeon 780M, RTX 4070 спит, пока не запущена игра.' -Action 'Подробнее' }
        'dgpu'     { Set-Row $r 3 'только RTX 4070' 'Видеокарта не засыпает никогда - главный расход батареи. Для батареи переключите на гибридный.' -Action 'Как переключить' }
        'external' { Set-Row $r 2 'внешний монитор на RTX 4070' 'Пока монитор подключён, видеокарта не засыпает. На батарее отключайте его.' -Action 'Подробнее' }
        default    { Set-Row $r 5 'NVIDIA не видна' 'Драйвер видеокарты не установлен или видеокарта отключена.' -Action '' }
    }
}

# ----- настройки с переключателем -----
# Get возвращает @{ On; Value; Na }. Apply включает (с записью исходных значений), Off - ставит обычные значения,
# если откатывать нечего (например, настройку поменяли не мы).
$script:Items = [ordered]@{}
function Def-Item([string]$cat, [string]$key, [string]$title, [string]$desc, [bool]$rec, [scriptblock]$get, [scriptblock]$apply, [scriptblock]$off, [string]$note = '') {
    $it = @{ Cat = $cat; Key = $key; Title = $title; Desc = $desc; Rec = $rec; Get = $get; Apply = $apply; Off = $off; Note = $note }
    $script:Items["$cat`:$key"] = $it
    $it
}
function Get-ItemState($it) {
    $g = & $it.Get
    if ($null -eq $g) { $g = @{ Na = $true } }
    $g
}
function Set-Option($it, [bool]$on) {
    $cat = "$($it.Cat):$($it.Key)"
    if ($on) { $script:Cat = $cat; & $it.Apply }
    else {
        $script:Cat = $null
        $n = Undo-Journal $cat
        if (-not $n -and $it.Off) { & $it.Off }
    }
    $script:Cat = $null
    [void][LTK.Pwr]::Apply()
}
function Add-ItemRow($it) {
    $r = Add-Row $it.Title $it.Desc -Switch -Load {
        param($r)
        $it = $r.Tag.Item
        $g = Get-ItemState $it
        if ($g.Na) { Set-Row $r 5 $(if ($g.Value) { $g.Value } else { 'нет на этом ноутбуке' }) -On $false; return }
        $st = if ($g.On) { 1 } elseif ($it.Rec) { 2 } else { 0 }
        Set-Row $r $st "$($g.Value)" -On ([bool]$g.On)
    } -Click {
        param($r)
        $it = $r.Tag.Item
        $want = -not $r.On
        Set-Option $it $want
        $msg = "$($it.Title): $(if ($want) { 'включено' } else { 'выключено' })"
        if ($it.Note) { $msg += ". $($it.Note)" }
        Set-Status $msg $cOk
    }
    $r.Tag.Item = $it
    $r
}
function Get-Summary([string]$cat) {
    $all = @($script:Items.Values | Where-Object { $_.Cat -eq $cat -and $_.Rec })
    $on = 0; $total = 0
    foreach ($it in $all) { $g = Get-ItemState $it; if ($g.Na) { continue }; $total++; if ($g.On) { $on++ } }
    @{ On = $on; Total = $total }
}
function Set-AllItems([string]$cat, [bool]$on) {
    $n = 0
    foreach ($it in @($script:Items.Values | Where-Object { $_.Cat -eq $cat })) {
        if ($on -and -not $it.Rec) { continue }
        $g = Get-ItemState $it
        if ($g.Na -or [bool]$g.On -eq $on) { continue }
        Set-Status "$(if ($on) { 'Включаю' } else { 'Выключаю' }): $($it.Title)..." $accent
        [Windows.Forms.Application]::DoEvents()
        Set-Option $it $on
        $n++
    }
    # частично применённые настройки (например, Windows не дала включить гибернацию) тоже откатываем
    if (-not $on) { $n += Undo-Journal "$cat*" }
    $n
}

# --- батарея ---
function Disable-AgentPart([hashtable]$changes) {
    $cfg = Get-AgentConfig
    if (-not $cfg -or -not (Test-AgentTask)) { return }
    $left = @{ Refresh = [bool]$cfg.Refresh; DcOverlay = "$($cfg.DcOverlay)"; AcOverlay = "$($cfg.AcOverlay)" }
    foreach ($k in $changes.Keys) { $left[$k] = $changes[$k] }
    if (-not $left.Refresh -and -not $left.DcOverlay -and -not $left.AcOverlay) { Uninstall-Agent }
    else {
        Install-Agent $changes
        if ($changes.ContainsKey('Refresh') -and -not $changes.Refresh) { $rates = @([LTK.Disp]::Rates()); if ($rates.Count) { [void][LTK.Disp]::Set($rates[-1]) } }
    }
    if ($changes.ContainsKey('DcOverlay') -and [LTK.Pwr]::OnAC() -eq 0) { [void][LTK.Pwr]::SetOverlay($OV_BAL) }
}
function Test-AgentFlag([string]$name) {
    $cfg = Get-AgentConfig
    if (-not $cfg -or -not (Test-AgentTask)) { return $null }
    $cfg.$name
}
function Pow-Item([string]$sub, [string]$set) { $v = Get-Pow $sub $set; if ($v -lt 0) { $null } else { $v } }

[void](Def-Item 'battery' 'refresh' 'Экран 60 Гц на батарее' '240 Гц заметно тратят заряд. При подключении зарядки частота сама вернётся на максимум.' $true {
    $rates = @([LTK.Disp]::Rates())
    if ($rates.Count -lt 2) { return @{ Na = $true; Value = 'частоту не поменять' } }
    $on = [bool](Test-AgentFlag 'Refresh')
    @{ On = $on; Value = $(if ($on) { "60 Гц на батарее, $($rates[-1]) Гц от сети" } else { "всегда $([LTK.Disp]::Current()) Гц" }) }
} { Install-Agent @{ Refresh = $true; DcHz = 60 } } { Disable-AgentPart @{ Refresh = $false } })

[void](Def-Item 'battery' 'overlay' 'Экономичный режим Windows на батарее' 'Без зарядки - «Лучшая энергоэффективность», от сети - «Максимальная производительность». Переключается само.' $true {
    $on = ((Test-AgentFlag 'DcOverlay') -eq $OV_EFF)
    @{ On = $on; Value = $(if ($on) { 'переключается само' } else { 'не переключается' }) }
} { Install-Agent @{ DcOverlay = $OV_EFF; AcOverlay = $OV_PERF }; if ([LTK.Pwr]::OnAC() -eq 0) { [void][LTK.Pwr]::SetOverlay($OV_EFF) } } { Disable-AgentPart @{ DcOverlay = '' } })

[void](Def-Item 'battery' 'boost' 'Процессор без турбобуста на батарее' 'До 3,8 ГГц вместо 5,1: в браузере и видео почти незаметно, а работает заметно дольше. От сети турбо остаётся.' $true {
    $v = Pow-Item $PW.Proc $PW.Boost
    if ($null -eq $v) { return @{ Na = $true } }
    @{ On = ($v -eq 0); Value = $(if ($v -eq 0) { 'турбо выключено' } else { 'турбо включено' }) }
} { Set-Pow $PW.Proc $PW.Boost 0 'Турбобуст на батарее: выкл'; powercfg -attributes $PW.Proc $PW.Boost -ATTRIB_HIDE 2>&1 | Out-Null } { Set-Pow $PW.Proc $PW.Boost 2 'Турбобуст на батарее: вкл' })

[void](Def-Item 'battery' 'epp' 'Процессор бережёт энергию' 'Частота мягче поднимается в лёгких задачах.' $true {
    $v = Pow-Item $PW.Proc $PW.Epp
    if ($null -eq $v) { return @{ Na = $true } }
    @{ On = ($v -ge 70); Value = "приоритет экономии $v %" }
} { Set-Pow $PW.Proc $PW.Epp 80 'Энергоэффективность процессора: 80%' } { Set-Pow $PW.Proc $PW.Epp 50 'Энергоэффективность процессора: 50%' })

[void](Def-Item 'battery' 'saver' 'Экономия энергии - сразу без зарядки' 'Windows приглушает фоновые задачи и синхронизацию. Обычно это включается только при 20%.' $true {
    $v = Pow-Item $PW.Saver $PW.SaverAt
    if ($null -eq $v) { return @{ Na = $true } }
    @{ On = ($v -ge 100); Value = $(if ($v -ge 100) { 'с первой минуты' } else { "только при $v %" }) }
} { Set-Pow $PW.Saver $PW.SaverAt 100 'Экономия энергии: всегда на батарее' } { Set-Pow $PW.Saver $PW.SaverAt 20 'Экономия энергии: при 20%' })

[void](Def-Item 'battery' 'screen' 'Экран гаснет через 3 мин, сон через 10 мин' 'Только на батарее. От сети - как было.' $true {
    $so = Pow-Item $PW.Video $PW.ScreenOff; $sl = Pow-Item $PW.Sleep $PW.SleepAfter
    if ($null -eq $so) { return @{ Na = $true } }
    $on = ($so -gt 0 -and $so -le 300 -and $null -ne $sl -and $sl -gt 0 -and $sl -le 900)
    @{ On = $on; Value = "экран $(Fmt-Sec $so) · сон $(Fmt-Sec $sl)" }
} { Set-Pow $PW.Video $PW.ScreenOff 180 'Экран на батарее: 3 мин'; Set-Pow $PW.Sleep $PW.SleepAfter 600 'Сон на батарее: 10 мин' } {
    Set-Pow $PW.Video $PW.ScreenOff 300 'Экран на батарее: 5 мин'; Set-Pow $PW.Sleep $PW.SleepAfter 900 'Сон на батарее: 15 мин' })

[void](Def-Item 'battery' 'standby' 'Не разряжается во сне' 'Во сне без интернета, через час сна - гибернация: можно оставить в рюкзаке на ночь.' $true {
    $ns = Pow-Item $PW.None $PW.NetStandby; $ha = Pow-Item $PW.Sleep $PW.HibAfter
    if ($null -eq $ns -and $null -eq $ha) { return @{ Na = $true } }
    $hib = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled -eq 1)
    $on = ($null -eq $ns -or $ns -eq 0) -and $hib -and $ha -gt 0
    @{ On = $on; Value = $(if ($hib -and $ha -gt 0) { "гибернация через $(Fmt-Sec $ha)" } else { 'гибернации нет' }) }
} {
    $pk = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
    Save-Original 'hib' @{ Kind = 'hib'; WasOn = ($pk.HibernateEnabled -eq 1); WasType = $pk.HiberFileType }
    if ($pk.HibernateEnabled -ne 1) { powercfg /hibernate on 2>&1 | Out-Null }
    if ($pk.HiberFileType -eq 1) { powercfg /h /type full 2>&1 | Out-Null }
    Set-Pow $PW.None $PW.NetStandby 0 'Интернет во сне на батарее: выкл'
    Set-Pow $PW.Sleep $PW.HibAfter 3600 'Гибернация через 1 час сна'
} { Set-Pow $PW.None $PW.NetStandby 2 'Интернет во сне: решает Windows'; Set-Pow $PW.Sleep $PW.HibAfter 0 'Гибернация после сна: никогда' })

[void](Def-Item 'battery' 'devices' 'Энергосбережение Wi-Fi, SSD и USB' 'Простаивающие устройства засыпают. Если на батарее начнёт подтормаживать мышь или Wi-Fi - выключите.' $true {
    $a = Pow-Item $PW.Pcie $PW.Aspm; $w = Pow-Item $PW.Wifi $PW.WifiSave
    if ($null -eq $a -and $null -eq $w) { return @{ Na = $true } }
    $on = ($null -eq $a -or $a -eq 2) -and ($null -eq $w -or $w -eq 3)
    @{ On = $on; Value = $(if ($on) { 'максимальная экономия' } else { 'частичная' }) }
} {
    Set-Pow $PW.Pcie $PW.Aspm 2 'PCIe на батарее: максимальная экономия'
    Set-Pow $PW.Usb $PW.UsbSuspend 1 'USB на батарее: засыпают'
    Set-Pow $PW.Wifi $PW.WifiSave 3 'Wi-Fi на батарее: максимальная экономия'
} { Set-Pow $PW.Pcie $PW.Aspm 1 'PCIe: умеренно'; Set-Pow $PW.Wifi $PW.WifiSave 1 'Wi-Fi: умеренно' })

[void](Def-Item 'battery' 'video' 'Видео в экономичном режиме' 'YouTube и фильмы на батарее воспроизводятся с упором на экономию.' $true {
    $v = Pow-Item $PW.Media $PW.VideoPlay
    if ($null -eq $v) { return @{ Na = $true } }
    @{ On = ($v -eq 2); Value = $(switch ($v) { 0 { 'упор на качество' } 1 { 'баланс' } default { 'упор на экономию' } }) }
} { Set-Pow $PW.Media $PW.VideoPlay 2 'Видео на батарее: экономия' } { Set-Pow $PW.Media $PW.VideoPlay 1 'Видео на батарее: баланс' })

[void](Def-Item 'battery' 'gpuprefs' 'Браузеры и мессенджеры - без RTX 4070' 'Работают на встроенной графике и не будят видеокарту (проснувшаяся RTX 4070 тратит несколько ватт).' $true {
    $apps = @(Get-LowPowerApps)
    if (-not $apps.Count) { return @{ Na = $true; Value = 'браузеры не найдены' } }
    $k = Get-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction SilentlyContinue
    $n = @($apps | Where-Object { $k -and "$($k.$_)" -match 'GpuPreference=1' }).Count
    $names = ($apps | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ', '
    @{ On = ($n -eq $apps.Count); Value = $(if ($n -eq $apps.Count) { $names } else { "$n из $($apps.Count): $names" }) }
} { foreach ($a in @(Get-LowPowerApps)) { Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $a 'GpuPreference=1;' 'String' } } {
    foreach ($a in @(Get-LowPowerApps)) { Remove-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name $a -ErrorAction SilentlyContinue } } 'Перезапустите браузеры')

[void](Def-Item 'battery' 'edge' 'Edge не висит в фоне' 'После закрытия Edge не остаётся в памяти. В его настройках появится «Управляется организацией» - это нормально.' $true {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -ErrorAction SilentlyContinue
    $on = ($k -and $k.StartupBoostEnabled -eq 0 -and $k.BackgroundModeEnabled -eq 0)
    @{ On = $on; Value = $(if ($on) { 'фон выключен' } else { 'работает в фоне' }) }
} { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0; Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0 } {
    foreach ($n in 'StartupBoostEnabled', 'BackgroundModeEnabled') { Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name $n -ErrorAction SilentlyContinue } })

[void](Def-Item 'battery' 'bgapps' 'Запретить фоновую работу приложений Store' 'Дополнительно (не входит в общий переключатель): экономит ещё, но WhatsApp, Почта и т.п. не пришлют уведомление, пока закрыты.' $false {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction SilentlyContinue).LetAppsRunInBackground
    @{ On = ($v -eq 2); Value = $(if ($v -eq 2) { 'запрещено' } else { 'разрешено' }) }
} { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2 } {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name 'LetAppsRunInBackground' -ErrorAction SilentlyContinue })

# --- Windows ---
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
function RegV([string]$path, [string]$name) { (Get-ItemProperty $path -Name $name -ErrorAction SilentlyContinue).$name }

[void](Def-Item 'windows' 'gamemode' 'Игровой режим' 'Игре - приоритет, обновления и фоновые задачи не мешают.' $true {
    $v = RegV 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    @{ On = ($null -eq $v -or $v -eq 1); Value = '' }
} { Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1; Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 } {
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0 })

[void](Def-Item 'windows' 'dvr' 'Без фоновой записи игр' 'Xbox Game Bar не пишет игру постоянно - больше FPS. Сам Game Bar (Win+G) остаётся.' $true {
    @{ On = ((RegV 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0); Value = '' }
} { Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0; Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 } {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1; Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 1 })

[void](Def-Item 'windows' 'hags' 'Аппаратное планирование GPU' 'Меньше задержка, нужно для DLSS Frame Generation.' $true {
    @{ On = ((RegV 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode') -eq 2); Value = '' }
} { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 } { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 1 } 'Нужна перезагрузка')

[void](Def-Item 'windows' 'telemetry' 'Телеметрия на минимуме' 'Меньше фоновой отправки данных в Microsoft - и меньше расход батареи.' $true {
    $s = Get-Service 'DiagTrack' -ErrorAction SilentlyContinue
    @{ On = ((RegV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry') -eq 0 -and (-not $s -or "$($s.StartType)" -eq 'Disabled')); Value = '' }
} { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0; foreach ($s in 'DiagTrack', 'dmwappushservice') { [void](Set-Svc $s 'Disabled') } } {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -ErrorAction SilentlyContinue
    Set-Service 'DiagTrack' -StartupType Automatic -ErrorAction SilentlyContinue; Set-Service 'dmwappushservice' -StartupType Manual -ErrorAction SilentlyContinue })

$CdmNames = 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'SubscribedContent-338388Enabled',
            'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
            'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled'
$Cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
[void](Def-Item 'windows' 'ads' 'Без рекламы и «рекомендаций»' 'Рекламный ID, предложения в Пуске и Параметрах, тихая установка игр вроде Candy Crush.' $true {
    @{ On = ((RegV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled') -eq 0 -and (RegV $Cdm 'SilentInstalledAppsEnabled') -eq 0); Value = '' }
} {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    foreach ($n in $CdmNames) { Set-Reg $Cdm $n 0 }
    Set-Reg $adv 'Start_IrisRecommendations' 0
} { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 1; foreach ($n in $CdmNames) { Set-Reg $Cdm $n 1 } } 'Применится после перезапуска Проводника')

[void](Def-Item 'windows' 'bing' 'Поиск в Пуске без Bing' 'Ищет только на компьютере - быстрее и без лишнего трафика.' $true {
    @{ On = ((RegV 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions') -eq 1); Value = '' }
} { Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1; Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 } {
    Remove-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BingSearchEnabled' -ErrorAction SilentlyContinue } 'Применится после перезапуска Проводника')

[void](Def-Item 'windows' 'widgets' 'Без виджетов и новостей' 'Убирает фоновые процессы виджетов на панели задач.' $true {
    @{ On = ((RegV 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests') -eq 0); Value = '' }
} { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 } {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue } 'Применится после перезапуска Проводника')

[void](Def-Item 'windows' 'copilot' 'Без Copilot' 'Убирает кнопку и отключает Copilot.' $true {
    @{ On = ((RegV 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot') -eq 1); Value = '' }
} {
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg $adv 'ShowCopilotButton' 0
} {
    foreach ($p in 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot') {
        Remove-ItemProperty $p -Name 'TurnOffWindowsCopilot' -ErrorAction SilentlyContinue }
} 'Применится после перезапуска Проводника')

[void](Def-Item 'windows' 'delivery' 'Не раздавать обновления чужим компьютерам' 'Windows только скачивает обновления, а не отдаёт их через ваш интернет.' $true {
    @{ On = ((RegV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode') -eq 0); Value = '' }
} { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 } {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name 'DODownloadMode' -ErrorAction SilentlyContinue })

[void](Def-Item 'windows' 'fileext' 'Показывать расширения файлов' 'Защита от вирусов вида «фото.jpg.exe».' $true {
    @{ On = ((RegV $adv 'HideFileExt') -eq 0); Value = '' }
} { Set-Reg $adv 'HideFileExt' 0 } { Set-Reg $adv 'HideFileExt' 1 } 'Применится после перезапуска Проводника')

[void](Def-Item 'windows' 'transp' 'Без прозрачности окон' 'Дополнительно: чуть меньше нагрузка на графику, но интерфейс проще.' $false {
    @{ On = ((RegV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency') -eq 0); Value = '' }
} { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 } {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 1 })

$CtxKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
[void](Def-Item 'windows' 'ctxmenu' 'Классическое меню правой кнопки' 'Дополнительно: сразу полное меню, как в Windows 10, без «Показать дополнительные параметры».' $false {
    @{ On = (Test-Path "$CtxKey\InprocServer32"); Value = '' }
} { Set-Reg "$CtxKey\InprocServer32" '(default)' '' 'String' } { Remove-Item $CtxKey -Recurse -Force -ErrorAction SilentlyContinue } 'Применится после перезапуска Проводника')

function Get-BloatFound {
    Cached 'bloat' 60 {
        $names = @($Bloat.Keys)
        $pk = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $names } | Select-Object -ExpandProperty Name -Unique)
        , $pk
    }
}

# ----- утилиты: скачать и сразу запустить -----
$WgLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
$Tools = @(
    @{ Name = 'HWiNFO64'; Desc = 'Все температуры, частоты и датчики. Главная программа для проверки перегрева.'; Id = 'REALiX.HWiNFO'; Match = 'HWiNFO'; Exe = 'HWiNFO64.exe'; Rec = $true
       Paths = @("$env:ProgramFiles\HWiNFO64\HWiNFO64.exe") }
    @{ Name = 'MSI Afterburner'; Desc = 'Разгон и андервольт RTX 4070, мониторинг в играх.'; Id = 'Guru3D.Afterburner'; Match = 'Afterburner'; Exe = 'MSIAfterburner.exe'; Rec = $true
       Paths = @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe") }
    @{ Name = 'OCCT'; Desc = 'Стресс-тест процессора, видеокарты, памяти и блока питания.'; Id = 'OCBase.OCCT.Personal'; Match = '^OCCT'; Exe = 'OCCT.exe'; Rec = $true
       Paths = @("$env:ProgramFiles\OCCT\OCCT.exe") }
    @{ Name = 'FurMark 2'; Desc = 'Нагрузка на видеокарту - для замера 140 Вт.'; Id = 'Geeks3D.FurMark.2'; Match = 'FurMark'; Exe = 'FurMark_GUI.exe'; Rec = $true
       Paths = @("$env:ProgramFiles\Geeks3D\FurMark2_x64\FurMark_GUI.exe", "$env:ProgramFiles\Geeks3D\FurMark2_x64\furmark.exe") }
    @{ Name = 'CrystalDiskInfo'; Desc = 'Здоровье и износ SSD.'; Id = 'CrystalDewWorld.CrystalDiskInfo'; Match = 'CrystalDiskInfo'; Exe = 'DiskInfo64.exe'; Rec = $true
       Paths = @("$env:ProgramFiles\CrystalDiskInfo\DiskInfo64.exe") }
    @{ Name = 'CrystalDiskMark'; Desc = 'Скорость SSD.'; Id = 'CrystalDewWorld.CrystalDiskMark'; Match = 'CrystalDiskMark'; Exe = 'DiskMark64.exe'; Rec = $false
       Paths = @("$env:ProgramFiles\CrystalDiskMark8\DiskMark64.exe") }
    @{ Name = 'Cinebench R23'; Desc = 'Тест производительности процессора.'; Id = 'Maxon.CinebenchR23'; Match = 'Cinebench'; Exe = 'Cinebench.exe'; Rec = $false; Paths = @() }
    @{ Name = 'CPU-Z'; Desc = 'Процессор и память: модель, частоты, тайминги.'; Id = 'CPUID.CPU-Z'; Match = 'CPU-Z'; Exe = 'cpuz.exe'; Rec = $false
       Paths = @("$env:ProgramFiles\CPUID\CPU-Z\cpuz.exe") }
    @{ Name = 'GPU-Z'; Desc = 'Видеокарта: модель, частоты, лимиты мощности.'; Id = 'TechPowerUp.GPU-Z'; Match = 'GPU-Z'; Exe = 'GPU-Z.exe'; Rec = $false
       Paths = @("$env:ProgramFiles\GPU-Z\GPU-Z.exe", "${env:ProgramFiles(x86)}\GPU-Z\GPU-Z.exe") }
    @{ Name = 'Autoruns'; Desc = 'Вся автозагрузка Windows (Microsoft Sysinternals).'; Id = 'Microsoft.Sysinternals.Autoruns'; Match = '^Autoruns'; Exe = 'Autoruns64.exe'; Rec = $false; Paths = @() }
    @{ Name = '7-Zip'; Desc = 'Архиватор.'; Id = '7zip.7zip'; Match = '^7-Zip'; Exe = '7zFM.exe'; Rec = $false; Paths = @("$env:ProgramFiles\7-Zip\7zFM.exe") }
)

function Get-InstalledApps {
    Cached 'apps' 10 {
        $l = @()
        foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*') {
            $l += @(Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Select-Object DisplayName, DisplayIcon, InstallLocation)
        }
        , $l
    }
}
function Get-ToolCandidates($t) {
    $c = @($t.Paths) + @(Join-Path $WgLinks $t.Exe)
    foreach ($a in @(Get-InstalledApps | Where-Object { $_.DisplayName -match $t.Match })) {
        if ($a.InstallLocation) { $c += Join-Path $a.InstallLocation $t.Exe }
        $ico = "$($a.DisplayIcon)".Trim('"') -replace ',\s*-?\d+$', ''
        if ($ico -like '*.exe') { $c += $ico }
    }
    $c
}
function Find-Tool($t) { Get-ToolCandidates $t | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1 }
function Start-Tool($t) {
    $p = Find-Tool $t
    if ($p) { Start-Process $p; Set-Status "Запущено: $($t.Name)" $cOk; return }
    if (-not (Test-Winget)) { return }
    # Скачивание идёт в отдельном окне; после установки программа запускается сама.
    $cands = (@(Get-ToolCandidates $t) + @("$env:ProgramFiles\$($t.Name)\$($t.Exe)") | ForEach-Object { "'$_'" }) -join ','
    Start-Console "Скачиваю $($t.Name)" ("Write-Host 'Скачиваю и устанавливаю $($t.Name)...'; " +
        "winget install -e --id $($t.Id) --silent --accept-package-agreements --accept-source-agreements; " +
        "`$p = @($cands) | Where-Object { Test-Path `$_ } | Select-Object -First 1; " +
        "if (`$p) { Write-Host 'Запускаю...'; Start-Process `$p } else { Write-Host 'Установлено - запустите из меню Пуск.' }")
}

# ================= ГЛАВНАЯ =================
Add-Page 'home' 'Главная' 'home' 'Состояние ноутбука проверяется само. Зелёное - в порядке, жёлтое и красное - нажмите кнопку справа.'

[void](Add-Row 'Видеокарта 140 Вт' '' 'Открыть' -Load {
    param($r)
    $g = Get-GpuInfo
    if (-not $g.Smi) { Set-Row $r 3 'драйвер NVIDIA не найден' 'Установите драйвер видеокарты - раздел «Видеокарта».'; return }
    if ($g.Db -ne 'ok') { Set-Row $r 3 'сейчас до 115 Вт' 'Не работает Dynamic Boost (+25 Вт). На странице «Видеокарта» - кнопка «Исправить».'; return }
    if (-not $g.AC) { Set-Row $r 1 'Dynamic Boost работает' 'Мощность проверю, когда подключите зарядку (на батарее опрос будит видеокарту).'; return }
    if ($g.Max -ge 139) { Set-Row $r 1 "до $([int]$g.Max) Вт" 'Dynamic Boost работает: в тяжёлых играх от сети - до 140 Вт.' }
    else { Set-Row $r 2 "до $([int]$g.Max) Вт" 'Прошивка ноутбука ограничивает мощность.' }
} -Click { Show-Page 'gpu' })

$script:HomeBat = Add-Row 'Экономия на батарее' '' 'Открыть' -Load {
    param($r)
    $s = Get-Summary 'battery'
    if ($s.On -eq $s.Total) { Set-Row $r 1 'включена' 'Отключили зарядку - ноутбук сам переходит на минимальный расход.' -Action 'Открыть' }
    elseif ($s.On -eq 0) { Set-Row $r 3 'выключена' 'Ноутбук на батарее работает как от сети и быстро садится. Включается одной кнопкой.' -Action 'Включить' }
    else { Set-Row $r 2 "включено $($s.On) из $($s.Total)" 'Часть настроек экономии выключена.' -Action 'Открыть' }
} -Click {
    param($r)
    if ($r.Action -eq 'Включить') { $n = Set-AllItems 'battery' $true; Set-Status "Экономия на батарее включена (изменено: $n)." $cOk; Queue-Page 'battery' }
    else { Show-Page 'battery' }
}

[void](Add-Row 'Режим графики' '' 'Как переключить' -Load { param($r) Set-GraphicsRow $r } -Click { Show-HybridDialog })

[void](Add-Row 'Оптимизация Windows' '' 'Открыть' -Load {
    param($r)
    $s = Get-Summary 'windows'
    $st = if ($s.On -eq $s.Total) { 1 } elseif ($s.On -ge $s.Total / 2) { 2 } else { 3 }
    Set-Row $r $st "включено $($s.On) из $($s.Total)" 'Без рекламы, телеметрии, лишних фоновых процессов; игровой режим.'
} -Click { Show-Page 'windows' })

[void](Add-Row 'Защита от вирусов' '' 'Открыть' -Load {
    param($r)
    $m = Get-MpInfo
    if (-not $m) { Set-Row $r 0 'другой антивирус' 'Защитник Windows выключен - видимо, стоит сторонний антивирус.'; return }
    if (-not $m.RealTimeProtectionEnabled) { Set-Row $r 3 'защита выключена' 'Защита в реальном времени выключена!'; return }
    $age = [int]((Get-Date) - $m.AntivirusSignatureLastUpdated).TotalDays
    if ($age -gt 7) { Set-Row $r 2 "базы устарели ($age дн.)" 'Обновите базы - страница «Безопасность».'; return }
    Set-Row $r 1 'работает' 'Защитник Windows включён, базы свежие.'
} -Click { Show-Page 'security' })

[void](Add-Row "Место на диске $env:SystemDrive" '' 'Очистить' -Load {
    param($r)
    $v = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if (-not $v) { Set-Row $r 5 'н/д'; return }
    $pct = [math]::Round($v.SizeRemaining * 100 / $v.Size)
    $st = if ($pct -lt 10) { 3 } elseif ($pct -lt 20) { 2 } else { 1 }
    Set-Row $r $st "свободно $(GB $v.SizeRemaining) из $(GB $v.Size) ГБ ($pct %)" 'Очистка удаляет временные файлы и корзину.'
} -Click { Do-Cleanup })

[void](Add-Row 'Батарея' '' 'Отчёт' -Load {
    param($r)
    try {
        $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
    } catch { $design = 0 }
    if ($design -gt 0 -and $full -gt 0) {
        $wear = [math]::Max(0, [math]::Round(100 - $full * 100 / $design, 1))
        $st = if ($wear -gt 30) { 3 } elseif ($wear -gt 20) { 2 } else { 1 }
        Set-Row $r $st "износ $wear %" "Ёмкость $([math]::Round($full / 1000, 1)) из $([math]::Round($design / 1000, 1)) Вт·ч."
    } else { Set-Row $r 0 'износ не определить' 'Подробный отчёт Windows откроется по кнопке.' }
} -Click { Do-Battery })

[void](Add-Row 'Оперативная память' '' -Load {
    param($r)
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $total = ($mods | Measure-Object Capacity -Sum).Sum
    if ($mods.Count -eq 1) { Set-Row $r 2 "$(GB $total) ГБ, одна планка" 'Одноканальный режим - главный тормоз в играх. Вторая такая же планка DDR5-5600 даст +10..30% FPS.' }
    else { Set-Row $r 1 "$(GB $total) ГБ, $($mods.Count) планки" 'Двухканальный режим.' }
})

[void](Add-Row 'Устройства и драйверы' '' 'Подробно' -ToLog -Load {
    param($r)
    $bad = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue)
    if ($bad.Count) { Set-Row $r 2 "проблем: $($bad.Count)" (($bad | Select-Object -First 2 | ForEach-Object Name) -join ', ') }
    else { Set-Row $r 1 'всё работает' 'Нет устройств с ошибками.' -Action '' }
} -Click { Do-Drivers })

[void](Add-Row 'Сбои за 30 дней' '' 'Подробно' -ToLog -Load {
    param($r)
    $since = (Get-Date).AddDays(-30)
    $bsod = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -MaxEvents 50 -ErrorAction SilentlyContinue).Count
    $off = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -MaxEvents 50 -ErrorAction SilentlyContinue).Count
    $tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since } -MaxEvents 50 -ErrorAction SilentlyContinue).Count
    $sum = $bsod + $off + $tdr
    if (-not $sum) { Set-Row $r 1 'не было' 'Синих экранов, внезапных выключений и сбоев видеодрайвера нет.' -Action ''; return }
    Set-Row $r $(if ($bsod) { 3 } else { 2 }) "синих экранов $bsod · выключений $off · сбоев видео $tdr" 'Выключения часто бывают от зажатой кнопки питания - смотрите подробности.'
} -Click { Do-Events })

[void](Add-Row 'Точка восстановления' 'Снимок системы: если что-то пойдёт не так - Win+R -> rstrui.' 'Создать' -Load {
    param($r)
    $p = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber | Select-Object -Last 1
    if (-not $p) { Set-Row $r 2 'нет ни одной'; return }
    $d = [Management.ManagementDateTimeConverter]::ToDateTime($p.CreationTime)
    $age = [int]((Get-Date) - $d).TotalDays
    Set-Row $r $(if ($age -gt 30) { 2 } else { 1 }) "последняя: $($d.ToString('dd.MM.yyyy'))"
} -Click { Do-Restore; Set-Status 'Точка восстановления создана.' $cOk })

[void](Add-Row 'Полная проверка и отчёт' 'Все проверки подряд с подробностями; отчёт сохранится в папку LaptopToolkit на рабочем столе.' 'Запустить' -ToLog -Click { Do-Full })

# ================= БАТАРЕЯ =================
Add-Page 'battery' 'Батарея' 'battery' 'Включите экономию один раз - дальше всё переключается само при отключении и подключении зарядки.'

$script:BatMaster = Add-Row 'Экономия при работе от батареи' 'Отключили зарядку - экран 60 Гц, процессор без турбо, экономичный режим Windows. Подключили - снова полная мощность.' -Switch -Primary -H 92 -Load {
    param($r)
    $s = Get-Summary 'battery'
    $on = ($s.Total -gt 0 -and $s.On -eq $s.Total)
    $st = if ($on) { 1 } elseif ($s.On) { 2 } else { 3 }
    Set-Row $r $st $(if ($on) { 'включена' } elseif ($s.On) { "включено $($s.On) из $($s.Total)" } else { 'выключена' }) -On $on
} -Click {
    param($r)
    if ($r.On) {
        if (-not (Ask-User 'Выключить экономию и вернуть настройки, которые были до программы?' 'Экономия на батарее')) { return }
        $n = Set-AllItems 'battery' $false
        $n += Undo-Journal 'battery'   # изменения версии 3.x
        Set-Status "Экономия выключена, настройки возвращены (изменено: $n)." $cOk
    } else {
        $n = Set-AllItems 'battery' $true
        Set-Status 'Готово! Отключите зарядку - через 2-3 секунды строка «Сейчас» покажет 60 Гц и экономичный режим.' $cOk
        Show-Info ("Экономия включена.`n`nПроверьте: отключите зарядку и посмотрите на строку «Сейчас» - через 2-3 секунды там будет «От батареи · 60 Гц · Лучшая энергоэффективность».`n`n" +
                   'Подключите зарядку - всё вернётся на полную мощность.') 'Экономия на батарее'
    }
}

$script:NowRow = Add-Row 'Сейчас' 'Отключите зарядку: через 2-3 секунды здесь появится «От батареи · 60 Гц · Лучшая энергоэффективность» - значит, всё работает.' -H 76
$script:NowRow.State = 0

Add-Section 'Главная причина расхода'
[void](Add-Row 'Режим графики' '' 'Как переключить' -Load { param($r) Set-GraphicsRow $r } -Click { Show-HybridDialog })
Add-ControlCenterRow 'В нём переключается режим графики: для батареи выберите гибридный (Hybrid / MSHybrid).'

Add-Section 'Что включается на батарее' 'Каждую настройку можно включить или выключить отдельно. Общий переключатель сверху включает все, кроме последней.'
foreach ($k in 'refresh', 'overlay', 'boost', 'epp', 'saver', 'screen', 'standby', 'devices', 'video', 'gpuprefs', 'edge', 'bgapps') {
    [void](Add-ItemRow $script:Items["battery:$k"])
}

Add-Section 'Что ещё садит батарею'
[void](Add-Row 'Что не даёт видеокарте уснуть' 'Какие программы держат RTX 4070 включённой.' 'Проверить' -ToLog -Click { Do-GpuHolders })
[void](Add-Row 'Энергоотчёт Windows' '60 секунд наблюдения: что мешает энергосбережению. Лучше запускать на батарее.' 'Запустить' -Click { Do-EnergyReport })
[void](Add-Row 'Расход во сне' 'Сколько заряда ушло во сне и что не давало спать.' 'Открыть' -Click { Do-SleepStudy })
[void](Add-Row 'Журнал переключений' 'Когда и что переключалось при подключении и отключении зарядки.' 'Показать' -ToLog -Click { Do-AgentLog })
[void](Add-Row 'Вручную (программа не может)' 'Подсветка клавиатуры - выключить (Fn + клавиша подсветки). Яркость 40-60%. NVIDIA App -> Battery Boost: вкл. AMD Software -> Vari-Bright: вкл.' -H 80)

# ================= ВИДЕОКАРТА =================
Add-Page 'gpu' 'Видеокарта' 'gpu' 'RTX 4070 Laptop: 115 Вт база + 25 Вт Dynamic Boost = 140 Вт. Только от сети. Прошивку программа не трогает.'

[void](Add-Row 'Включить всё для 140 Вт' 'Dynamic Boost, служба NVIDIA и режим «Максимальная производительность» от сети - одной кнопкой.' 'Сделать' -Primary -H 88 -Load {
    param($r)
    $g = Get-GpuInfo
    $perf = ((Test-AgentFlag 'AcOverlay') -eq $OV_PERF)
    if ($g.Db -eq 'ok' -and $perf) { Set-Row $r 1 'всё включено' } else { Set-Row $r 2 'есть что включить' }
} -Click { Do-Gpu140; Set-Status 'Готово - строки ниже обновлены. Подробности - в «Журнале».' $cOk })

[void](Add-Row 'Мощность видеокарты' '' -Load {
    param($r)
    $g = Get-GpuInfo
    if (-not $g.Smi) { Set-Row $r 3 'драйвер NVIDIA не найден' 'Установите драйвер - раздел «Обслуживание» -> «Драйверы NVIDIA и AMD».'; return }
    if (-not $g.AC) { Set-Row $r 0 'подключите зарядку' 'На батарее не проверяю: опрос будит видеокарту, а мощность всё равно урезана.'; return }
    $lim = "лимит $([int]$g.Def) Вт · потолок прошивки $([int]$g.Max) Вт"
    if ($g.Max -ge 139 -and $g.Db -eq 'ok') { Set-Row $r 1 $lim 'В тяжёлых играх Dynamic Boost добавит +25 Вт, когда процессор не загружен полностью.' }
    elseif ($g.Max -ge 139) { Set-Row $r 3 $lim 'Прошивка разрешает 140 Вт, но без Dynamic Boost видеокарта упирается в 115 Вт.' }
    else { Set-Row $r 2 $lim 'Прошивка ограничивает мощность - программно выше не поднять.' }
})

[void](Add-Row 'Dynamic Boost (+25 Вт)' '' 'Исправить' -Load {
    param($r)
    switch -Wildcard ((Get-GpuInfo).Db) {
        'ok'       { Set-Row $r 1 'работает' 'Компонент NVIDIA Platform Controllers and Framework работает.' -Action '' }
        'disabled' { Set-Row $r 3 'отключён' 'Отключён в Диспетчере устройств. Кнопка включит его.' -Action 'Включить' }
        'missing'  { Set-Row $r 3 'не найден' 'Нужен полный драйвер NVIDIA и, возможно, обновление BIOS. Кнопка подскажет, что делать.' -Action 'Исправить' }
        default    { Set-Row $r 3 'нет драйвера' 'Без него видеокарта ограничена 115 Вт. Кнопка попробует установить драйвер сама.' -Action 'Исправить' }
    }
} -Click { Fix-DynamicBoost })

[void](Add-Row 'Максимальная производительность от сети' 'При подключении зарядки Windows сама переходит в режим «Максимальная производительность».' -Switch -Load {
    param($r)
    $on = ((Test-AgentFlag 'AcOverlay') -eq $OV_PERF)
    Set-Row $r $(if ($on) { 1 } else { 2 }) $(if ($on) { 'включается само' } else { 'выключено' }) -On $on
} -Click {
    param($r)
    if ($r.On) {
        Disable-AgentPart @{ AcOverlay = '' }
        if ([LTK.Pwr]::OnAC() -eq 1) { [void][LTK.Pwr]::SetOverlay($OV_BAL) }
    } else {
        Install-Agent @{ AcOverlay = $OV_PERF }
        if ([LTK.Pwr]::OnAC() -eq 1) { [void][LTK.Pwr]::SetOverlay($OV_PERF) }
    }
})

[void](Add-Row 'Служба NVIDIA' 'NVIDIA Display Container - без неё не работают Панель NVIDIA и управление питанием.' 'Включить' -Load {
    param($r)
    $s = Get-Service 'NVDisplay.ContainerLocalSystem' -ErrorAction SilentlyContinue
    if (-not $s) { Set-Row $r 5 'не установлена' -Action ''; return }
    if ("$($s.Status)" -eq 'Running' -and "$($s.StartType)" -eq 'Automatic') { Set-Row $r 1 'работает' -Action '' }
    else { Set-Row $r 3 "$($s.Status) / $($s.StartType)" -Action 'Включить' }
} -Click {
    Set-Service 'NVDisplay.ContainerLocalSystem' -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service 'NVDisplay.ContainerLocalSystem' -ErrorAction SilentlyContinue
})

[void](Add-Row 'Режим графики' '' 'Как переключить' -Load { param($r) Set-GraphicsRow $r } -Click { Show-HybridDialog })
Add-ControlCenterRow 'Режим Turbo / Performance - без него ноутбук не даёт видеокарте 140 Вт. И переключатель графики.'

$script:PeakRow = Add-Row 'Замер пиковой мощности' 'Нажмите «Начать», запустите тяжёлую игру или FurMark 2 на 3-5 минут. ~140 Вт - всё работает.' 'Начать' -Click {
    param($r)
    if ($script:GpuMon) { $script:GpuMon = $false; Set-Row $r 0 -Action 'Начать'; return }
    if ([LTK.Pwr]::OnAC() -ne 1) { Show-Info 'Подключите зарядку: на батарее 140 Вт недостижимы, а замер будит видеокарту.' 'Замер мощности'; return }
    $script:GpuPeak = 0.0; $script:GpuMon = $true
    Set-Row $r 0 'идёт замер...' -Action 'Остановить'
}
$script:PeakRow.State = 0

Add-Section 'Разгон'
[void](Add-Row 'MSI Afterburner' 'Разгон и андервольт RTX 4070. Если не установлен - скачается и запустится сам.' 'Запустить' -Load {
    param($r)
    if (Find-Tool $Tools[1]) { Set-Row $r 1 'установлен' -Action 'Запустить' } else { Set-Row $r 0 'не установлен' -Action 'Скачать и запустить' }
} -Click { Start-Tool $Tools[1] })
[void](Add-Row 'Гайд по разгону и андервольту' 'Пошагово: частоты ядра и памяти, андервольт, проверка стабильности.' 'Открыть' -ToLog -Click { Do-OcGuide })

# ================= WINDOWS =================
Add-Page 'windows' 'Оптимизация Windows' 'windows' 'Переключатель включён - улучшение применено. Любой можно выключить обратно в любой момент.'

[void](Add-Row 'Рекомендуемая оптимизация' 'Включает все основные переключатели ниже. Сначала предложит создать точку восстановления.' 'Применить' -Primary -H 88 -Load {
    param($r)
    $s = Get-Summary 'windows'
    if ($s.On -eq $s.Total) { Set-Row $r 1 'всё применено' -Action '' } else { Set-Row $r 2 "применено $($s.On) из $($s.Total)" -Action 'Применить' }
} -Click {
    if (Ask-User 'Создать точку восстановления перед изменениями? (рекомендуется, ~30 секунд)' 'Оптимизация Windows') {
        try { Do-Restore } catch { Out-Box "[!] Точка восстановления: $($_.Exception.Message)" }
    }
    $n = Set-AllItems 'windows' $true
    Set-Status "Применено: $n. Часть изменений - после перезапуска Проводника или перезагрузки." $cOk
})

Add-Section 'Игры'
foreach ($k in 'gamemode', 'dvr', 'hags') { [void](Add-ItemRow $script:Items["windows:$k"]) }
Add-Section 'Реклама и приватность'
foreach ($k in 'ads', 'telemetry', 'bing', 'widgets', 'copilot', 'delivery') { [void](Add-ItemRow $script:Items["windows:$k"]) }
Add-Section 'Удобство'
foreach ($k in 'fileext', 'transp', 'ctxmenu') { [void](Add-ItemRow $script:Items["windows:$k"]) }
[void](Add-Row 'Перезапустить Проводник' 'Чтобы изменения панели задач и меню применились без перезагрузки. Окна папок закроются.' 'Перезапустить' -Click {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
})

Add-Section 'Лишние приложения'
[void](Add-Row 'Предустановленный мусор' '' 'Удалить' -Load {
    param($r)
    $f = @(Get-BloatFound)
    if (-not $f.Count) { Set-Row $r 1 'нет' 'Лишних предустановленных приложений не найдено.' -Action ''; return }
    Set-Row $r 2 "найдено: $($f.Count)" (($f | ForEach-Object { $Bloat[$_] }) -join ', ') -Action 'Удалить'
} -Click {
    $f = @(Get-BloatFound)
    if (-not (Ask-User ("Удалить эти приложения?`n`n" + (($f | ForEach-Object { $Bloat[$_] }) -join ', ') + "`n`nВернуть можно из Microsoft Store.") 'Лишние приложения')) { return }
    Head 'УДАЛЕНИЕ ПРЕДУСТАНОВЛЕННЫХ ПРИЛОЖЕНИЙ'
    foreach ($k in $f) {
        Set-Status "Удаляю: $($Bloat[$k])..." $accent; [Windows.Forms.Application]::DoEvents()
        Get-AppxPackage -Name $k -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
        Out-Box "  - $($Bloat[$k])"
    }
    Set-Status 'Лишние приложения удалены.' $cOk
})

Add-Section 'Обслуживание'
[void](Add-Row 'Точка восстановления' 'Снимок системы. Откат: Win+R -> rstrui.' 'Создать' -Click { Do-Restore; Set-Status 'Точка восстановления создана.' $cOk })
[void](Add-Row 'Очистка диска' 'Временные файлы, корзина и (по желанию) старые обновления Windows.' 'Очистить' -Load {
    param($r)
    $v = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($v) { Set-Row $r 0 "свободно $(GB $v.SizeRemaining) ГБ" }
} -Click { Do-Cleanup })
[void](Add-Row 'Автозагрузка программ' 'Отключите то, что не нужно сразу после включения: Steam, Discord, лаунчеры.' 'Открыть' -Click { Do-Startup })
[void](Add-Row 'Обновить Windows и программы' 'Центр обновления Windows и обновление всех программ через winget.' 'Обновить' -Click { Do-Update })
[void](Add-Row 'Драйверы NVIDIA и AMD' 'Официальные страницы драйверов видеокарты и чипсета.' 'Открыть' -Click { Do-DriversWeb })
[void](Add-Row 'Ремонт Windows' 'DISM + SFC: восстановление повреждённых системных файлов (10-30 минут).' 'Запустить' -Click { Do-Repair })
[void](Add-Row 'Chris Titus WinUtil' 'Сторонняя утилита твиков. Не отключайте в ней службы NVIDIA.' 'Запустить' -Click { Do-WinUtil })
[void](Add-Row 'Вернуть всё как было' 'Откатывает все изменения Windows, сделанные этой программой (кроме удалённых приложений).' 'Откатить' -Click {
    if (-not (Ask-User 'Вернуть все настройки Windows, которые меняла программа?' 'Откат')) { return }
    $n = Undo-Journal 'windows*'
    Set-Status "Возвращено значений: $n. Перезагрузите ноутбук." $cOk
})

# ================= ДИАГНОСТИКА =================
Add-Page 'diag' 'Диагностика' 'diag' 'Сведения о железе и системе - загружаются сами, ничего не меняют.'

[void](Add-Row 'Ноутбук' '' -Load {
    param($r)
    $cs = Get-CimInstance Win32_ComputerSystem; $b = Get-CimInstance Win32_BIOS
    Set-Row $r 0 ("$($cs.Manufacturer) $($cs.Model)".Trim()) "BIOS $($b.SMBIOSBIOSVersion) от $($b.ReleaseDate.ToString('dd.MM.yyyy'))"
})
[void](Add-Row 'Windows' '' -Load {
    param($r)
    $os = Get-CimInstance Win32_OperatingSystem
    $up = (Get-Date) - $os.LastBootUpTime
    Set-Row $r 0 "$($os.Caption -replace 'Microsoft ', ''), сборка $($os.BuildNumber)" "Без перезагрузки: $([int]$up.TotalDays) д $($up.Hours) ч"
})
[void](Add-Row 'Процессор' '' -Load {
    param($r)
    $c = Get-CimInstance Win32_Processor | Select-Object -First 1
    Set-Row $r 0 "$($c.Name.Trim())" "$($c.NumberOfCores) ядер / $($c.NumberOfLogicalProcessors) потоков, базовая частота $($c.MaxClockSpeed) МГц"
})
[void](Add-Row 'Оперативная память' '' -Load {
    param($r)
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $total = ($mods | Measure-Object Capacity -Sum).Sum
    $d = ($mods | ForEach-Object { "$($_.DeviceLocator): $(GB $_.Capacity) ГБ $($_.ConfiguredClockSpeed) MT/s" }) -join ' · '
    if ($mods.Count -eq 1) { Set-Row $r 2 "$(GB $total) ГБ, одноканальный режим" "$d. Вторая такая же планка = +10..30% FPS." }
    else { Set-Row $r 1 "$(GB $total) ГБ, двухканальный" $d }
})
[void](Add-Row 'Видеокарты' '' -Load {
    param($r)
    $v = @(Get-CimInstance Win32_VideoController)
    Set-Row $r 0 "$($v.Count) шт." (($v | ForEach-Object { "$($_.Name) (драйвер $($_.DriverVersion))" }) -join ' · ')
})
[void](Add-Row 'Диски' '' -Load {
    param($r)
    $parts = @(); $worst = 1
    foreach ($d in @(Get-PhysicalDisk)) {
        $rc = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $w = if ($rc -and $null -ne $rc.Wear) { ", износ $($rc.Wear) %" } else { '' }
        $t = if ($rc -and $rc.Temperature) { ", $($rc.Temperature) °C" } else { '' }
        $parts += "$($d.FriendlyName) $(GB $d.Size) ГБ: $($d.HealthStatus)$w$t"
        if ("$($d.HealthStatus)" -ne 'Healthy') { $worst = 3 }
    }
    Set-Row $r $worst $(if ($worst -eq 1) { 'исправны' } else { 'есть проблема!' }) ($parts -join ' · ')
})
[void](Add-Row 'Батарея' '' 'HTML-отчёт' -Load {
    param($r)
    try {
        $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
        $cyc = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Select-Object -First 1).CycleCount
    } catch { $design = 0 }
    if ($design -gt 0 -and $full -gt 0) {
        $wear = [math]::Max(0, [math]::Round(100 - $full * 100 / $design, 1))
        Set-Row $r $(if ($wear -gt 20) { 2 } else { 1 }) "износ $wear %" "Ёмкость $([math]::Round($full / 1000, 1)) из $([math]::Round($design / 1000, 1)) Вт·ч$(if ($cyc) { ", циклов: $cyc" })"
    } else { Set-Row $r 0 'подробнее в отчёте' }
} -Click { Do-Battery })
[void](Add-Row 'Безопасность загрузки' '' -Load {
    param($r)
    $sb = $(try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'вкл' } else { 'выкл' } } catch { '?' })
    $tpm = $(try { if ((Get-Tpm -ErrorAction Stop).TpmReady) { 'готов' } else { 'не готов' } } catch { '?' })
    $vbs = $(try { if ((Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop).VirtualizationBasedSecurityStatus -eq 2) { 'вкл' } else { 'выкл' } } catch { '?' })
    Set-Row $r 0 "Secure Boot $sb · TPM $tpm · VBS $vbs" 'VBS (целостность памяти) защищает лучше, но в части игр отнимает 5-10% FPS.'
})

Add-Section 'Тесты' 'Подключите зарядку. Температуру во время тестов смотрите в HWiNFO64 (страница «Инструменты»).'
[void](Add-Row 'Стресс-тест процессора, 1 минута' 'Быстрая проверка частот и охлаждения. Итог - в «Журнале».' 'Запустить' -Click { Start-CpuStress 60 })
[void](Add-Row 'Стресс-тест процессора, 10 минут' 'Долгая нагрузка: видно, сбрасывает ли процессор частоту от перегрева.' 'Запустить' -Click { Start-CpuStress 600 })
[void](Add-Row 'Остановить стресс-тест' '' 'Остановить' -ToLog -Click { Stop-CpuStress })
[void](Add-Row 'Тест оперативной памяти' 'Средство проверки памяти Windows. Ноутбук перезагрузится (~20 минут).' 'Запустить' -Click { Do-RamTest })
[void](Add-Row 'Скорость диска' 'Встроенный тест Windows (winsat).' 'Запустить' -Click { Do-DiskSpeed })
[void](Add-Row 'Полная проверка и отчёт' 'Все проверки подряд; отчёт сохранится в папку LaptopToolkit на рабочем столе.' 'Запустить' -ToLog -Click { Do-Full })

# ================= БЕЗОПАСНОСТЬ =================
Add-Page 'security' 'Безопасность' 'security' 'Состояние антивируса проверяется само. Проверки на вирусы - кнопками ниже.'

[void](Add-Row 'Антивирус' '' -Load {
    param($r)
    $av = @(try { Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object displayName } catch { })
    Set-Row $r $(if ($av.Count) { 1 } else { 3 }) $(if ($av.Count) { $av -join ', ' } else { 'не найден' })
})
[void](Add-Row 'Защита в реальном времени' '' 'Открыть' -Load {
    param($r)
    $m = Get-MpInfo
    if (-not $m) { Set-Row $r 5 'Защитник недоступен'; return }
    if ($m.RealTimeProtectionEnabled) { Set-Row $r 1 'включена' -Action '' } else { Set-Row $r 3 'ВЫКЛЮЧЕНА' 'Включите в «Безопасность Windows».' -Action 'Открыть' }
} -Click { Start-Process 'windowsdefender://threat' })
[void](Add-Row 'Антивирусные базы' '' 'Обновить' -Load {
    param($r)
    $m = Get-MpInfo
    if (-not $m) { Set-Row $r 5 'н/д' -Action ''; return }
    $age = [int]((Get-Date) - $m.AntivirusSignatureLastUpdated).TotalDays
    Set-Row $r $(if ($age -gt 7) { 2 } else { 1 }) "от $($m.AntivirusSignatureLastUpdated.ToString('dd.MM.yyyy'))"
} -Click { Start-Console 'Обновление баз Защитника' 'Update-MpSignature; Write-Host "Базы обновлены."' })
[void](Add-Row 'Найденные угрозы' '' 'Подробно' -ToLog -Load {
    param($r)
    $n = @(Get-MpThreatDetection -ErrorAction SilentlyContinue).Count
    if ($n) { Set-Row $r 2 "в истории: $n" 'Защитник уже что-то находил - посмотрите подробности.' } else { Set-Row $r 1 'нет' -Action '' }
} -Click { Do-AvStatus })
[void](Add-Row 'Исключения Защитника' 'Вирусы часто добавляют себя в исключения, чтобы их не проверяли.' 'Показать' -ToLog -Load {
    param($r)
    $p = Get-MpPreference -ErrorAction SilentlyContinue
    $ex = @(@($p.ExclusionPath) + @($p.ExclusionProcess) + @($p.ExclusionExtension) | Where-Object { $_ })
    if ($ex.Count) { Set-Row $r 2 "есть: $($ex.Count)" } else { Set-Row $r 1 'нет' -Action '' }
} -Click { Do-AvStatus })
[void](Add-Row 'Последняя проверка' '' 'Быстрая проверка' -Load {
    param($r)
    $m = Get-MpInfo
    if (-not $m) { Set-Row $r 5 'н/д' -Action ''; return }
    $full = if ($m.FullScanAge -gt 10000) { 'полной не было' } else { "полная - $($m.FullScanAge) дн. назад" }
    Set-Row $r $(if ($m.QuickScanAge -gt 14) { 2 } else { 1 }) "быстрая - $($m.QuickScanAge) дн. назад · $full"
} -Click { Do-QuickScan })

Add-Section 'Проверки'
[void](Add-Row 'Полная проверка Защитником' 'Все диски, 1-3 часа. Идёт в отдельном окне.' 'Запустить' -Click { Do-FullScan })
[void](Add-Row 'Автономная проверка' 'До загрузки Windows, ловит руткиты. Ноутбук перезагрузится (~15 минут).' 'Запустить' -Click { Do-OfflineScan })
[void](Add-Row 'Поиск подозрительного' 'Автозагрузка, задачи, службы, процессы, файл hosts и прокси.' 'Проверить' -ToLog -Click { Do-Suspicious })
[void](Add-Row 'Microsoft Safety Scanner' 'Официальный одноразовый сканер Microsoft - скачается и запустится сам (~200 МБ).' 'Запустить' -Click { Do-Msert })
[void](Add-Row 'Второе мнение (Kaspersky KVRT)' 'Бесплатный сканер без установки - откроется страница загрузки.' 'Открыть' -Click { Do-Kvrt })

# ================= ИНСТРУМЕНТЫ =================
Add-Page 'tools' 'Инструменты' 'install' 'Программы для проверки и разгона: нажмите - скачается и сразу запустится (официальные пакеты через winget).'

[void](Add-Row 'Скачать основные' 'HWiNFO64, MSI Afterburner, OCCT, FurMark 2 и CrystalDiskInfo - одним окном.' 'Скачать' -Primary -H 84 -Load {
    param($r)
    $miss = @($Tools | Where-Object { $_.Rec -and -not (Find-Tool $_) })
    if ($miss.Count) { Set-Row $r 2 "не хватает: $($miss.Count)" -Action 'Скачать' } else { Set-Row $r 1 'все установлены' -Action '' }
} -Click {
    if (-not (Test-Winget)) { return }
    $miss = @($Tools | Where-Object { $_.Rec -and -not (Find-Tool $_) })
    Start-Console 'Скачиваю основные программы' (($miss | ForEach-Object { "winget install -e --id $($_.Id) --silent --accept-package-agreements --accept-source-agreements" }) -join '; ')
})
Add-Section 'Программы'
foreach ($t in $Tools) {
    $r = Add-Row $t.Name $t.Desc 'Запустить' -Load {
        param($r)
        if (Find-Tool $r.Tag.Tool) { Set-Row $r 1 'установлена' -Action 'Запустить' } else { Set-Row $r 0 'не установлена' -Action 'Скачать и запустить' }
    } -Click { param($r) Start-Tool $r.Tag.Tool }
    $r.Tag.Tool = $t
}

Add-Section 'Переустановка Windows'
[void](Add-Row 'Как поставить чистую Windows' 'Пошаговый план и что сохранить заранее.' 'Открыть' -ToLog -Click { Do-WinGuide })
[void](Add-Row 'Бэкап драйверов' 'Сохранить все драйверы в папку отчётов (особенно важен Wi-Fi).' 'Сохранить' -Click { Do-DriverBackup })
[void](Add-Row 'Скачать Windows 11' 'Официальная страница Microsoft.' 'Открыть' -Click { Start-Process 'https://www.microsoft.com/software-download/windows11' })

# ================= ЖУРНАЛ =================
$script:LogNav = Add-Nav 'log' 'Журнал' 'report'

$chipSave.Add_Click({ Invoke-Safe 'Сохранить отчёт' { Do-Save } })
$chipFolder.Add_Click({ Start-Process explorer.exe $ReportDir })
$chipClear.Add_Click({ $box.Clear(); [void]$script:Log.Clear() })

function Fix-DynamicBoost {
    Head 'DYNAMIC BOOST'
    $st = Get-DbState
    if ($st -eq 'disabled') {
        $d = @(Get-Nvpcf)[0]
        Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    } elseif ($st -ne 'ok' -and $st -ne 'missing') { [void](Repair-Nvpcf) }
    $script:Cache.Clear()
    if ((Get-DbState) -eq 'ok') {
        Out-Ok '  + Dynamic Boost работает.'
        Show-Info 'Готово: Dynamic Boost работает. В тяжёлых играх от сети видеокарта сможет брать до 140 Вт.' 'Dynamic Boost'
        return
    }
    Show-DbHelp
    $msg = "Автоматически починить не получилось: драйвера Dynamic Boost нет на диске.`n`n" +
           "ЧТО СДЕЛАТЬ:`n1. Параметры -> Центр обновления -> Дополнительные параметры -> Необязательные обновления -> установить всё от NVIDIA.`n" +
           "2. Не помогло - драйвер с nvidia.com: при установке «Выборочная» -> «Чистая установка».`n" +
           "3. Перезагрузка -> снова откройте эту страницу.`n`nОткрыть необязательные обновления и сайт NVIDIA?"
    if (Ask-User $msg 'Dynamic Boost') {
        Start-Process 'ms-settings:windowsupdate-optionalupdates'
        Start-Process 'https://www.nvidia.com/drivers/'
    }
}

# ---------------- МОНИТОР ----------------
$script:GpuMon = $false
$tileGpu.Add_Click({
    if (-not $script:GpuMon -and [LTK.Pwr]::OnAC() -eq 0) {
        Set-Status 'На батарее слежение за видеокартой не включается: оно будит её.' $cWarn
        return
    }
    $script:GpuMon = -not $script:GpuMon
    Set-Row $script:PeakRow 0 -Action $(if ($script:GpuMon) { 'Остановить' } else { 'Начать' })
    Update-Monitor
})

$script:LastAC = $null
function Update-State {
    $ac = [LTK.Pwr]::OnAC()
    $ov = [LTK.Pwr]::GetOverlay()
    $ovName = if ($OverlayNames.ContainsKey($ov)) { $OverlayNames[$ov] } else { 'н/д' }
    if ($ac -eq 1) { $badgePower.Set('От сети', $cOk) }
    elseif ($ac -eq 0) { $badgePower.Set('От батареи', $cWarn) }
    else { $badgePower.Set('Питание: ?', $cDim) }
    $tone = if ($ov -eq $OV_PERF) { $accent } elseif ($ov -eq $OV_EFF) { $cOk } else { $cDim }
    $badgeMode.Set("Режим: $ovName", $tone)
    $hz = [LTK.Disp]::Current()
    $stateLbl.Text = "Экран: $hz Гц    ·    Отчёты: $ReportDir"
    $src = if ($ac -eq 1) { 'От сети' } elseif ($ac -eq 0) { 'От батареи' } else { '?' }
    $nowSt = if ($ac -eq 0 -and $ov -eq $OV_EFF) { 1 } elseif ($ac -eq 0) { 2 } else { 0 }
    Set-Row $script:NowRow $nowSt "$src · $hz Гц · $ovName"
    # источник питания сменился - обновить состояние на открытой странице
    if ($null -ne $script:LastAC -and $ac -ne $script:LastAC) {
        $script:Cache.Clear()
        if ($script:PageKey -and $script:PageKey -ne 'log') { Queue-Page $script:PageKey -Front }
    }
    $script:LastAC = $ac
}

function Update-Monitor {
    $ac = [LTK.Pwr]::OnAC()
    $p = $null
    try { $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop } catch { }
    if ($p) {
        $ghz = [math]::Round($MaxMHz * $p.PercentProcessorPerformance / 100 / 1000, 2)
        $load = [int]$p.PercentProcessorTime
        $sub = "$ghz ГГц"
        if ($script:StressJobs.Count) {
            $script:StressGHz.Add($ghz)
            $left_s = [int]($script:StressEnd - (Get-Date)).TotalSeconds
            $sub += "  ·  стресс-тест: ещё $([math]::Max(0, $left_s)) с"
            if ((Get-Date) -gt $script:StressEnd.AddSeconds(3)) { Stop-CpuStress -Finished }
        }
        $tileCpu.Set("$load %", $sub, $load, $(if ($load -ge 90) { $cWarn } else { $accent }))
    } else { $tileCpu.Set('н/д', 'счётчики недоступны', -1, $cDim) }

    $mem = [LTK.Win]::Memory()
    if ($mem[0]) {
        $tot = [math]::Round($mem[0] / 1GB, 1); $used = [math]::Round(($mem[0] - $mem[1]) / 1GB, 1)
        $pct = [int](($mem[0] - $mem[1]) * 100 / $mem[0])
        $tileRam.Set("$pct %", "$used из $tot ГБ", $pct, $(if ($pct -ge 85) { $cWarn } else { $accent }))
    }

    if ([LTK.Pwr]::HasBattery()) {
        $bp = [LTK.Pwr]::BatteryPercent()
        $sub = 'от сети'
        if ($ac -ne 1) {
            $parts = @()
            $sec = [LTK.Pwr]::BatterySeconds()
            if ($sec -gt 0) { $parts += "≈ $([int][math]::Floor($sec / 3600)) ч $([int](($sec % 3600) / 60)) мин" }
            if (-not $script:NoBatWmi) {
                try {
                    $bs = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
                    if ($bs.DischargeRate -gt 0) { $parts += "расход $([math]::Round($bs.DischargeRate / 1000, 1)) Вт" }
                } catch { $script:NoBatWmi = $true }
            }
            $sub = if ($parts.Count) { $parts -join '  ·  ' } else { 'от батареи' }
        }
        $col = if ($bp -lt 15) { $cErr } elseif ($bp -lt 30) { $cWarn } else { $cOk }
        $tileBat.Set($(if ($bp -ge 0) { "$bp %" } else { '?' }), $sub, $bp, $col)
    } else { $tileBat.Set('нет', 'батарея не найдена', -1, $cDim) }

    if ($ac -eq 0 -and $script:GpuMon) {
        $script:GpuMon = $false
        Set-Row $script:PeakRow 0 -Action 'Начать'
        Set-Status 'Слежение за видеокартой выключено: на батарее оно не даёт ей уснуть.' $cWarn
    }
    if (-not $Smi) { $tileGpu.Set('н/д', 'драйвер NVIDIA не найден', -1, $cDim) }
    elseif (-not $script:GpuMon) { $tileGpu.Set('не слежу', 'нажмите, чтобы включить (будит GPU)', -1, $cDim) }
    else {
        $q = @(& $Smi --query-gpu=temperature.gpu,utilization.gpu,power.draw,enforced.power.limit --format=csv,noheader,nounits 2>$null)
        if ($q.Count) {
            $v = "$($q[0])" -split ',\s*'
            $w = Num $v[2]
            if ($w -gt $script:GpuPeak) { $script:GpuPeak = $w }
            $val = if ($null -ne $w) { "$([math]::Round($w)) Вт" } else { "$($v[2]) Вт" }
            $tileGpu.Set($val, "$($v[0]) °C  ·  $($v[1]) %  ·  пик $([math]::Round($script:GpuPeak)) Вт", $(if ($w) { $w * 100 / 140 } else { 0 }), $accent)
            $pk = [math]::Round($script:GpuPeak)
            Set-Row $script:PeakRow $(if ($pk -ge 135) { 1 } elseif ($pk -ge 100) { 2 } else { 0 }) "пик $pk Вт · сейчас $val"
        } else { $tileGpu.Set('?', 'nvidia-smi не ответил', -1, $cWarn) }
    }
    Update-State
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    $timer.Stop()   # Out-Box вызывает DoEvents - не даём тику войти сам в себя
    try {
        if ($form.WindowState -eq 'Minimized') { return }   # свёрнуто - не тратим батарею на опрос
        $timer.Interval = if ([LTK.Pwr]::OnAC() -eq 0) { 5000 } else { 2000 }
        Update-Monitor
    } catch { Set-Status "Монитор: $($_.Exception.Message)" $cWarn }
    finally { $timer.Start() }
})

$form.Add_Shown({
    foreach ($c in @($box, $navFlow) + @($script:Pages.Values | ForEach-Object { $_.Flow })) { [LTK.UI.Theme]::DarkScroll($c) }
    $script:AgentOn = Test-AgentTask
    Show-Page 'home'
    try { Update-Monitor } catch { }
    # остальные страницы проверяются заранее, в фоне - к моменту перехода всё уже готово
    foreach ($k in @($script:Pages.Keys)) { if ($k -ne 'home') { Queue-Page $k } }
    $timer.Start()
    $loader.Start()
    Out-Box "Laptop Toolkit v$Version - журнал действий. Здесь появляются подробности проверок и изменений." $accent
})
$form.Add_FormClosing({
    $timer.Stop(); $loader.Stop()
    Get-Job | Stop-Job -ErrorAction SilentlyContinue
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
})

try { [void]$form.ShowDialog() }
finally { [Environment]::Exit(0) }
