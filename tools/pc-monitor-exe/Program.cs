using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace PCMonitor
{
    internal static class Program
    {
        [STAThread]
        static void Main()
        {
            using (var mutex = new Mutex(true, "Local\\PCMonitor_SingleInstance", out bool first))
            {
                if (!first)
                {
                    MessageBox.Show("PC 모니터가 이미 실행 중입니다.\n화면 오른쪽 아래 알림 영역(시계 옆 ^)에서 아이콘을 확인하세요.",
                        "PC 모니터", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
            }
        }
    }

    internal class TrayApp : ApplicationContext
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "PCMonitor";

        readonly Settings _cfg;
        readonly Monitor _mon;
        readonly NotifyIcon _tray;
        readonly Icon[] _icons;
        readonly Control _ui = new Control();
        readonly ToolStripMenuItem _autoStart;
        int _level = -1;
        StatusForm _status;

        public TrayApp()
        {
            var _ = _ui.Handle; // UI 스레드 핸들 생성 (백그라운드 → UI 호출용)
            _cfg = Settings.Load();
            _mon = new Monitor(_cfg);
            _icons = new[] { MakeIcon(Color.FromArgb(46, 160, 67)), MakeIcon(Color.FromArgb(219, 160, 0)), MakeIcon(Color.FromArgb(207, 34, 46)) };

            var menu = new ContextMenuStrip();
            menu.Items.Add("현재 상태 보기", null, (s, e) => ShowStatus());
            menu.Items.Add("멈춤 기록 보기 (엑셀)", null, (s, e) => Open(_mon.SummaryFile, "아직 기록된 멈춤이 없습니다."));
            menu.Items.Add("오늘 상세 분석 보기", null, (s, e) => Open(_mon.EventFile, "오늘 기록이 아직 없습니다."));
            menu.Items.Add("기록 폴더 열기", null, (s, e) => Open(_cfg.LogDir, null));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("설정 (ERP 프로그램 이름 등)", null, (s, e) => Open(Settings.IniPath, null));
            _autoStart = new ToolStripMenuItem("Windows 시작 시 자동 실행") { Checked = IsAutoStart() };
            _autoStart.Click += (s, e) => { SetAutoStart(!_autoStart.Checked); _autoStart.Checked = IsAutoStart(); };
            menu.Items.Add(_autoStart);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("종료", null, (s, e) => ExitApp());

            _tray = new NotifyIcon { Icon = _icons[0], Text = "PC 모니터 - 시작 중", ContextMenuStrip = menu, Visible = true };
            _tray.DoubleClick += (s, e) => ShowStatus();

            _mon.Updated += s => { try { _ui.BeginInvoke(new Action(() => OnSample(s))); } catch { } };
            SystemEvents.PowerModeChanged += (s, e) => { if (e.Mode == PowerModes.Resume) _mon.LastResume = DateTime.Now; };

            var th = new Thread(() =>
            {
                try { _mon.Run(); }
                catch (Exception ex)
                {
                    _mon.LogError(ex);
                    _ui.BeginInvoke(new Action(() => MessageBox.Show("모니터링 중 오류가 발생했습니다.\n" + ex.Message, "PC 모니터", MessageBoxButtons.OK, MessageBoxIcon.Error)));
                }
            }) { IsBackground = true, Priority = ThreadPriority.AboveNormal, Name = "monitor" };
            th.Start();

            if (_cfg.IsNew)
            {
                if (MessageBox.Show(
                        "PC 모니터를 처음 실행했습니다.\n\n" +
                        "· 화면 오른쪽 아래 알림 영역에 아이콘으로 실행됩니다.\n" +
                        "· 프로그램이 '응답 없음'으로 멈추면 원인을 자동으로 분석해 기록합니다.\n" +
                        "· 기록 위치: " + _cfg.LogDir + "\n\n" +
                        "Windows를 켤 때 자동으로 실행할까요? (권장)",
                        "PC 모니터", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                {
                    SetAutoStart(true);
                    _autoStart.Checked = IsAutoStart();
                }
                if (MessageBox.Show(
                        "ERP 프로그램 이름을 설정하면 ERP의 CPU·메모리·서버 응답 속도를 계속 기록합니다.\n" +
                        "(설정하지 않아도 '응답 없음' 감지는 모든 프로그램에 동작합니다)\n\n" +
                        "지금 설정 파일을 열까요?\n→ ErpProcess= 뒤에 작업 관리자 '세부 정보' 탭의 ERP 이름을 적고 저장한 뒤 프로그램을 다시 시작하세요.",
                        "PC 모니터", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                    Open(Settings.IniPath, null);
            }
        }

        void OnSample(Sample s)
        {
            int level = s.Hung.Count > 0 || s.Notes.Count >= 2 ? 2 : s.Notes.Count > 0 ? 1 : 0;
            if (level != _level) { _tray.Icon = _icons[level]; _level = level; }
            string tip = $"CPU {s.Cpu:0}% 메모리 {s.MemPct:0}% 디스크 {Sample.Fmt(s.DiskBusy)}%" +
                         (s.Hung.Count > 0 ? "\n응답없음: " + string.Join(",", s.Hung) : s.Notes.Count > 0 ? "\n" + string.Join(",", s.Notes) : "");
            _tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
            if (_status != null && !_status.IsDisposed) _status.Show(s);
        }

        void ShowStatus()
        {
            if (_status == null || _status.IsDisposed) _status = new StatusForm();
            var s = _mon.Latest;
            if (s != null) _status.Show(s);
            _status.Show();
            _status.Activate();
        }

        static void Open(string path, string missingMsg)
        {
            if (!File.Exists(path) && !Directory.Exists(path))
            {
                MessageBox.Show(missingMsg ?? "파일을 찾을 수 없습니다: " + path, "PC 모니터");
                return;
            }
            try
            {
                if (path.EndsWith(".log") || path.EndsWith(".ini"))
                    Process.Start("notepad.exe", "\"" + path + "\"");
                else
                    Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "PC 모니터"); }
        }

        static bool IsAutoStart()
        {
            try { using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k?.GetValue(RunName) != null; }
            catch { return false; }
        }

        static void SetAutoStart(bool on)
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (on) k.SetValue(RunName, "\"" + Application.ExecutablePath + "\"");
                    else k.DeleteValue(RunName, false);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("자동 실행 설정에 실패했습니다 (회사 보안 정책일 수 있음).\n" + ex.Message, "PC 모니터");
            }
        }

        void ExitApp()
        {
            _mon.Stop();
            _tray.Visible = false;
            _tray.Dispose();
            Application.Exit();
        }

        static Icon MakeIcon(Color c)
        {
            using (var bmp = new Bitmap(32, 32))
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (var b = new SolidBrush(c)) g.FillEllipse(b, 1, 1, 30, 30);
                using (var pen = new Pen(Color.White, 3))
                    g.DrawLines(pen, new[] { new Point(5, 18), new Point(11, 18), new Point(14, 9), new Point(18, 24), new Point(21, 15), new Point(27, 15) });
                return Icon.FromHandle(bmp.GetHicon());
            }
        }
    }

    internal class StatusForm : Form
    {
        readonly TextBox _box;

        public StatusForm()
        {
            Text = "PC 모니터 - 현재 상태";
            Width = 720; Height = 560;
            StartPosition = FormStartPosition.CenterScreen;
            _box = new TextBox
            {
                Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical,
                Font = new Font("맑은 고딕", 10f), BackColor = SystemColors.Window,
            };
            Controls.Add(_box);
        }

        public void Show(Sample s)
        {
            var sb = new StringBuilder();
            sb.AppendLine($"기록 시각: {s.Time:yyyy-MM-dd HH:mm:ss}");
            sb.AppendLine();
            sb.AppendLine($"CPU 사용률     {s.Cpu:0}%");
            sb.AppendLine($"CPU 실제 클럭  {s.ClockMHz} MHz (기본 대비 {s.ClockPct}%)");
            sb.AppendLine($"메모리         {s.MemPct:0}%  (여유 {s.MemFreeMB:N0} MB, 커밋 {s.CommitPct:0}%)");
            sb.AppendLine($"디스크 사용률  {Sample.Fmt(s.DiskBusy)}%   C드라이브 여유 {s.CFreePct:0}%");
            sb.AppendLine($"전원           {s.Power} {(s.BatPct >= 0 ? s.BatPct + "%" : "")}");
            if (s.Erp != null)
            {
                sb.AppendLine();
                sb.AppendLine($"[ERP] {s.Erp.Name}  CPU {s.Erp.Cpu:0.#}%  메모리 {s.Erp.MemMB} MB  핸들 {s.Erp.Handles}");
                if (s.ErpNet?.Target != null) sb.AppendLine($"      서버 {s.ErpNet.Text}");
            }
            sb.AppendLine();
            sb.AppendLine("상태: " + (s.Notes.Count > 0 ? string.Join(", ", s.Notes) : "정상"));
            sb.AppendLine();
            sb.AppendLine("■ CPU 많이 쓰는 프로그램");
            foreach (var p in s.TopCpu(10)) sb.AppendLine($"   {p.Name,-32} {p.Cpu,6:0.0}%   ({p.MemMB:N0} MB)");
            sb.AppendLine();
            sb.AppendLine("■ 메모리 많이 쓰는 프로그램");
            foreach (var p in s.TopMem(8)) sb.AppendLine($"   {p.Name,-32} {p.MemMB,8:N0} MB");
            var io = s.TopIo(5).ToList();
            if (io.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("■ 디스크 많이 쓰는 프로그램");
                foreach (var p in io) sb.AppendLine($"   {p.Name,-32} {p.IoMBs,6:0.0} MB/s");
            }
            _box.Text = sb.ToString();
            _box.SelectionStart = 0;
        }
    }
}
