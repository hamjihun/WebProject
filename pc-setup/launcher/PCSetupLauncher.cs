// 사내 PC 자동 셋팅 - 실행 파일(PCSetup.exe)
// - 프로그램 본체(PCSetup.ps1)와 기본 설정(config.json)을 exe 안에 담고 있다가 실행 시 꺼내서 실행
// - config.json, logs 는 exe 옆에 둠 (USB 에 exe 하나만 두고 써도 됨)
// - 관리자 권한이 없으면 관리자 권한으로 다시 실행
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

[assembly: AssemblyTitle("사내 PC 자동 셋팅")]
[assembly: AssemblyProduct("PC Setup")]
[assembly: AssemblyVersion("1.0.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string exePath = Process.GetCurrentProcess().MainModule.FileName;
        string exeDir = Path.GetDirectoryName(exePath);
        string passArgs = string.Join(" ", args);

        try
        {
            if (!IsAdmin())
            {
                var psi = new ProcessStartInfo(exePath, passArgs) { UseShellExecute = true, Verb = "runas" };
                try { Process.Start(psi); }
                catch (System.ComponentModel.Win32Exception) { /* 관리자 권한 요청을 취소함 */ }
                return 0;
            }

            // 기본 설정이 없으면 exe 옆에 만들어 둠 (이후에는 이 파일을 수정해서 사용)
            string config = Path.Combine(exeDir, "config.json");
            if (!File.Exists(config)) Extract("config.json", config);

            // 프로그램 본체는 매번 임시 폴더에 새로 꺼냄
            string work = Path.Combine(Path.GetTempPath(), "PCSetup");
            Directory.CreateDirectory(work);
            string script = Path.Combine(work, "PCSetup.ps1");
            Extract("PCSetup.ps1", script);

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            string arguments = string.Format(
                "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"{0}\" -RootDir \"{1}\" -LauncherExe \"{2}\" {3}",
                script, exeDir.TrimEnd('\\'), exePath, passArgs);
            var start = new ProcessStartInfo(ps, arguments) { UseShellExecute = false, CreateNoWindow = true };
            Process.Start(start);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("실행하지 못했습니다.\n\n" + ex.Message, "사내 PC 자동 셋팅", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static bool IsAdmin()
    {
        return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    }

    static void Extract(string name, string target)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (s == null) throw new Exception("내장 파일을 찾을 수 없습니다: " + name);
            using (FileStream f = File.Create(target)) s.CopyTo(f);
        }
    }
}
