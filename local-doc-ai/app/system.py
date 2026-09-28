"""PC 사양 확인과 Ollama 실행 파일 찾기/실행."""
from __future__ import annotations

import ctypes
import os
import shutil
import subprocess
import sys
from pathlib import Path


def total_ram_gb() -> float:
    try:
        if sys.platform == "win32":
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]
            st = MEMORYSTATUSEX()
            st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
            return st.ullTotalPhys / 1024**3
        if sys.platform == "darwin":
            out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout
            return int(out.strip()) / 1024**3
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 1024**3
    except Exception:
        return 16.0


def recommended_profile(ram_gb: float | None = None) -> dict:
    """메모리에 맞는 기본 모델과 설정."""
    ram = total_ram_gb() if ram_gb is None else ram_gb
    # 16GB PC는 윈도우가 약간 빼고 보고하므로 14GB 기준
    if ram >= 14:
        return {"chat_model": "qwen3:4b", "num_ctx": 6144, "top_k": 5}
    return {"chat_model": "qwen3:1.7b", "num_ctx": 4096, "top_k": 4}


# 대략적인 다운로드 크기 (GB), 안내용
MODEL_SIZES_GB = {"qwen3:4b": 2.5, "qwen3:1.7b": 1.4, "bge-m3": 1.2}


def find_ollama() -> str | None:
    found = shutil.which("ollama")
    if found:
        return found
    candidates = []
    if sys.platform == "win32":
        local = os.environ.get("LOCALAPPDATA", "")
        candidates += [
            Path(local) / "Programs" / "Ollama" / "ollama.exe",
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Ollama" / "ollama.exe",
        ]
    else:
        candidates += [Path("/usr/local/bin/ollama"), Path("/opt/homebrew/bin/ollama")]
    for c in candidates:
        if c.exists():
            return str(c)
    return None


def start_ollama() -> bool:
    """Ollama 가 꺼져 있을 때 백그라운드로 실행한다. 실행을 시도했으면 True."""
    exe = find_ollama()
    if not exe:
        return False
    flags = 0
    if sys.platform == "win32":
        flags = subprocess.CREATE_NO_WINDOW | subprocess.DETACHED_PROCESS
    try:
        subprocess.Popen(
            [exe, "serve"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=flags, close_fds=True,
        )
        return True
    except OSError:
        return False
