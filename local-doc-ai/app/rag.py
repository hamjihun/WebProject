"""문서 등록(파싱→조각→임베딩)과 질문 답변(검색→프롬프트→생성)."""
from __future__ import annotations

import json
import queue
import re
import threading
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import numpy as np

from . import db, ollama_client
from .chunker import chunk_blocks
from .config import get_settings
from .parsers import ParseError, parse_file

EMBED_BATCH = 16

# ---------------------------------------------------------------- 문서 등록

# 노트북 PC 부담을 줄이려고 문서는 한 번에 하나씩 처리한다
_jobs: "queue.Queue[int]" = queue.Queue()
_worker: threading.Thread | None = None


def enqueue(doc_id: int) -> None:
    global _worker
    _jobs.put(doc_id)
    if _worker is None or not _worker.is_alive():
        _worker = threading.Thread(target=_work, daemon=True, name="ingest")
        _worker.start()


def _work() -> None:
    while True:
        doc_id = _jobs.get()
        try:
            ingest(doc_id)
        finally:
            _jobs.task_done()


def _set_status(doc_id: int, **fields) -> None:
    cols = ", ".join(f"{k}=?" for k in fields)
    with db.write() as conn:
        conn.execute(f"UPDATE documents SET {cols} WHERE id=?", (*fields.values(), doc_id))


def ingest(doc_id: int) -> None:
    with db.read() as conn:
        row = conn.execute("SELECT * FROM documents WHERE id=?", (doc_id,)).fetchone()
    if row is None:
        return
    s = get_settings()
    try:
        blocks = parse_file(Path(row["stored_path"]), row["filename"], s.chunk_chars)
        chunks = chunk_blocks(blocks, s.chunk_chars, s.chunk_overlap)
        vectors: list[np.ndarray] = []
        for i in range(0, len(chunks), EMBED_BATCH):
            batch = chunks[i : i + EMBED_BATCH]
            vectors.append(ollama_client.embed([f"{row['filename']} {c.location}\n{c.text}" for c in batch]))
            _set_status(doc_id, progress=min(0.99, (i + len(batch)) / len(chunks)))
            if not _doc_exists(doc_id):  # 처리 중에 삭제됨
                return
        emb = np.vstack(vectors)
        with db.write() as conn:
            if conn.execute("SELECT 1 FROM documents WHERE id=?", (doc_id,)).fetchone() is None:
                return
            conn.execute("DELETE FROM chunks WHERE document_id=?", (doc_id,))
            conn.executemany(
                "INSERT INTO chunks (document_id, seq, location, text, embedding) VALUES (?,?,?,?,?)",
                [(doc_id, n, c.location, c.text, emb[n].tobytes()) for n, c in enumerate(chunks)],
            )
            conn.execute(
                "UPDATE documents SET status='ready', progress=1, chunk_count=?, error=NULL WHERE id=?",
                (len(chunks), doc_id),
            )
    except (ParseError, ollama_client.OllamaError) as e:
        _set_status(doc_id, status="error", error=str(e))
    except Exception as e:
        traceback.print_exc()
        _set_status(doc_id, status="error", error=f"처리 중 오류: {e}")


def _doc_exists(doc_id: int) -> bool:
    with db.read() as conn:
        return conn.execute("SELECT 1 FROM documents WHERE id=?", (doc_id,)).fetchone() is not None


# ---------------------------------------------------------------- 검색

@dataclass
class Hit:
    chunk_id: int
    document_id: int
    filename: str
    location: str
    text: str
    score: float


_PARTICLES = ("으로", "에서", "에게", "까지", "부터", "은", "는", "이", "가", "을", "를", "에", "의", "로", "와", "과", "도", "만")


def _keywords(q: str) -> list[str]:
    out = []
    for w in re.findall(r"[0-9A-Za-z가-힣]{2,}", q):
        for p in _PARTICLES:
            if len(w) > len(p) + 1 and w.endswith(p):
                w = w[: -len(p)]
                break
        out.append(w.lower())
    return list(dict.fromkeys(out))


