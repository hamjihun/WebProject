"""앱 설정.

기본값은 환경 변수로 덮어쓸 수 있고, 화면의 [설정]에서 바꾼 값은
data/settings.json 에 저장되어 다음 실행에도 유지된다.
"""
from __future__ import annotations

import json
import os
import sys
import threading
from dataclasses import asdict, dataclass, fields
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
FROZEN = getattr(sys, "frozen", False)  # 설치형 exe 로 실행 중


def _default_data_dir() -> Path:
    if FROZEN:
        # 설치 폴더와 분리해서 사용자 폴더에 저장 (프로그램을 지웠다 다시 깔아도 유지)
        root = os.environ.get("LOCALAPPDATA") or str(Path.home() / ".local" / "share")
        return Path(root) / "LocalDocAI" / "data"
    return BASE_DIR / "data"


DATA_DIR = Path(os.environ.get("DOCAI_DATA_DIR") or _default_data_dir())
LOG_DIR = DATA_DIR.parent / "logs" if FROZEN else DATA_DIR / "logs"
FILES_DIR = DATA_DIR / "files"
DB_PATH = DATA_DIR / "docai.sqlite3"
SETTINGS_PATH = DATA_DIR / "settings.json"

HOST = "127.0.0.1"  # 외부 접속을 막기 위해 항상 이 PC 안에서만 연다
PORT = int(os.environ.get("DOCAI_PORT", "8765"))

MAX_UPLOAD_MB = int(os.environ.get("DOCAI_MAX_UPLOAD_MB", "100"))


@dataclass
class Settings:
    ollama_url: str = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
    chat_model: str = os.environ.get("DOCAI_CHAT_MODEL", "qwen3:4b-instruct")
    embed_model: str = os.environ.get("DOCAI_EMBED_MODEL", "bge-m3")
    # 한 번에 AI에게 넘기는 문서 조각 수. 적을수록 빠르다.
    top_k: int = int(os.environ.get("DOCAI_TOP_K", "5"))
    # 조각 하나의 최대 글자 수
    chunk_chars: int = int(os.environ.get("DOCAI_CHUNK_CHARS", "700"))
    chunk_overlap: int = int(os.environ.get("DOCAI_CHUNK_OVERLAP", "100"))
    # 모델이 한 번에 읽을 수 있는 토큰 수. 메모리 8GB PC는 4096 권장.
    num_ctx: int = int(os.environ.get("DOCAI_NUM_CTX", "6144"))
    temperature: float = float(os.environ.get("DOCAI_TEMPERATURE", "0.2"))
    # 이 점수보다 관련도가 낮은 조각은 근거로 쓰지 않는다 (0~1)
    min_score: float = float(os.environ.get("DOCAI_MIN_SCORE", "0.3"))


_lock = threading.Lock()
_settings: Settings | None = None


def ensure_dirs() -> None:
    FILES_DIR.mkdir(parents=True, exist_ok=True)


def get_settings() -> Settings:
    global _settings
    with _lock:
        if _settings is None:
            _settings = Settings()
            if not SETTINGS_PATH.exists() and "DOCAI_CHAT_MODEL" not in os.environ:
                # 처음 실행: PC 메모리에 맞는 모델을 고른다
                from .system import recommended_profile

                _apply(_settings, recommended_profile())
            if SETTINGS_PATH.exists():
                try:
                    saved = json.loads(SETTINGS_PATH.read_text(encoding="utf-8-sig"))
                    _apply(_settings, saved)
                except (OSError, ValueError):
                    pass
                else:
                    _migrate(_settings)
        return _settings


def _migrate(s: Settings) -> None:
    """이전 버전 기본 모델을 쓰고 있으면 새 기본 모델로 바꾼다 (처음 설정 창에서 새로 받게 됨)."""
    from .system import MODEL_MIGRATIONS

    new = MODEL_MIGRATIONS.get(s.chat_model)
    if new:
        s.chat_model = new
        try:
            SETTINGS_PATH.write_text(json.dumps(asdict(s), ensure_ascii=False, indent=2), encoding="utf-8")
        except OSError:
            pass


def update_settings(values: dict) -> Settings:
    s = get_settings()
    with _lock:
        _apply(s, values)
        ensure_dirs()
        SETTINGS_PATH.write_text(
            json.dumps(asdict(s), ensure_ascii=False, indent=2), encoding="utf-8"
        )
    return s


def _apply(s: Settings, values: dict) -> None:
    for f in fields(Settings):
        if f.name in values and values[f.name] is not None:
            current = getattr(s, f.name)
            setattr(s, f.name, type(current)(values[f.name]))
