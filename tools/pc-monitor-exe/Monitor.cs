using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace PCMonitor
{
    internal class ProcStat
    {
        public string Name;
        public double Cpu;      // 전체 CPU 대비 %
        public long MemMB;
        public double IoMBs;    // 초당 MB
        public int Count;
        public int Handles;
        public List<int> Pids = new List<int>();
    }

    internal class NetCheck
    {
        public string Target;     // 서버 주소:포트
        public long PingMs = -1;  // -1 = 응답 없음(차단 포함)
        public long TcpMs = -1;   // -1 = 연결 실패 / 미측정
        public string Text =>
            Target == null ? "" :
            $"{Target} ping {(PingMs >= 0 ? PingMs + "ms" : "응답없음")}" + (TcpMs != -2 ? $", 접속 {(TcpMs >= 0 ? TcpMs + "ms" : "실패")}" : "");
        public long BestMs => PingMs >= 0 ? PingMs : TcpMs;
    }

    internal class Sample
    {
        public DateTime Time;
        public double Cpu, MemPct, CommitPct, DiskBusy = -1, CFreePct = -1;
        public long MemFreeMB;
        public int ClockMHz, ClockPct;
        public string Power = "";
        public int BatPct = -1;
        public List<ProcStat> Procs = new List<ProcStat>();
        public ProcStat Erp;
        public NetCheck ErpNet;
        public List<string> Hung = new List<string>();
        public List<string> Notes = new List<string>();

        public IEnumerable<ProcStat> TopCpu(int n) => Procs.OrderByDescending(p => p.Cpu).Take(n);
        public IEnumerable<ProcStat> TopMem(int n) => Procs.OrderByDescending(p => p.MemMB).Take(n);
        public IEnumerable<ProcStat> TopIo(int n) => Procs.Where(p => p.IoMBs >= 0.1).OrderByDescending(p => p.IoMBs).Take(n);

        public string Summary() =>
            $"CPU {Cpu:0}%  클럭 {ClockMHz}MHz({ClockPct}%)  메모리 {MemPct:0}%(커밋 {CommitPct:0}%)  디스크 {Fmt(DiskBusy)}%  전원 {Power}" +
            (Erp != null ? $"  | ERP CPU {Erp.Cpu:0.#}% 메모리 {Erp.MemMB}MB" : "") +
            (ErpNet?.Target != null ? $"  서버 {ErpNet.BestMs}ms" : "") +
            $"  | CPU상위 {string.Join(", ", TopCpu(3).Select(p => $"{p.Name} {p.Cpu:0.#}%"))}";

        public static string Fmt(double v) => v < 0 ? "-" : v.ToString("0");
    }

    internal class HangState
    {
        public int Pid;
        public string Name, Title;
        public DateTime Start;
        public string Category, Verdict;
    }

    internal class Monitor
    {
        readonly Settings _cfg;
        readonly int _cores = Environment.ProcessorCount;
        int _baseMHz;
        public volatile Sample Latest;
        public event Action<Sample> Updated;
        public DateTime LastResume = DateTime.MinValue;

        ulong _prevIdle, _prevTotal;
        Dictionary<int, ProcessSnapshot.Raw> _prevProcs = new Dictionary<int, ProcessSnapshot.Raw>();
        DateTime _prevProcTime;
        readonly Queue<Sample> _history = new Queue<Sample>();
        readonly Dictionary<int, HangState> _hangs = new Dictionary<int, HangState>();
        readonly object _fileLock = new object();
        volatile bool _stop;

        public Monitor(Settings cfg) { _cfg = cfg; }

        public void Stop() => _stop = true;

        public void Run()
        {
            Directory.CreateDirectory(_cfg.LogDir);
            Cleanup();
            try
            {
                using (var s = new ManagementObjectSearcher("SELECT MaxClockSpeed FROM Win32_Processor"))
                    foreach (ManagementObject o in s.Get()) { _baseMHz = Convert.ToInt32(o["MaxClockSpeed"]); break; }
            }
            catch { }

            WriteEvent($"===== 모니터 시작 {DateTime.Now:yyyy-MM-dd HH:mm:ss}  (코어 {_cores}개, 기본 클럭 {_baseMHz}MHz, ERP 대상: {(_cfg.ErpProcess.Length > 0 ? string.Join(",", _cfg.ErpProcess) : "미지정")})");
            TakeSample(); // 기준값 확보

            DateTime lastFull = DateTime.Now;
            DateTime lastTick = DateTime.Now;
            while (!_stop)
            {
                Thread.Sleep(2000);
                DateTime now = DateTime.Now;
                double gap = (now - lastTick).TotalSeconds; // 직전 처리 종료 ~ 지금 (정상이면 약 2초)
                try
                {
                    // 2초마다 돌아야 하는데 크게 늦었다 = 이 프로그램을 포함한 PC 전체가 멈췄거나 절전 상태였음
                    if (gap > 15)
                    {
                        bool sleep = (now - LastResume).TotalSeconds < gap + 30;
                        var s = TakeSample();
                        if (sleep)
                            WriteEvent($"\n[{now:HH:mm:ss}] 절전/최대절전에서 복귀 (약 {gap:0}초 공백)");
                        else
                        {
                            string verdict = $"PC 전체가 약 {gap:0}초 동안 멈춤 (기록 프로그램도 멈춤). 특정 프로그램이 아니라 PC 자체 문제 가능성 → 디스크/드라이버/발열/전원 확인 필요";
                            WriteEvent($"\n[{now:HH:mm:ss}] ★ PC 전체 멈춤 감지\n  판정: [PC 전체 멈춤] {verdict}\n  복귀 직후 상태: {s.Summary()}\n" + DumpHistory());
                            WriteSummaryRow(now.AddSeconds(-gap), now, gap, "(PC 전체)", "PC 전체 멈춤", verdict);
                        }
                        lastFull = now;
                    }

                    bool hungChanged = CheckHung();
                    if ((now - lastFull).TotalSeconds >= _cfg.IntervalSec - 1 || hungChanged)
                    {
                        lastFull = now;
                        var s = TakeSample();
                        AnalyzeHangs(s);
                        WriteCsv(s);
                        if (now.Hour == 0 && now.Minute == 0) Cleanup();
                    }
                }
                catch (Exception ex) { LogError(ex); }
                lastTick = DateTime.Now;
            }
            WriteEvent($"===== 모니터 종료 {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        }

        // ---------------- 수집 ----------------
        Sample TakeSample()
        {
            var s = new Sample { Time = DateTime.Now };

            // CPU 전체
            if (Native.GetSystemTimes(out var idle, out var kernel, out var user))
            {
                ulong total = kernel.Value + user.Value;
                if (_prevTotal > 0 && total > _prevTotal)
                    s.Cpu = Math.Round(100.0 * (1 - (double)(idle.Value - _prevIdle) / (total - _prevTotal)), 1);
                _prevIdle = idle.Value; _prevTotal = total;
            }

            // 메모리
            var m = new Native.MEMORYSTATUSEX();
            if (Native.GlobalMemoryStatusEx(m))
            {
                s.MemPct = Math.Round(100.0 * (m.ullTotalPhys - m.ullAvailPhys) / m.ullTotalPhys, 1);
                s.MemFreeMB = (long)(m.ullAvailPhys / 1048576);
                s.CommitPct = Math.Round(100.0 * (m.ullTotalPageFile - m.ullAvailPageFile) / m.ullTotalPageFile, 1);
            }

            // 디스크 사용률 / CPU 실제 클럭 (WMI, 언어와 무관한 클래스명)
            s.DiskBusy = Wmi("SELECT PercentIdleTime FROM Win32_PerfFormattedData_PerfDisk_PhysicalDisk WHERE Name='_Total'", "PercentIdleTime", v => Math.Max(0, 100 - v));
            double perf = Wmi("SELECT PercentProcessorPerformance FROM Win32_PerfFormattedData_Counters_ProcessorInformation WHERE Name='_Total'", "PercentProcessorPerformance", v => v);
            if (perf > 0) { s.ClockPct = (int)perf; s.ClockMHz = (int)(_baseMHz * perf / 100); }

            try
            {
                var c = new DriveInfo("C");
                s.CFreePct = Math.Round(100.0 * c.AvailableFreeSpace / c.TotalSize, 1);
            }
            catch { }

            try
            {
                var ps = System.Windows.Forms.SystemInformation.PowerStatus;
                s.Power = ps.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online ? "충전기" :
                          ps.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Offline ? "배터리" : "";
                if (ps.BatteryLifePercent <= 1) s.BatPct = (int)(ps.BatteryLifePercent * 100);
            }
            catch { }

            // 프로세스별
            var now = DateTime.Now;
            var raw = ProcessSnapshot.Read();
            double elapsed100ns = (now - _prevProcTime).Ticks;
            double elapsedSec = (now - _prevProcTime).TotalSeconds;
            var per = new List<(string name, int pid, double cpu, long mem, double io, int handles)>();
            var cur = new Dictionary<int, ProcessSnapshot.Raw>();
            foreach (var r in raw)
            {
                cur[r.Pid] = r;
                if (r.Pid == 0) continue;
                double cpu = 0, io = 0;
                if (_prevProcs.TryGetValue(r.Pid, out var p) && p.Name == r.Name && elapsed100ns > 0)
                {
                    cpu = 100.0 * Math.Max(0, r.CpuTime100ns - p.CpuTime100ns) / (elapsed100ns * _cores);
                    io = Math.Max(0, r.IoBytes - p.IoBytes) / 1048576.0 / elapsedSec;
                }
                per.Add((r.Name, r.Pid, cpu, r.PrivateWs / 1048576, io, r.Handles));
            }
            _prevProcs = cur;
            _prevProcTime = now;

            s.Procs = per.GroupBy(x => x.name, StringComparer.OrdinalIgnoreCase).Select(g =>
            {
                var ps = new ProcStat
                {
                    Name = g.First().name,
                    Cpu = Math.Round(g.Sum(x => x.cpu), 1),
                    MemMB = g.Sum(x => x.mem),
                    IoMBs = Math.Round(g.Sum(x => x.io), 1),
                    Count = g.Count(),
                    Handles = g.Sum(x => x.handles),
                };
                ps.Pids.AddRange(g.Select(x => x.pid));
                return ps;
            }).ToList();

            // ERP
            if (_cfg.ErpProcess.Length > 0)
            {
                var erp = s.Procs.Where(p => _cfg.IsErp(p.Name)).ToList();
                if (erp.Count > 0)
                {
                    s.Erp = new ProcStat
                    {
                        Name = string.Join("+", erp.Select(e => e.Name)),
                        Cpu = Math.Round(erp.Sum(e => e.Cpu), 1),
                        MemMB = erp.Sum(e => e.MemMB),
                        IoMBs = erp.Sum(e => e.IoMBs),
                        Count = erp.Sum(e => e.Count),
                        Handles = erp.Sum(e => e.Handles),
                    };
                    s.Erp.Pids.AddRange(erp.SelectMany(e => e.Pids));
                    s.ErpNet = CheckNetwork(s.Erp.Pids, tcp: false);
                }
            }

            // 경고 메모
            if (s.Cpu >= _cfg.CpuAlert) s.Notes.Add("CPU높음");
            if (s.MemPct >= _cfg.MemAlert || s.CommitPct >= 90) s.Notes.Add("메모리부족");
            if (s.DiskBusy >= _cfg.DiskAlert) s.Notes.Add("디스크포화");
            if (s.ClockPct > 0 && s.ClockPct < 50 && s.Cpu >= 50) s.Notes.Add("클럭저하(발열/절전)");
            if (s.ErpNet?.Target != null && (s.ErpNet.BestMs < 0 || s.ErpNet.BestMs >= _cfg.PingWarnMs)) s.Notes.Add("ERP서버지연");

            lock (_hangs) s.Hung = _hangs.Values.Select(h => h.Name).ToList();
            if (s.Hung.Count > 0) s.Notes.Add("응답없음:" + string.Join(",", s.Hung));

            _history.Enqueue(s);
            while (_history.Count > 7) _history.Dequeue();
            Latest = s;
            try { Updated?.Invoke(s); } catch { }
            return s;
        }

        static double Wmi(string query, string prop, Func<double, double> f)
        {
            try
            {
                using (var q = new ManagementObjectSearcher(query))
                {
                    q.Options.Timeout = TimeSpan.FromSeconds(3);
                    foreach (ManagementObject o in q.Get()) return f(Convert.ToDouble(o[prop]));
                }
            }
            catch { }
            return -1;
        }

        /// <summary>프로세스가 연결 중인 서버에 대해 응답 시간 측정</summary>
        NetCheck CheckNetwork(IEnumerable<int> pids, bool tcp)
        {
            var nc = new NetCheck { TcpMs = -2 };
            List<IPEndPoint> eps;
            try { eps = pids.SelectMany(Native.GetRemoteEndpoints).ToList(); } catch { return nc; }
            if (eps.Count == 0) return nc;
            // 가장 많이 연결된 서버를 주 서버로 간주
            var ep = eps.GroupBy(e => e.ToString()).OrderByDescending(g => g.Count()).First().First();
            nc.Target = ep.ToString();
            try
            {
                using (var p = new Ping())
                {
                    var r = p.Send(ep.Address, 1000);
                    if (r.Status == IPStatus.Success) nc.PingMs = r.RoundtripTime;
                }
            }
            catch { }
            if (tcp)
            {
                try
                {
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    using (var c = new TcpClient())
                    {
                        var t = c.ConnectAsync(ep.Address, ep.Port);
                        nc.TcpMs = t.Wait(3000) && c.Connected ? sw.ElapsedMilliseconds : -1;
                    }
                }
                catch { nc.TcpMs = -1; }
            }
            return nc;
        }

        // ---------------- 응답 없음 감지 ----------------
        readonly List<HangState> _newHangs = new List<HangState>();

        bool CheckHung()
        {
            var hung = Native.GetHungWindows();
            var now = DateTime.Now;
            bool changed = false;
            var hungPids = new HashSet<int>(hung.Select(h => h.pid));

            lock (_hangs)
            {
                foreach (var h in hung)
                {
                    if (_hangs.ContainsKey(h.pid)) continue;
                    string name = "?";
                    try { using (var p = System.Diagnostics.Process.GetProcessById(h.pid)) name = p.ProcessName; } catch { }
                    var st = new HangState { Pid = h.pid, Name = name, Title = h.title, Start = now.AddSeconds(-5) }; // Windows는 5초 무응답 후 '응답 없음' 판정
                    _hangs[h.pid] = st;
                    _newHangs.Add(st);
                    changed = true;
                }

                foreach (var pid in _hangs.Keys.ToList())
                {
                    if (hungPids.Contains(pid)) continue;
                    var st = _hangs[pid];
                    _hangs.Remove(pid);
                    changed = true;
                    bool alive;
                    try { using (var p = System.Diagnostics.Process.GetProcessById(pid)) alive = !p.HasExited; } catch { alive = false; }
                    double dur = (now - st.Start).TotalSeconds;
                    string how = alive ? "정상 복구" : "프로그램 종료됨(강제 종료 추정)";
                    WriteEvent($"[{now:HH:mm:ss}] ■ {st.Name} 응답 없음 해제 - {how}, 약 {dur:0}초 멈춤");
                    WriteSummaryRow(st.Start, now, dur, st.Name + (alive ? "" : " (종료됨)"), st.Category ?? "", st.Verdict ?? "");
                }
            }
            return changed;
        }

        void AnalyzeHangs(Sample s)
        {
            List<HangState> list;
            lock (_hangs) { list = _newHangs.ToList(); _newHangs.Clear(); }
            foreach (var h in list)
            {
                var proc = s.Procs.FirstOrDefault(p => p.Pids.Contains(h.Pid))
                           ?? new ProcStat { Name = h.Name };
                var net = CheckNetwork(new[] { h.Pid }, tcp: true);
                var (cat, verdict, details) = Diagnose(s, h, proc, net);
                h.Category = cat; h.Verdict = verdict;

                var sb = new StringBuilder();
                sb.AppendLine();
                sb.AppendLine($"[{h.Start:HH:mm:ss}] ★ 응답 없음 발생: {h.Name}{(_cfg.IsErp(h.Name) ? " (ERP)" : "")}  창 제목: \"{h.Title}\"");
                sb.AppendLine($"  판정: [{cat}] {verdict}");
                foreach (var d in details) sb.AppendLine("    - " + d);
                sb.AppendLine($"  멈춘 프로그램: CPU {proc.Cpu:0.#}%  메모리 {proc.MemMB}MB  핸들 {proc.Handles}  디스크 {proc.IoMBs:0.#}MB/s");
                sb.AppendLine($"  서버 연결: {(net.Target != null ? net.Text : "연결된 외부 서버 없음")}");
                sb.AppendLine($"  PC 상태: {s.Summary()}");
                sb.AppendLine("  CPU 상위: " + string.Join(" / ", s.TopCpu(8).Select(p => $"{p.Name} {p.Cpu:0.#}%")));
                sb.AppendLine("  메모리 상위: " + string.Join(" / ", s.TopMem(8).Select(p => $"{p.Name} {p.MemMB}MB")));
                var io = s.TopIo(5).ToList();
                sb.AppendLine("  디스크 상위: " + (io.Count > 0 ? string.Join(" / ", io.Select(p => $"{p.Name} {p.IoMBs:0.#}MB/s")) : "없음"));
                sb.Append(DumpHistory());
                WriteEvent(sb.ToString());
            }
        }

        (string cat, string verdict, List<string> details) Diagnose(Sample s, HangState h, ProcStat proc, NetCheck net)
        {
            var d = new List<string>();
            var cats = new List<string>();
            double oneCore = 100.0 / _cores;
            var others = s.Procs.Where(p => !p.Pids.Contains(h.Pid) && p.Name != "Idle").ToList();
            // 직전 기록까지 포함해 가장 나빴던 값으로 판단 (멈추기 직전 상황 반영)
            var recent = _history.ToList();
            double maxCpu = recent.Count > 0 ? recent.Max(x => x.Cpu) : s.Cpu;
            double maxMem = recent.Count > 0 ? recent.Max(x => Math.Max(x.MemPct, x.CommitPct - 5)) : s.MemPct;
            double maxDisk = recent.Count > 0 ? recent.Max(x => x.DiskBusy) : s.DiskBusy;

            if (maxCpu >= _cfg.CpuAlert)
            {
                var top = s.TopCpu(1).FirstOrDefault();
                if (top != null && top.Pids.Contains(h.Pid))
                    { cats.Add("프로그램 자체 과부하"); d.Add($"PC CPU {maxCpu:0}% 중 멈춘 프로그램 자신이 {top.Cpu:0.#}% 사용 → 프로그램이 대량 처리 중"); }
                else
                {
                    var t = others.OrderByDescending(p => p.Cpu).Take(3).ToList();
                    cats.Add("PC CPU 과부하");
                    d.Add($"PC CPU {maxCpu:0}% → 다른 프로그램이 CPU 점유: {string.Join(", ", t.Select(p => $"{p.Name} {p.Cpu:0.#}%"))}");
                }
            }
            if (maxMem >= _cfg.MemAlert)
            {
                cats.Add("메모리 부족");
                d.Add($"메모리 {s.MemPct:0}%(커밋 {s.CommitPct:0}%), 여유 {s.MemFreeMB}MB → 상위: {string.Join(", ", s.TopMem(3).Select(p => $"{p.Name} {p.MemMB}MB"))}");
            }
            if (maxDisk >= _cfg.DiskAlert)
            {
                cats.Add("디스크 병목");
                var io = s.TopIo(3).ToList();
                d.Add($"디스크 사용률 {maxDisk:0}% → 많이 쓰는 프로그램: {(io.Count > 0 ? string.Join(", ", io.Select(p => $"{p.Name} {p.IoMBs:0.#}MB/s")) : "확인 불가")}");
            }
            if (recent.Any(x => x.ClockPct > 0 && x.ClockPct < 50 && x.Cpu >= 50))
            {
                cats.Add("발열/절전 성능제한");
                d.Add($"부하가 있는데 CPU 클럭이 기본의 {s.ClockPct}%({s.ClockMHz}MHz)로 떨어짐 → 발열 또는 절전 설정으로 성능 제한");
            }
            if (net.Target != null)
            {
                if (net.PingMs < 0 && net.TcpMs < 0)
                    { cats.Add("서버 연결 실패"); d.Add($"연결 서버({net.Target}) 연결 실패 → 네트워크 끊김(무선 불안정/VPN) 또는 서버 장애"); }
                else if (net.BestMs >= _cfg.PingWarnMs || net.TcpMs >= 1000)
                    { cats.Add("네트워크 지연"); d.Add($"연결 서버 응답 느림 ({net.Text}) → 네트워크 품질 또는 서버 과부하"); }
            }
            if (proc.Cpu >= oneCore * 0.8 && !cats.Contains("프로그램 자체 과부하"))
            {
                cats.Add("프로그램 자체 처리 중");
                d.Add($"멈춘 프로그램이 CPU 한 코어를 꽉 채워 사용({proc.Cpu:0.#}% = 코어 1개) → 화면/계산 처리 중 (대량 조회·엑셀 내보내기 등)");
            }
            if (proc.Handles > 10000)
                d.Add($"멈춘 프로그램의 핸들 수가 {proc.Handles}개로 많음 → 오래 켜 둬서 자원 누적(재시작 권장)");

            if (cats.Count == 0)
            {
                if (net.Target != null)
                {
                    cats.Add("서버 응답 대기 추정");
                    d.Add($"PC 자원(CPU/메모리/디스크)과 네트워크({net.Text})는 정상 → 서버(DB)에서 처리가 오래 걸렸거나 프로그램 내부 문제로 추정. 발생 시간을 전산팀/ERP 업체에 전달하면 서버 기록과 대조 가능");
                }
                else
                {
                    cats.Add("프로그램 내부 대기");
                    d.Add("PC 자원 정상, 연결 중인 서버 없음 → 프로그램 내부 대기(팝업 창 뒤에 숨음, 인쇄/파일 대기 등) 추정");
                }
            }
            string verdict = cats.Count == 1 ? CategoryHint(cats[0]) : "복합 원인: " + string.Join(" + ", cats);
            return (string.Join(" + ", cats), verdict, d);
        }

        static string CategoryHint(string c)
        {
            switch (c)
            {
                case "PC CPU 과부하": return "다른 프로그램이 CPU를 점유해서 멈춘 프로그램이 느려짐 (상세의 프로그램 확인)";
                case "프로그램 자체 과부하": return "프로그램 자신이 CPU를 많이 쓰는 작업 중이었음";
                case "메모리 부족": return "메모리가 부족해 디스크를 대신 쓰면서 멈춤 (프로그램/브라우저 탭 정리 또는 메모리 증설)";
                case "디스크 병목": return "디스크 사용이 몰려 멈춤 (백신 검사/업데이트/동기화 프로그램 의심)";
                case "발열/절전 성능제한": return "발열 또는 전원 설정 때문에 CPU 성능이 제한됨";
                case "서버 연결 실패": return "서버와 연결이 끊겨 응답을 기다림";
                case "네트워크 지연": return "연결 서버까지 네트워크가 느림";
                case "프로그램 자체 처리 중": return "프로그램이 무거운 작업(대량 조회/출력 등)을 처리하는 중이었음";
                case "서버 응답 대기 추정": return "PC는 정상, 서버 쪽 처리 지연으로 추정";
                default: return "PC 자원은 정상, 프로그램 내부 대기로 추정";
            }
        }

        string DumpHistory()
        {
            var sb = new StringBuilder();
            sb.AppendLine("  -- 직전 기록 (약 1분) --");
            foreach (var h in _history) sb.AppendLine($"    {h.Time:HH:mm:ss} {h.Summary()}");
            return sb.ToString();
        }

        // ---------------- 파일 기록 ----------------
        static readonly Encoding Utf8Bom = new UTF8Encoding(true);

        void Append(string file, string text)
        {
            lock (_fileLock)
            {
                try
                {
                    using (var w = new StreamWriter(Path.Combine(_cfg.LogDir, file), true, Utf8Bom))
                        w.Write(text);
                }
                catch { }
            }
        }

        static string Csv(params object[] cols) =>
            string.Join(",", cols.Select(c => "\"" + (c?.ToString() ?? "").Replace("\"", "\"\"") + "\"")) + "\r\n";

        void WriteCsv(Sample s)
        {
            string file = $"monitor_{s.Time:yyyy-MM-dd}.csv";
            bool exists = File.Exists(Path.Combine(_cfg.LogDir, file));
            var sb = new StringBuilder();
            if (!exists)
                sb.Append(Csv("시간", "CPU(%)", "CPU클럭(MHz)", "클럭비율(%)", "메모리(%)", "커밋(%)", "메모리여유(MB)", "디스크(%)", "C여유(%)",
                              "전원", "배터리(%)", "ERP CPU(%)", "ERP 메모리(MB)", "ERP서버", "ERP서버응답(ms)",
                              "CPU상위", "메모리상위", "디스크상위", "응답없음", "비고"));
            sb.Append(Csv(s.Time.ToString("yyyy-MM-dd HH:mm:ss"), s.Cpu, s.ClockMHz, s.ClockPct, s.MemPct, s.CommitPct, s.MemFreeMB,
                Sample.Fmt(s.DiskBusy), s.CFreePct, s.Power, s.BatPct >= 0 ? s.BatPct.ToString() : "",
                s.Erp?.Cpu, s.Erp?.MemMB, s.ErpNet?.Target, s.ErpNet?.Target != null ? s.ErpNet.BestMs.ToString() : "",
                string.Join(" / ", s.TopCpu(5).Select(p => $"{p.Name}({p.Cpu:0.#}%)")),
                string.Join(" / ", s.TopMem(3).Select(p => $"{p.Name}({p.MemMB}MB)")),
                string.Join(" / ", s.TopIo(3).Select(p => $"{p.Name}({p.IoMBs:0.#}MB/s)")),
                string.Join(",", s.Hung), string.Join(", ", s.Notes)));
            Append(file, sb.ToString());
        }

        public string EventFile => Path.Combine(_cfg.LogDir, $"분석_{DateTime.Now:yyyy-MM-dd}.log");
        public string SummaryFile => Path.Combine(_cfg.LogDir, "멈춤기록.csv");

        void WriteEvent(string text) => Append(Path.GetFileName(EventFile), text + "\r\n");

        void WriteSummaryRow(DateTime start, DateTime end, double dur, string prog, string cat, string verdict)
        {
            var sb = new StringBuilder();
            if (!File.Exists(SummaryFile)) sb.Append(Csv("날짜", "시작", "끝", "멈춘시간(초)", "프로그램", "원인 분류", "판정"));
            sb.Append(Csv(start.ToString("yyyy-MM-dd"), start.ToString("HH:mm:ss"), end.ToString("HH:mm:ss"), Math.Round(dur), prog, cat, verdict));
            Append(Path.GetFileName(SummaryFile), sb.ToString());
        }

        void Cleanup()
        {
            try
            {
                foreach (var f in Directory.GetFiles(_cfg.LogDir))
                {
                    var name = Path.GetFileName(f);
                    if ((name.StartsWith("monitor_") || name.StartsWith("분석_")) && File.GetLastWriteTime(f) < DateTime.Now.AddDays(-_cfg.KeepDays))
                        File.Delete(f);
                }
            }
            catch { }
        }

        public void LogError(Exception ex) => Append("error.log", $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {ex}\r\n");
    }
}
