# 파일 대량 변경 감시 — agent.ps1 이 점 소싱(. fswatch.ps1)해서 쓴다.
# 랜섬웨어는 짧은 시간에 파일을 한꺼번에 암호화하며 확장자를 바꾸거나(a.docx → a.docx.locked) 협박 안내문을 남긴다.
# FileSystemWatcher 를 C# 로 두어 PowerShell 이 쉬는 동안에도 셈을 하고, agent.ps1 이 1분마다 Step-FsWatch 로 집계한다.
# agent.conf: SEC_WATCH=D:\;E:\자료 (감시할 폴더, 0 = 안 함. 비우면 C: 를 뺀 모든 고정 드라이브, 없으면 C:\Users)
#             SEC_EXT=30 (1분에 확장자가 바뀐 파일 수) · SEC_FILES=5000 (1분에 바뀐 파일 수, 2분 연속이면 주의)
$FsSrc = @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Text.RegularExpressions;
public class ImsFsSnap {
  public int Files; public int Renamed; public int ExtChanged; public int Overflow;
  public string[] Notes; public string[] TopExt; public string[] TopDir; public string[] Samples;
}
public class ImsFsWatch {
  private List<FileSystemWatcher> ws = new List<FileSystemWatcher>();
  private readonly object lk = new object();
  private HashSet<string> files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  private int renamed, extChanged, overflow;
  private List<string> notes = new List<string>();
  private List<string> samples = new List<string>();
  private Dictionary<string, int> exts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
  private Dictionary<string, int> dirs = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
  private string[] excl;
  private static readonly Regex NoteRe = new Regex(@"(decrypt|ransom|recover.?(your|my|all)?.?files|restore.?(your|my|all)?.?files|how.?to.?(back|get|restore|recover|decrypt|unlock)|unlock.?files|files.?encrypted|readme.?(now|first|to.?decrypt)).*\.(txt|html?|hta|url|rtf)$", RegexOptions.IgnoreCase);
  private static readonly HashSet<string> TmpExt = new HashSet<string>(new string[] { "", ".tmp", ".temp", ".bak", ".old", ".log", ".part", ".partial", ".crdownload", ".download", ".swp", ".lock", ".lck", ".ldb" }, StringComparer.OrdinalIgnoreCase);
  public string[] Roots;
  public ImsFsWatch(string[] roots, string[] exclude) {
    excl = exclude == null ? new string[0] : exclude;
    List<string> ok = new List<string>();
    foreach (string r in roots) {
      try {
        FileSystemWatcher w = new FileSystemWatcher(r);
        w.IncludeSubdirectories = true; w.InternalBufferSize = 65536;
        w.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite;
        w.Changed += OnChange; w.Created += OnChange; w.Deleted += OnChange; w.Renamed += OnRename; w.Error += OnError;
        w.EnableRaisingEvents = true; ws.Add(w); ok.Add(r);
      } catch { }
    }
    Roots = ok.ToArray();
  }
  public void Stop() { foreach (FileSystemWatcher w in ws) { try { w.EnableRaisingEvents = false; w.Dispose(); } catch { } } ws.Clear(); }
  private bool Skip(string p) {
    if (p == null) return true;
    foreach (string x in excl) if (x.Length > 0 && p.IndexOf(x, StringComparison.OrdinalIgnoreCase) >= 0) return true;
    return false;
  }
  private static string Top(string p) {
    string[] a = p.Split('\\');
    if (a.Length > 3) return a[0] + "\\" + a[1] + "\\" + a[2];
    if (a.Length > 2) return a[0] + "\\" + a[1];
    return a[0];
  }
  private void Count(string p) {
    if (files.Count < 100000) files.Add(p);
    string t = Top(p); int n; dirs.TryGetValue(t, out n); if (n > 0 || dirs.Count < 3000) dirs[t] = n + 1;
  }
  private void Note(string p) { try { if (notes.Count < 20 && NoteRe.IsMatch(Path.GetFileName(p))) notes.Add(p); } catch { } }
  private void OnChange(object s, FileSystemEventArgs e) {
    try {
      if (Skip(e.FullPath)) return;
      lock (lk) { Count(e.FullPath); if (e.ChangeType == WatcherChangeTypes.Created) Note(e.FullPath); }
    } catch { }
  }
  private void OnRename(object s, RenamedEventArgs e) {
    try {
      if (Skip(e.FullPath)) return;
      lock (lk) {
        Count(e.FullPath); renamed++; Note(e.FullPath);
        string oldName = Path.GetFileName(e.OldFullPath == null ? "" : e.OldFullPath), newName = Path.GetFileName(e.FullPath);
        string o = Path.GetExtension(oldName), n = Path.GetExtension(newName);
        if (!string.Equals(o, n, StringComparison.OrdinalIgnoreCase) && !TmpExt.Contains(o) && !TmpExt.Contains(n) && !oldName.StartsWith("~") && !newName.StartsWith("~")) {
          extChanged++;
          int c; exts.TryGetValue(n, out c); if (c > 0 || exts.Count < 300) exts[n] = c + 1;
          if (samples.Count < 3) samples.Add(oldName + " → " + newName);
        }
      }
    } catch { }
  }
  private void OnError(object s, ErrorEventArgs e) { try { lock (lk) { overflow++; } } catch { } }
  private static string[] TopN(Dictionary<string, int> d, int k) {
    List<KeyValuePair<string, int>> l = new List<KeyValuePair<string, int>>(d);
    l.Sort(delegate(KeyValuePair<string, int> a, KeyValuePair<string, int> b) { return b.Value.CompareTo(a.Value); });
    List<string> r = new List<string>();
    for (int i = 0; i < l.Count && i < k; i++) r.Add(l[i].Key + "(" + l[i].Value + ")");
    return r.ToArray();
  }
  public ImsFsSnap Take() {
    lock (lk) {
      ImsFsSnap s = new ImsFsSnap();
      s.Files = files.Count; s.Renamed = renamed; s.ExtChanged = extChanged; s.Overflow = overflow;
      s.Notes = notes.ToArray(); s.TopExt = TopN(exts, 3); s.TopDir = TopN(dirs, 3); s.Samples = samples.ToArray();
      files.Clear(); renamed = 0; extChanged = 0; overflow = 0; notes.Clear(); samples.Clear(); exts.Clear(); dirs.Clear();
      return s;
    }
  }
}
'@

