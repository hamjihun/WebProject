using System;
using System.Collections.Generic;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;

namespace PCMonitor
{
    internal static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct FILETIME { public uint Low; public uint High; public ulong Value => ((ulong)High << 32) | Low; }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetProcessIoCounters(IntPtr hProcess, out IO_COUNTERS counters);

        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
        const uint GW_OWNER = 4;

        /// <summary>'응답 없음' 상태인 최상위 창 목록 (PID, 창 제목)</summary>
        public static List<(int pid, string title)> GetHungWindows()
        {
            var list = new List<(int, string)>();
            EnumWindows((h, l) =>
            {
                try
                {
                    if (!IsWindowVisible(h) || GetWindow(h, GW_OWNER) != IntPtr.Zero) return true;
                    if (!IsHungAppWindow(h)) return true;
                    GetWindowThreadProcessId(h, out uint pid);
                    var sb = new StringBuilder(256);
                    GetWindowText(h, sb, sb.Capacity);
                    list.Add(((int)pid, sb.ToString()));
                }
                catch { }
                return true;
            }, IntPtr.Zero);
            return list;
        }

        // ---- TCP 연결 목록 (프로세스별 서버 주소 확인용) ----
        [DllImport("iphlpapi.dll", SetLastError = true)]
        static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int size, bool order, int af, int tableClass, uint reserved);

        [StructLayout(LayoutKind.Sequential)]
        struct MIB_TCPROW_OWNER_PID
        {
            public uint state, localAddr, localPort, remoteAddr, remotePort, owningPid;
        }

        /// <summary>해당 PID가 연결 중인 원격 서버 목록 (ESTABLISHED, 로컬 주소 제외)</summary>
        public static List<IPEndPoint> GetRemoteEndpoints(int pid)
        {
            var result = new List<IPEndPoint>();
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2 /*AF_INET*/, 5 /*OWNER_PID_ALL*/, 0);
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetExtendedTcpTable(buf, ref size, false, 2, 5, 0) != 0) return result;
                int count = Marshal.ReadInt32(buf);
                IntPtr row = buf + 4;
                int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                for (int i = 0; i < count; i++, row += rowSize)
                {
                    var r = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(row, typeof(MIB_TCPROW_OWNER_PID));
                    if (r.owningPid != pid || r.state != 5 /*ESTABLISHED*/) continue;
                    var ip = new IPAddress(r.remoteAddr);
                    if (IPAddress.IsLoopback(ip)) continue;
                    int port = (int)(((r.remotePort & 0xFF) << 8) | ((r.remotePort >> 8) & 0xFF));
                    var ep = new IPEndPoint(ip, port);
                    if (!result.Exists(e => e.Equals(ep))) result.Add(ep);
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return result;
        }
    }
}

namespace PCMonitor
{
    /// <summary>핸들을 열지 않고 모든 프로세스의 CPU시간/메모리/IO를 한 번에 읽음 (보안 프로그램 등 보호된 프로세스 포함)</summary>
    internal static class ProcessSnapshot
    {
        [DllImport("ntdll.dll")]
        static extern uint NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int returnLength);

        public struct Raw
        {
            public int Pid;
            public string Name;
            public long CpuTime100ns;   // user + kernel
            public long PrivateWs;      // 작업 관리자 '메모리'와 같은 값(전용 작업 집합)
            public long IoBytes;        // 누적 read+write+other
            public int Handles;
            public int Threads;
        }

        static int _bufSize = 1 << 20;

        public static List<Raw> Read()
        {
            if (IntPtr.Size != 8) throw new PlatformNotSupportedException("64비트 Windows에서만 동작합니다.");
            var list = new List<Raw>(400);
            while (true)
            {
                IntPtr buf = Marshal.AllocHGlobal(_bufSize);
                try
                {
                    uint st = NtQuerySystemInformation(5 /*SystemProcessInformation*/, buf, _bufSize, out int need);
                    if (st == 0xC0000004 /*INFO_LENGTH_MISMATCH*/) { _bufSize = Math.Max(need, _bufSize) * 2; continue; }
                    if (st != 0) return list;
                    long off = 0;
                    while (true)
                    {
                        IntPtr p = new IntPtr(buf.ToInt64() + off);
                        uint next = (uint)Marshal.ReadInt32(p, 0);
                        var r = new Raw
                        {
                            Threads = Marshal.ReadInt32(p, 4),
                            PrivateWs = Marshal.ReadInt64(p, 8),
                            CpuTime100ns = Marshal.ReadInt64(p, 40) + Marshal.ReadInt64(p, 48),
                            Pid = (int)Marshal.ReadInt64(p, 80),
                            Handles = Marshal.ReadInt32(p, 96),
                            IoBytes = Marshal.ReadInt64(p, 232) + Marshal.ReadInt64(p, 240) + Marshal.ReadInt64(p, 248),
                        };
                        int nameLen = Marshal.ReadInt16(p, 56);
                        IntPtr nameBuf = Marshal.ReadIntPtr(p, 64);
                        r.Name = nameBuf == IntPtr.Zero ? (r.Pid == 0 ? "Idle" : "System")
                                                        : Marshal.PtrToStringUni(nameBuf, nameLen / 2);
                        if (r.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) r.Name = r.Name.Substring(0, r.Name.Length - 4);
                        list.Add(r);
                        if (next == 0) break;
                        off += next;
                    }
                    return list;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
        }
    }
}