def search(doc_ids: list[int], query: str, top_k: int | None = None) -> list[Hit]:
    s = get_settings()
    top_k = top_k or s.top_k
    if not doc_ids:
        return []
    marks = ",".join("?" * len(doc_ids))
    with db.read() as conn:
        rows = conn.execute(
            f"SELECT c.id, c.document_id, d.filename, c.location, c.text, c.embedding "
            f"FROM chunks c JOIN documents d ON d.id = c.document_id "
            f"WHERE d.status='ready' AND c.document_id IN ({marks})",
            doc_ids,
        ).fetchall()
    if not rows:
        return []
    qv = ollama_client.embed([query])[0]
    mat = np.vstack([np.frombuffer(r["embedding"], dtype=np.float32) for r in rows])
    scores = mat @ qv

    # 이름·숫자·코드처럼 정확히 일치해야 하는 단어가 들어 있으면 가산점
    kws = _keywords(query)
    if kws:
        for i, r in enumerate(rows):
            low = r["text"].lower()
            matched = sum(1 for k in kws if k in low)
            scores[i] += 0.15 * matched / len(kws)

    order = np.argsort(-scores)[:top_k]
    return [
        Hit(rows[i]["id"], rows[i]["document_id"], rows[i]["filename"], rows[i]["location"], rows[i]["text"], float(scores[i]))
        for i in order
        if scores[i] >= s.min_score
    ]


# ---------------------------------------------------------------- 답변

SYSTEM_PROMPT = """당신은 회사 내부 문서를 바탕으로 업무 질문에 답하는 도우미입니다.
규칙:
1. 반드시 아래 [자료]에 적힌 내용만 근거로 답하세요. 자료에 없는 내용은 절대 지어내지 마세요.
2. 자료에서 답을 찾을 수 없으면 "업로드한 문서에서 관련 내용을 찾을 수 없습니다."라고만 답하세요.
3. 근거로 쓴 문장 끝에 자료 번호를 [1], [2] 처럼 표시하세요.
4. 숫자, 날짜, 금액, 이름은 자료에 적힌 그대로 옮기세요.
5. 한국어로 간결하고 명확하게 답하고, 필요하면 목록이나 표로 정리하세요."""

NOT_FOUND = "업로드한 문서에서 관련 내용을 찾을 수 없습니다. 질문을 조금 더 구체적으로 바꾸거나, 관련 문서가 선택되어 있는지 확인해 주세요."


def build_messages(question: str, hits: list[Hit], history: list[dict]) -> list[dict]:
    refs = "\n\n".join(f"[{n}] ({h.filename}, {h.location})\n{h.text}" for n, h in enumerate(hits, start=1))
    msgs = [{"role": "system", "content": SYSTEM_PROMPT}]
    # 이전 대화 두 번까지만 넣는다 (노트북에서 속도 유지)
    for m in history[-4:]:
        msgs.append({"role": m["role"], "content": m["content"]})
    msgs.append({"role": "user", "content": f"[자료]\n{refs}\n\n[질문]\n{question}"})
    return msgs


def answer(notebook_id: int, question: str, doc_ids: list[int]) -> Iterator[dict]:
    """화면으로 보낼 이벤트를 차례로 돌려준다: sources → token… → done (또는 error)."""
    with db.read() as conn:
        history = [
            dict(r)
            for r in conn.execute(
                "SELECT role, content FROM messages WHERE notebook_id=? ORDER BY id DESC LIMIT 4",
                (notebook_id,),
            ).fetchall()
        ][::-1]
    try:
        # 짧은 후속 질문("그럼 2분기는?")은 앞 질문과 합쳐서 검색한다
        last_q = next((m["content"] for m in reversed(history) if m["role"] == "user"), "")
        query = f"{last_q}\n{question}" if last_q and len(question) < 25 else question
        hits = search(doc_ids, query)
    except ollama_client.OllamaError as e:
        yield {"type": "error", "message": str(e)}
        return

    sources = [
        {"n": n, "document_id": h.document_id, "filename": h.filename, "location": h.location,
         "text": h.text, "score": round(h.score, 3)}
        for n, h in enumerate(hits, start=1)
    ]
    yield {"type": "sources", "sources": sources}

    parts: list[str] = []
    if not hits:
        parts.append(NOT_FOUND)
        yield {"type": "token", "text": NOT_FOUND}
    else:
        try:
            for piece in ollama_client.chat_stream(build_messages(question, hits, history)):
                parts.append(piece)
                yield {"type": "token", "text": piece}
        except ollama_client.OllamaError as e:
            yield {"type": "error", "message": str(e)}
            if not parts:
                return

    content = "".join(parts).strip()
    with db.write() as conn:
        conn.execute(
            "INSERT INTO messages (notebook_id, role, content) VALUES (?, 'user', ?)", (notebook_id, question)
        )
        cur = conn.execute(
            "INSERT INTO messages (notebook_id, role, content, sources) VALUES (?, 'assistant', ?, ?)",
            (notebook_id, content, json.dumps(sources, ensure_ascii=False)),
        )
    yield {"type": "done", "message_id": cur.lastrowid}