$FsWatch = $null; $FsRoots = @(); $fsEvents = New-Object System.Collections.ArrayList
$fsLast = Get-Date; $fsBig = 0; $fsBigAt = (Get-Date).AddHours(-1); $fsExtAt = (Get-Date).AddHours(-1)
$FsExt = 30; if ($conf['SEC_EXT'] -match '^\d+$') { $FsExt = [math]::Max(5, [int]$conf['SEC_EXT']) }
$FsFiles = 5000; if ($conf['SEC_FILES'] -match '^\d+$') { $FsFiles = [math]::Max(200, [int]$conf['SEC_FILES']) }

function Start-FsWatch([string[]]$skipPaths) {
  if ($conf['SEC_WATCH'] -eq '0') { return }
  try { if (-not ('ImsFsWatch' -as [type])) { Add-Type -TypeDefinition $FsSrc -Language CSharp -ErrorAction Stop } } catch { Log "파일 감시 준비 실패: $($_.Exception.Message)"; return }
  $roots = @()
  if ($conf['SEC_WATCH']) { $roots = @($conf['SEC_WATCH'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path $_) }) }
  else {
    $roots = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.DeviceID -ne 'C:' } | ForEach-Object { "$($_.DeviceID)\" })
    if (-not $roots.Count -and (Test-Path 'C:\Users')) { $roots = @('C:\Users') }
  }
  # 늘 바뀌는 곳은 뺀다: 휴지통·복원 지점·임시·프로그램 캐시·DB 파일 폴더·백업 폴더(SQL 백업이 매일 큰 파일을 만든다)
  $ex = @('\$Recycle.Bin', '\System Volume Information', '\AppData\', '\Temp\', '\Windows\', '\ProgramData\', '\MSSQL', '\DBBackup', '\DB_BACKUP', '\pagefile', '\WindowsImageBackup', '\IMSMonitoringAgent', '\Veeam')
  $ex += @($skipPaths | Where-Object { $_ })
  if ($conf['SEC_WATCH_SKIP']) { $ex += @($conf['SEC_WATCH_SKIP'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
  try {
    $script:FsWatch = New-Object ImsFsWatch -ArgumentList ([string[]]$roots), ([string[]]$ex)
    $script:FsRoots = @($script:FsWatch.Roots)
    Log "파일 대량 변경 감시 시작: $($script:FsRoots -join ', ')"
  } catch { Log "파일 감시 시작 실패: $($_.Exception.Message)" }
}

function Add-FsEv([string]$sev, [string]$msg) {
  $now = Get-Date
  [void]$script:fsEvents.Insert(0, [ordered]@{ id = "W:$($now.ToString('yyyyMMddHHmmss'))"; t = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); sev = $sev; kind = 'ransom'; msg = $msg })
  while ($script:fsEvents.Count -gt 20) { $script:fsEvents.RemoveAt($script:fsEvents.Count - 1) }
  Log "$sev $msg"
}

function Step-FsWatch {                              # 1분마다 집계해 이상하면 이벤트를 만든다
  if (-not $script:FsWatch -or ((Get-Date) - $script:fsLast).TotalSeconds -lt 60) { return }
  $script:fsLast = Get-Date
  $s = $script:FsWatch.Take()
  $where = $(if ($s.TopDir.Length) { ' · 주로 ' + ($s.TopDir -join ', ') } else { '' })
  if ($s.Notes.Length) {
    Add-FsEv 'crit' "랜섬웨어 안내문으로 보이는 파일이 생겼습니다: $($s.Notes[0])$(if ($s.Notes.Length -gt 1) { " 외 $($s.Notes.Length - 1)개" }) — 즉시 확인"
  }
  if ($s.ExtChanged -ge $FsExt -and ((Get-Date) - $script:fsExtAt).TotalMinutes -ge 10) {
    $script:fsExtAt = Get-Date
    Add-FsEv 'crit' "파일 확장자가 1분에 $($s.ExtChanged)개 바뀌었습니다 — 랜섬웨어 의심 · $($s.TopExt -join ', ')$(if ($s.Samples.Length) { ' · 예: ' + $s.Samples[0] })$where"
  }
  if ($s.Files -ge $FsFiles -or $s.Overflow -gt 0) { $script:fsBig++ } else { $script:fsBig = 0 }
  if ($script:fsBig -ge 2 -and ((Get-Date) - $script:fsBigAt).TotalMinutes -ge 30) {
    $script:fsBigAt = Get-Date
    Add-FsEv 'warn' "파일이 2분 넘게 대량으로 바뀌고 있습니다 (1분에 $($s.Files)개$(if ($s.Overflow) { ', 너무 많아 일부 놓침' }))$where — 백업·자료 이동이 아니면 확인"
  }
}

function Get-FsStatus {
  if (-not $script:FsWatch) { return $null }
  $cut = (Get-Date).AddDays(-3).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  while ($script:fsEvents.Count -and [string]$script:fsEvents[$script:fsEvents.Count - 1].t -lt $cut) { $script:fsEvents.RemoveAt($script:fsEvents.Count - 1) }
  return [ordered]@{ roots = @($script:FsRoots) }
}
