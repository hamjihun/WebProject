"""SQLite 저장소. 문서, 조각(임베딩 포함), 대화 기록을 모두 이 PC의 파일 하나에 저장한다."""
from __future__ import annotations

import sqlite3
import threading
from contextlib import contextmanager
from typing import Iterator

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS notebooks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS documents (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    notebook_id  INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
    filename     TEXT NOT NULL,
    stored_path  TEXT NOT NULL,
    size_bytes   INTEGER NOT NULL,
    status       TEXT NOT NULL DEFAULT 'processing',  -- processing | ready | error
    error        TEXT,
    progress     REAL NOT NULL DEFAULT 0,
    chunk_count  INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS chunks (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    document_id  INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,
    location     TEXT NOT NULL,   -- 예: "p.3", "시트 '매출' 2~40행", "슬라이드 5"
    text         TEXT NOT NULL,
    embedding    BLOB             -- float32, 정규화된 벡터
);
CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(document_id);

CREATE TABLE IF NOT EXISTS messages (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    notebook_id  INTEGER NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
    role         TEXT NOT NULL,   -- user | assistant
    content      TEXT NOT NULL,
    sources      TEXT,            -- JSON
    created_at   TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);
CREATE INDEX IF NOT EXISTS idx_messages_nb ON messages(notebook_id);
"""

_write_lock = threading.Lock()


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(config.DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    config.ensure_dirs()
    with _connect() as conn:
        conn.execute("PRAGMA journal_mode = WAL")
        conn.executescript(SCHEMA)
        # 이전 실행 중 처리하다 꺼진 문서는 오류로 표시
        conn.execute(
            "UPDATE documents SET status='error', error='처리 중 프로그램이 종료되었습니다. 다시 올려주세요.' "
            "WHERE status='processing'"
        )


@contextmanager
def read() -> Iterator[sqlite3.Connection]:
    conn = _connect()
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def write() -> Iterator[sqlite3.Connection]:
    with _write_lock:
        conn = _connect()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
