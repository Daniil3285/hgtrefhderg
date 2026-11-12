# LaptopToolkit v3.2 - Skytech Noir (Ryzen 7 8845HS / DDR5-5600 / RTX 4070 Laptop до 140 Вт)
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
$Version = '3.2'

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

    // Карточка действия: значок, заголовок, описание.
    public class Card : Smooth
    {
        public string Title = "", Desc = "", Glyph = "";
        public bool Primary;
        public Font TitleFont, DescFont, GlyphFont;
        public Card() { Cursor = Cursors.Hand; }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            Color back = Primary ? Theme.Mix(Theme.Surface, Theme.Accent, 0.10f) : Theme.Surface;
            if (Hot) back = Theme.Mix(back, Theme.Accent, 0.08f);
            if (Pressed) back = Theme.Mix(back, Theme.Accent, 0.18f);
            Color line = Hot ? Theme.Accent : (Primary ? Theme.Mix(Theme.Border, Theme.Accent, 0.55f) : Theme.Border);
            Theme.FillRound(g, new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.S(10), back, line);

            int pad = Theme.S(14), ic = Theme.S(40);
            Rectangle icr = new Rectangle(pad, pad, ic, ic);
            Theme.FillRound(g, icr, Theme.S(10), Primary ? Theme.Accent : Theme.Mix(Theme.Surface2, Theme.Accent, 0.16f), Color.Empty);
            Draw(g, Glyph, GlyphFont, icr, Primary ? Theme.Bg : Theme.Accent,
                 TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);

            int tx = pad + ic + Theme.S(12), tw = Width - tx - pad;
            int th = TitleFont != null ? TitleFont.Height : Theme.S(20);
            Rectangle tr = new Rectangle(tx, pad, tw, th);
            Draw(g, Title, TitleFont, tr, Theme.Fore, TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            Rectangle dr = new Rectangle(tx, tr.Bottom + Theme.S(3), tw, Height - tr.Bottom - Theme.S(3) - Theme.S(10));
            Draw(g, Desc, DescFont, dr, Theme.Dim, TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.TextBoxControl);
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
        public bool Selected;
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
$main.Dock = 'Fill'; $main.BackColor = $bg; $main.Padding = Pad 20 16 20 16

$tiles = New-Object Windows.Forms.TableLayoutPanel
$tiles.Dock = 'Top'; $tiles.Height = Px 112; $tiles.ColumnCount = 4; $tiles.RowCount = 1; $tiles.BackColor = $bg
$tiles.Margin = Pad 0 0 0 0; $tiles.Padding = Pad 0 0 0 0
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

$pageHead = New-Object Windows.Forms.Panel
$pageHead.Dock = 'Top'; $pageHead.Height = Px 74; $pageHead.BackColor = $bg
$pageTitle = New-Object Windows.Forms.Label
$pageTitle.Font = $fPage; $pageTitle.ForeColor = $fg; $pageTitle.AutoSize = $true
$pageTitle.Location = New-Object Drawing.Point(0, (Px 16))
$pageDesc = New-Object Windows.Forms.Label
$pageDesc.Font = $fUi; $pageDesc.ForeColor = $cDim; $pageDesc.AutoSize = $true
$pageDesc.Location = New-Object Drawing.Point((Px 2), (Px 48))
$pageHead.Controls.AddRange(@($pageTitle, $pageDesc))

$cards = New-Object Windows.Forms.FlowLayoutPanel
$cards.Dock = 'Top'; $cards.Height = Px 100; $cards.BackColor = $bg
$cards.WrapContents = $true; $cards.Margin = Pad 0 0 0 0; $cards.Padding = Pad 0 0 0 0

$logCard = New-Object LTK.UI.RoundPanel
$logCard.Dock = 'Fill'; $logCard.Padding = Pad 16 8 6 10
$logHead = New-Object Windows.Forms.Panel
$logHead.Dock = 'Top'; $logHead.Height = Px 38; $logHead.BackColor = $panel
$logTitle = New-Object Windows.Forms.Label
$logTitle.Text = 'Журнал'; $logTitle.Font = $fSemi; $logTitle.ForeColor = $fg; $logTitle.AutoSize = $true
$logTitle.Location = New-Object Drawing.Point(0, (Px 8))
$logTools = New-Object Windows.Forms.FlowLayoutPanel
$logTools.Dock = 'Right'; $logTools.Width = Px 420; $logTools.FlowDirection = 'RightToLeft'; $logTools.WrapContents = $false
$logTools.BackColor = $panel; $logTools.Padding = Pad 0 3 8 0
function New-Chip([string]$text, [double]$w, [switch]$Primary) {
    $c = New-Object LTK.UI.Chip
    $c.Text = $text; $c.Size = Sz $w 30; $c.Font = $fSmall; $c.Primary = [bool]$Primary; $c.Margin = Pad 6 0 0 0
    $c
}
$chipClear = New-Chip 'Очистить' 96
$chipFolder = New-Chip 'Папка отчётов' 124
$chipSave = New-Chip 'Сохранить отчёт' 140
$logTools.Controls.AddRange(@($chipClear, $chipFolder, $chipSave))
$logHead.Controls.AddRange(@($logTitle, $logTools))

$box = New-Object Windows.Forms.RichTextBox
$box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.DetectUrls = $false
$box.Dock = 'Fill'; $box.BackColor = $panel; $box.ForeColor = $fg
$box.Font = $fMono
$box.BorderStyle = 'None'
$logCard.Controls.Add($box)
$logCard.Controls.Add($logHead)

$gap1 = New-Object Windows.Forms.Panel
$gap1.Dock = 'Top'; $gap1.Height = Px 6; $gap1.BackColor = $bg

# порядок добавления важен для Dock: последний добавленный прижимается первым
$main.Controls.Add($logCard)
$main.Controls.Add($gap1)
$main.Controls.Add($cards)
$main.Controls.Add($pageHead)
$main.Controls.Add($tiles)

$form.Controls.Add($main)
$form.Controls.Add($nav)
$form.Controls.Add($bottom)
$form.Controls.Add($header)

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
function Head([string]$t) { Out-Box @('', "■ $t") $accent }
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
    $statusLbl.ForeColor = $accent
    $statusLbl.Text = "● Выполняется: $name..."
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try { & $action }
    catch { Out-Box "ОШИБКА [$name]: $($_.Exception.Message)" }
    finally {
        $script:Busy = $false; $script:Cat = $null
        $form.Cursor = [Windows.Forms.Cursors]::Default
        $statusLbl.ForeColor = $cDim
        $statusLbl.Text = "Готово: $name"
    }
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
function Test-AgentTask {
    try { return [bool](Get-ScheduledTask -TaskName 'PowerAgent' -TaskPath '\LaptopToolkit\' -ErrorAction Stop) } catch { return $false }
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
    $dlg.Size = Sz 760 780; $dlg.MinimumSize = Sz 560 440
    $dlg.BackColor = $bg; $dlg.ForeColor = $fg; $dlg.ShowInTaskbar = $false; $dlg.MinimizeBox = $false
    $dlg.Font = $fUi
    $dlg.Add_HandleCreated({ param($s, $e) [LTK.UI.Theme]::DarkTitle($s.Handle, $panel) })

    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Height = Px 92; $head.BackColor = $panel
    $ht = New-Object Windows.Forms.Label
    $ht.Text = $title; $ht.Font = $fTitle; $ht.ForeColor = $fg; $ht.AutoSize = $true
    $ht.Location = New-Object Drawing.Point((Px 20), (Px 12))
    $hi = New-Object Windows.Forms.Label
    $hi.Text = $intro; $hi.ForeColor = $cDim; $hi.Font = $fSmall
    $hi.Location = New-Object Drawing.Point((Px 21), (Px 46)); $hi.Size = Sz 700 42
    $head.Controls.AddRange(@($ht, $hi))

    $flow = New-Object Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
    $flow.Padding = Pad 20 4 12 14; $flow.BackColor = $bg
    $w = Px 670
    $script:OptBoxes = New-Object Collections.ArrayList
    $grp = $null
    foreach ($it in $items) {
        if ($it.Group -and $it.Group -ne $grp) {
            $grp = $it.Group
            $gl = New-Object Windows.Forms.Label
            $gl.Text = $grp.ToUpper(); $gl.ForeColor = $accent; $gl.AutoSize = $true
            $gl.Font = $fTileCap
            $gl.Margin = Pad 0 16 0 2
            $flow.Controls.Add($gl)
        }
        $cb = New-Object Windows.Forms.CheckBox
        $cb.Text = $it.Text; $cb.Checked = [bool]$it.On; $cb.Tag = $it.Key
        $cb.Font = $fSemi; $cb.ForeColor = $fg; $cb.Cursor = [Windows.Forms.Cursors]::Hand
        # AutoSize не переносит длинные строки - высоту считаем сами
        $txtSize = [Windows.Forms.TextRenderer]::MeasureText($it.Text, $fSemi, (New-Object Drawing.Size(($w - (Px 30)), 0)), [Windows.Forms.TextFormatFlags]::WordBreak)
        $cb.AutoSize = $false; $cb.Width = $w; $cb.Height = $txtSize.Height + (Px 6)
        $cb.CheckAlign = 'TopLeft'; $cb.TextAlign = 'TopLeft'
        $cb.FlatStyle = 'Flat'
        $cb.FlatAppearance.BorderColor = $accent
        $cb.FlatAppearance.CheckedBackColor = [LTK.UI.Theme]::Mix($bg, $accent, 0.35)
        $cb.FlatAppearance.MouseOverBackColor = $panel2
        $cb.Margin = Pad 0 8 0 0
        $flow.Controls.Add($cb)
        [void]$script:OptBoxes.Add($cb)
        if ($it.Hint) {
            $h = New-Object Windows.Forms.Label
            $h.Text = $it.Hint; $h.ForeColor = $cDim; $h.AutoSize = $true; $h.Font = $fSmall
            $h.MaximumSize = New-Object Drawing.Size(($w - (Px 22)), 0)
            $h.Margin = Pad 20 1 0 2
            $flow.Controls.Add($h)
        }
    }

    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = Px 60; $bar.BackColor = $panel
    $bar.FlowDirection = 'RightToLeft'; $bar.Padding = Pad 12 13 10 0
    $ok = New-Chip $okText 150 -Primary; $ok.Height = Px 34; $ok.Font = $fSemi
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = New-Chip 'Отмена' 110; $cancel.Height = Px 34
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $all = New-Chip 'Отметить всё' 130; $all.Height = Px 34
    $all.Add_Click({ foreach ($c in $script:OptBoxes) { $c.Checked = $true } })
    $none = New-Chip 'Снять всё' 110; $none.Height = Px 34
    $none.Add_Click({ foreach ($c in $script:OptBoxes) { $c.Checked = $false } })
    $bar.Controls.AddRange(@($ok, $cancel, $none, $all))

    $dlg.Controls.Add($flow); $dlg.Controls.Add($head); $dlg.Controls.Add($bar)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Add_Shown({ param($s, $e) [LTK.UI.Theme]::DarkScroll($flow) })
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
        '  2. Если пункта нет - переключатель GPU / MUX / Hybrid в фирменной утилите ноутбука (Control Center)',
        '     или в BIOS (обычно Advanced -> Display / Graphics Mode -> Hybrid, MSHybrid или Optimus).',
        '  3. Внешний монитор через HDMI обычно подключён прямо к RTX 4070 - на батарее отключайте его.',
        '  Для игр от сети можно снова включить «Только дискретная» - это +5..15% FPS.'
}

function Do-HybridHelp {
    Head 'РЕЖИМ ГРАФИКИ'
    $mode = Get-GraphicsMode
    Out-Box "Сейчас: $(Get-GraphicsModeText)"
    if ($mode -eq 'hybrid') { Out-Ok 'Всё правильно: на батарее RTX 4070 спит, пока не запущена игра.'; return }
    Show-HybridHelp
    if ($mode -ne 'external' -and (Ask-User 'Открыть Панель управления NVIDIA, чтобы переключить режим дисплея?' 'Режим графики')) { Open-NvidiaPanel }
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
        'disabled' { Out-Box '  [!] Dynamic Boost отключён в Диспетчере устройств - кнопка «140 Вт: разблокировать» включит его.' }
        'missing'  { Out-Box '  [!] Dynamic Boost: устройство «NVIDIA Platform Controllers and Framework» не найдено - видеокарта ограничена ~115 Вт.'; Show-DbHelp }
        default {
            $why = if ($script:DbState -eq 'nodriver') { 'у устройства нет драйвера' } else { "ошибка устройства ($($script:DbState))" }
            Out-Box "  [!] Dynamic Boost НЕ РАБОТАЕТ: $why. Пока это так, видеокарта не поднимется выше 115 Вт."
            if (-not $Fix) { Out-Box '      Кнопка «140 Вт: разблокировать» попробует установить драйвер сама.' }
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
    if ($script:DbState -ne 'ok' -and (Ask-User ("Dynamic Boost не заработал автоматически - без него видеокарта ограничена 115 Вт.`n`n" +
            "Открыть «Необязательные обновления» Windows и страницу драйверов NVIDIA?`n" +
            "Порядок действий - в журнале программы («КАК ПОЧИНИТЬ»).") 'Dynamic Boost')) {
        Start-Process 'ms-settings:windowsupdate-optionalupdates'
        Start-Process 'https://www.nvidia.com/drivers/'
    }
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
    $script:GpuMon = $true
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
    if (-not $sel.Count) { Out-Box 'Ничего не выбрано - отметьте нужные пункты галочками и нажмите «Применить».'; return }

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
    $mode = Get-GraphicsMode
    if ($mode -eq 'dgpu' -or $mode -eq 'external') {
        Out-Box '', "!!! $(Get-GraphicsModeText)."
        Out-Box '    Это главный расход батареи - все настройки выше дадут намного меньше, пока это так.'
        Show-HybridHelp
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
    if (-not $sel.Count) { Out-Box 'Ничего не выбрано - отметьте нужные пункты галочками и нажмите «Применить».'; return }
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

function Find-Afterburner {
    $c = @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe")
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Afterburner',
                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Afterburner') {
        $loc = (Get-ItemProperty $k -ErrorAction SilentlyContinue).InstallLocation
        if ($loc) { $c += Join-Path $loc 'MSIAfterburner.exe' }
    }
    $c | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Do-Afterburner {
    $p = Find-Afterburner
    if ($p) { Start-Process $p; Out-Box 'MSI Afterburner запущен.'; return }
    if (-not (Ask-User 'MSI Afterburner не установлен. Установить сейчас (winget, официальный пакет) и сразу запустить?' 'MSI Afterburner')) { return }
    if (-not (Test-Winget)) { return }
    $p86 = "${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe"
    Start-Console 'Установка MSI Afterburner' ("winget install -e --id Guru3D.Afterburner --accept-package-agreements --accept-source-agreements; " +
        "if (Test-Path '$p86') { Start-Process '$p86' } else { Write-Host 'Если установка прошла - запустите Afterburner из меню Пуск.' }")
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

# ---------------- РАЗДЕЛЫ И КАРТОЧКИ ----------------
$script:Pages = [ordered]@{}
$script:NavItems = @{}
$script:PageKey = $null

function Add-Page([string]$key, [string]$title, [string]$desc) {
    $script:Pages[$key] = @{ Title = $title; Desc = $desc; Cards = (New-Object Collections.ArrayList) }
    $n = New-Object LTK.UI.NavItem
    $n.Text = $title; $n.Glyph = Ico $key; $n.GlyphFont = $fIconNav; $n.Font = $fUi
    $n.Size = Sz 208 42; $n.Margin = Pad 0 0 0 3; $n.Tag = $key
    $n.Add_Click({ param($s, $e) Show-Page $s.Tag })
    $navFlow.Controls.Add($n)
    $script:NavItems[$key] = $n
    $script:CurPage = $key
}

# Карточка добавляется в текущий раздел (последний Add-Page) и, с -Home, на главную.
function Add-Card([string]$title, [string]$desc, [scriptblock]$action, [switch]$Primary, [string]$Page = $script:CurPage) {
    $c = New-Object LTK.UI.Card
    $c.Title = $title; $c.Desc = $desc; $c.Primary = [bool]$Primary
    $c.Glyph = Ico $Page; $c.GlyphFont = $fIcon; $c.TitleFont = $fSemi; $c.DescFont = $fSmall
    $c.Tag = @{ Name = $title; Action = $action }
    $c.Add_Click({ param($s, $e) Invoke-Safe $s.Tag.Name $s.Tag.Action })
    [void]$script:Pages[$Page].Cards.Add($c)
}

function Update-CardLayout {
    if ($script:InLayout) { return }
    $script:InLayout = $true
    try {
        $list = @($cards.Controls)
        $n = $list.Count
        if (-not $n) { $cards.Height = 0; return }
        $W = $cards.ClientSize.Width
        $gap = Px 12; $ch = Px 88
        $cols = [int][math]::Max(1, [math]::Min($n, [math]::Floor(($W + $gap) / ((Px 290) + $gap))))
        $cw = [int][math]::Floor(($W - $gap * ($cols - 1)) / $cols) - 1
        for ($i = 0; $i -lt $n; $i++) {
            $list[$i].Size = New-Object Drawing.Size($cw, $ch)
            $right = if (($i % $cols) -eq ($cols - 1)) { 0 } else { $gap }
            $list[$i].Margin = New-Object Windows.Forms.Padding(0, 0, $right, $gap)
        }
        $cards.Height = [int]([math]::Ceiling($n / $cols) * ($ch + $gap))
    } finally { $script:InLayout = $false }
}

function Show-Page([string]$key) {
    if ($script:PageKey -eq $key) { return }
    $script:PageKey = $key
    foreach ($k in $script:NavItems.Keys) { $script:NavItems[$k].Selected = ($k -eq $key); $script:NavItems[$k].Invalidate() }
    $p = $script:Pages[$key]
    $pageTitle.Text = $p.Title
    $pageDesc.Text = $p.Desc
    $main.SuspendLayout()
    $cards.Controls.Clear()
    $cards.Controls.AddRange([Windows.Forms.Control[]]@($p.Cards))
    Update-CardLayout
    $main.ResumeLayout()
}
$cards.Add_SizeChanged({ Update-CardLayout })

Add-Page 'home' 'Главная' 'Самое важное для этого ноутбука - по порядку, сверху вниз.'
Add-Card 'Полная проверка' 'Все проверки подряд и отчёт в папку LaptopToolkit на рабочем столе.' { Do-Full } -Primary
Add-Card '140 Вт: разблокировать' 'Полная мощность RTX 4070 от сети: Dynamic Boost, службы NVIDIA, режим Windows.' { Do-Gpu140 } -Primary
Add-Card 'Оптимизация Windows' 'Игры, приватность, реклама, лишние приложения - выбор галочками.' { Do-WinOptimize } -Primary
Add-Card 'Максимальная автономность' 'Только на батарее: 60 Гц, без турбобуста, экономия, сон. От сети - на полную.' { Do-BatteryOptimize } -Primary
Add-Card 'Точка восстановления' 'Снимок системы перед изменениями. Откат: Win+R -> rstrui.' { Do-Restore }
Add-Card 'Состояние питания сейчас' 'Источник, режим Windows, частота экрана и все настройки батареи.' { Do-PowerStatus }

Add-Page 'diag' 'Диагностика' 'Проверка железа и системы. Ничего не меняет.'
Add-Card 'Полная проверка' 'Все проверки подряд и сохранение отчёта.' { Do-Full } -Primary
Add-Card 'Система и процессор' 'Модель, Windows, BIOS, Secure Boot, TPM, VBS.' { Do-System }
Add-Card 'Оперативная память' 'Планки, частота, одноканальный режим.' { Do-Ram }
Add-Card 'Видеокарта' 'Драйвер, частоты, температура, лимиты мощности.' { Do-Gpu }
Add-Card 'Диски и SSD' 'Здоровье, износ, температура, свободное место, TRIM.' { Do-Disk }
Add-Card 'Батарея' 'Износ, ёмкость, циклы и подробный HTML-отчёт Windows.' { Do-Battery }
Add-Card 'Проблемные драйверы' 'Устройства с ошибками в Диспетчере устройств.' { Do-Drivers }
Add-Card 'Журнал сбоев' 'Синие экраны, WHEA, сбои видеодрайвера за 30 дней.' { Do-Events }

Add-Page 'gpu' 'Видеокарта 140 Вт' 'RTX 4070 Laptop: 115 Вт база + 25 Вт Dynamic Boost. Только от сети. vBIOS не трогается.'
Add-Card '140 Вт: разблокировать' 'Включает Dynamic Boost и службы NVIDIA, режим «Максимальная производительность» от сети.' { Do-Gpu140 } -Primary
Add-Card 'Проверить мощность' 'Лимиты, Dynamic Boost и режимы - только показывает, ничего не меняет.' { Do-GpuCheck }
Add-Card 'Замер пиковой мощности' 'Включает слежение за GPU и запоминает пик ватт, пока вы играете.' { Do-GpuPeak }
Add-Card 'Что держит видеокарту' 'Какие программы не дают RTX 4070 уснуть.' { Do-GpuHolders }
Add-Card 'Режим графики' 'Гибрид (Optimus) или только RTX 4070: проверка и как переключить.' { Do-HybridHelp }

Add-Page 'battery' 'Батарея' 'Всё, что продлевает работу без зарядки. Действует только на батарее.'
Add-Card 'Максимальная автономность' '60 Гц, без турбобуста, экономия энергии, сон, устройства - галочками.' { Do-BatteryOptimize } -Primary
Add-Card 'Состояние питания сейчас' 'Источник, режим Windows, частота экрана и все настройки батареи.' { Do-PowerStatus }
Add-Card 'Что не даёт видеокарте уснуть' 'Программы, которые будят RTX 4070 и садят батарею.' { Do-GpuHolders }
Add-Card 'Режим графики' 'Гибридный или только дискретная: главное для батареи. Подскажет, как переключить.' { Do-HybridHelp }
Add-Card 'Энергоотчёт' '60 секунд наблюдения Windows: что мешает экономии энергии.' { Do-EnergyReport }
Add-Card 'Расход во сне' 'Sleep Study: сколько заряда ушло во сне и почему.' { Do-SleepStudy }
Add-Card 'Журнал автопереключения' 'Когда и что переключалось при подключении и отключении зарядки.' { Do-AgentLog }
Add-Card 'Откатить настройки батареи' 'Вернуть всё, что изменила «Максимальная автономность».' { Do-BatteryUndo }

Add-Page 'windows' 'Оптимизация Windows' 'Быстрее и тише: без рекламы, телеметрии и лишнего. Всё откатывается.'
Add-Card 'Оптимизация Windows' 'Игры, приватность, реклама, мусорные приложения - выбор галочками.' { Do-WinOptimize } -Primary
Add-Card 'Точка восстановления' 'Снимок системы перед изменениями.' { Do-Restore }
Add-Card 'Автозагрузка программ' 'Диспетчер задач: отключить лишнее при включении.' { Do-Startup }
Add-Card 'Очистка диска' 'Временные файлы, корзина и старые обновления.' { Do-Cleanup }
Add-Card 'Ремонт Windows' 'DISM + SFC: восстановление системных файлов.' { Do-Repair }
Add-Card 'Обновить всё' 'Программы через winget и Центр обновления Windows.' { Do-Update }
Add-Card 'Драйверы NVIDIA и AMD' 'Официальные страницы драйверов видеокарты и чипсета.' { Do-DriversWeb }
Add-Card 'Chris Titus WinUtil' 'Сторонняя утилита твиков. Не отключайте в ней службы NVIDIA.' { Do-WinUtil }
Add-Card 'Откатить оптимизацию' 'Вернуть всё, что изменила «Оптимизация Windows» (кроме удалённых приложений).' { Do-WinUndo }

Add-Page 'security' 'Безопасность' 'Антивирус, подозрительная автозагрузка и проверки Защитником.'
Add-Card 'Статус антивируса' 'Защитник, базы, история угроз, исключения.' { Do-AvStatus } -Primary
Add-Card 'Поиск подозрительного' 'Автозагрузка, задачи, службы, процессы, hosts, прокси.' { Do-Suspicious }
Add-Card 'Быстрая проверка' 'Защитник Windows: обновить базы и проверить.' { Do-QuickScan }
Add-Card 'Полная проверка' 'Все диски, 1-3 часа.' { Do-FullScan }
Add-Card 'Автономная проверка' 'До загрузки Windows, ловит руткиты. Перезагрузка.' { Do-OfflineScan }
Add-Card 'Microsoft Safety Scanner' 'Официальный одноразовый сканер Microsoft.' { Do-Msert }
Add-Card 'Второе мнение (KVRT)' 'Бесплатный сканер Kaspersky без установки.' { Do-Kvrt }

Add-Page 'tests' 'Тесты' 'Нагрузка и проверка стабильности. Подключите зарядку.'
Add-Card 'Стресс CPU 1 мин' 'Быстрая проверка частот и охлаждения.' { Start-CpuStress 60 }
Add-Card 'Стресс CPU 10 мин' 'Длительная нагрузка: троттлинг и стабильность.' { Start-CpuStress 600 }
Add-Card 'Остановить стресс' 'Прервать тест и показать итог.' { Stop-CpuStress }
Add-Card 'Тест памяти' 'Средство проверки памяти Windows. Перезагрузка.' { Do-RamTest }
Add-Card 'Скорость диска' 'Встроенный тест winsat.' { Do-DiskSpeed }

Add-Page 'oc' 'Разгон' 'Андервольт и разгон RTX 4070 через MSI Afterburner.'
Add-Card 'Гайд по разгону' 'Пошагово: частоты, память, андервольт.' { Do-OcGuide } -Primary
Add-Card 'Установить утилиты' 'HWiNFO, Afterburner, OCCT, FurMark и другие через winget.' { Do-Tools }
Add-Card 'Запустить Afterburner' 'Открыть MSI Afterburner, если установлен.' { Do-Afterburner }

Add-Page 'install' 'Переустановка' 'Чистая Windows вместо «сборок» - пошагово.'
Add-Card 'Как поставить чистую Windows' 'План переустановки и что сохранить заранее.' { Do-WinGuide } -Primary
Add-Card 'Бэкап драйверов' 'Сохранить все драйверы в папку отчётов.' { Do-DriverBackup }
Add-Card 'Скачать Windows 11' 'Официальная страница Microsoft.' { Start-Process 'https://www.microsoft.com/software-download/windows11'; Out-Box 'Открыт сайт Microsoft.' }

$chipSave.Add_Click({ Invoke-Safe 'Сохранить отчёт' { Do-Save } })
$chipFolder.Add_Click({ Start-Process explorer.exe $ReportDir })
$chipClear.Add_Click({ $box.Clear(); [void]$script:Log.Clear() })

# ---------------- МОНИТОР ----------------
$script:GpuMon = $false
$tileGpu.Add_Click({
    if (-not $script:GpuMon -and [LTK.Pwr]::OnAC() -eq 0) {
        $statusLbl.Text = 'На батарее слежение за GPU не включается: оно будит видеокарту.'
        return
    }
    $script:GpuMon = -not $script:GpuMon
    Update-Monitor
})

function Update-State {
    $ac = [LTK.Pwr]::OnAC()
    $ov = [LTK.Pwr]::GetOverlay()
    $ovName = if ($OverlayNames.ContainsKey($ov)) { $OverlayNames[$ov] } else { 'н/д' }
    if ($ac -eq 1) { $badgePower.Set('От сети', $cOk) }
    elseif ($ac -eq 0) { $badgePower.Set('От батареи', $cWarn) }
    else { $badgePower.Set('Питание: ?', $cDim) }
    $tone = if ($ov -eq $OV_PERF) { $accent } elseif ($ov -eq $OV_EFF) { $cOk } else { $cDim }
    $badgeMode.Set("Режим: $ovName", $tone)
    $agent = if ($script:AgentOn) { 'вкл' } else { 'выкл' }
    $stateLbl.Text = "Экран: $([LTK.Disp]::Current()) Гц    ·    Автопереключение: $agent    ·    Отчёты: $ReportDir"
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
        Out-Dim 'Слежение за GPU выключено: на батарее оно не даёт видеокарте уснуть.'
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
    } catch { $statusLbl.Text = "Монитор: $($_.Exception.Message)" }
    finally { $timer.Start() }
})

$form.Add_Shown({
    foreach ($c in $box, $navFlow) { [LTK.UI.Theme]::DarkScroll($c) }
    $script:AgentOn = Test-AgentTask
    Show-Page 'home'
    try { Update-Monitor } catch { }
    $timer.Start()
    Out-Box "Laptop Toolkit v$Version" $accent
    Out-Box 'С чего начать - раздел «Главная», карточки сверху вниз:',
        '  1. «Полная проверка» - отчёт сохранится в папку LaptopToolkit на рабочем столе.',
        '  2. «140 Вт: разблокировать» - полная мощность RTX 4070 от сети.',
        '  3. «Оптимизация Windows» и «Максимальная автономность» - быстрее от сети, дольше от батареи.',
        'Плитка «Видеокарта» сверху включает слежение за GPU.'
    Invoke-Safe 'Система' { Do-System; Do-Ram }
})
$form.Add_FormClosing({
    $timer.Stop()
    Get-Job | Stop-Job -ErrorAction SilentlyContinue
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
})

try { [void]$form.ShowDialog() }
finally { [Environment]::Exit(0) }
