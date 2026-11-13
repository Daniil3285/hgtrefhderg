// Laptop Toolkit - запускатель. Программа (LaptopToolkit.ps1) встроена в exe как ресурс:
// exe распаковывает её в %ProgramData%\LaptopToolkit\app (запись только для администраторов)
// и запускает встроенный в Windows PowerShell 5.1 без окна консоли.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Laptop Toolkit")]
[assembly: AssemblyDescription("Laptop Toolkit - Skytech Noir")]
[assembly: AssemblyProduct("Laptop Toolkit")]
[assembly: AssemblyVersion("5.0.0.0")]
[assembly: AssemblyFileVersion("5.0.0.0")]

static class Program
{
    static void Fail(string text)
    {
        MessageBox.Show(text, "Laptop Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    [STAThread]
    static int Main()
    {
        string dir, ps1;
        try
        {
            dir = Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "LaptopToolkit"), "app");
            Directory.CreateDirectory(dir);
            ps1 = Path.Combine(dir, "LaptopToolkit.ps1");

            byte[] data;
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("LaptopToolkit.ps1"))
            using (MemoryStream ms = new MemoryStream())
            {
                s.CopyTo(ms);
                data = ms.ToArray();
            }
            bool same = File.Exists(ps1);
            if (same)
            {
                byte[] old = File.ReadAllBytes(ps1);
                same = old.Length == data.Length;
                for (int i = 0; same && i < old.Length; i++) same = old[i] == data[i];
            }
            if (!same) File.WriteAllBytes(ps1, data);
        }
        catch (Exception ex)
        {
            Fail("Не удалось подготовить программу:\n" + ex.Message + "\n\nЗапустите от имени администратора.");
            return 1;
        }

        // 64-битный PowerShell даже если exe вдруг запущен как 32-битный процесс.
        string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string ps = Path.Combine(win, @"Sysnative\WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps)) ps = Path.Combine(win, @"System32\WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps)) { Fail("Не найден Windows PowerShell:\n" + ps); return 1; }

        ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardError = true;
        psi.RedirectStandardOutput = true;
        psi.WorkingDirectory = dir;
        psi.EnvironmentVariables["LTK_EXE"] = Application.ExecutablePath;

        StringBuilder err = new StringBuilder();
        try
        {
            using (Process p = Process.Start(psi))
            {
                p.ErrorDataReceived += delegate(object o, DataReceivedEventArgs e) { if (e.Data != null) lock (err) err.AppendLine(e.Data); };
                p.OutputDataReceived += delegate(object o, DataReceivedEventArgs e) { };
                p.BeginErrorReadLine();
                p.BeginOutputReadLine();
                p.WaitForExit();
                if (p.ExitCode != 0 && err.Length > 0)
                {
                    string log = Path.Combine(dir, "error.log");
                    try { File.WriteAllText(log, err.ToString(), Encoding.UTF8); } catch { }
                    string text = err.ToString();
                    if (text.Length > 1500) text = text.Substring(0, 1500) + "...";
                    Fail("Программа завершилась с ошибкой:\n\n" + text + "\n\nПолный текст: " + log);
                    return p.ExitCode;
                }
            }
        }
        catch (Exception ex)
        {
            Fail("Не удалось запустить PowerShell:\n" + ex.Message);
            return 1;
        }
        return 0;
    }
}
