using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace PCMonitor
{
    internal class Settings
    {
        public int IntervalSec = 10;
        public int CpuAlert = 80;
        public int MemAlert = 90;
        public int DiskAlert = 90;
        public int KeepDays = 30;
        public int PingWarnMs = 100;
        public string[] ErpProcess = new string[0];
        public string LogDir;

        public static string IniPath => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "settings.ini");
        public bool IsNew;

        const string Template =
@"; PC 모니터 설정 파일 (수정 후 프로그램 다시 시작)
;
; ERP 프로그램 실행 파일 이름 (작업 관리자 > 세부 정보 탭의 이름, .exe 제외)
; 여러 개는 쉼표로 구분. 일부만 적어도 됨. 예) ErpProcess=erp,douzone,iCUBE
; 비워 두어도 '응답 없음' 감지는 모든 프로그램에 대해 동작함
ErpProcess=

; 기록 간격(초)
IntervalSec=10

; 경고 기준(%)
CpuAlert=80
MemAlert=90
DiskAlert=90

; 서버 응답이 이 값(ms)보다 느리면 네트워크 지연으로 판단
PingWarnMs=100

; 기록 보관 기간(일)
KeepDays=30

; 기록 폴더 (비우면 문서\PCMonitor)
LogDir=
";

        public static Settings Load()
        {
            var s = new Settings();
            if (!File.Exists(IniPath))
            {
                try { File.WriteAllText(IniPath, Template, new UTF8Encoding(true)); } catch { }
                s.IsNew = true;
            }
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (var raw in File.ReadAllLines(IniPath, Encoding.UTF8))
                {
                    var line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith(";") || line.StartsWith("#")) continue;
                    int eq = line.IndexOf('=');
                    if (eq > 0) map[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
            }
            catch { }

            int I(string k, int d, int min) => map.TryGetValue(k, out var v) && int.TryParse(v, out var n) && n >= min ? n : d;
            s.IntervalSec = I("IntervalSec", 10, 2);
            s.CpuAlert = I("CpuAlert", 80, 1);
            s.MemAlert = I("MemAlert", 90, 1);
            s.DiskAlert = I("DiskAlert", 90, 1);
            s.PingWarnMs = I("PingWarnMs", 100, 1);
            s.KeepDays = I("KeepDays", 30, 1);
            if (map.TryGetValue("ErpProcess", out var erp))
                s.ErpProcess = erp.Split(',').Select(x => x.Trim().Replace(".exe", "")).Where(x => x.Length > 0).ToArray();
            s.LogDir = map.TryGetValue("LogDir", out var dir) && dir.Length > 0
                ? dir
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "PCMonitor");
            return s;
        }

        public bool IsErp(string processName) =>
            ErpProcess.Any(e => processName.IndexOf(e, StringComparison.OrdinalIgnoreCase) >= 0);
    }
}
