"""웹 서버. 이 PC(127.0.0.1)에서만 접속할 수 있다."""
from __future__ import annotations

import json
import uuid
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import config, db, ollama_client, rag, system
from .parsers import SUPPORTED_EXTS

STATIC_DIR = Path(__file__).parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    yield


app = FastAPI(title="사내 문서 AI", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

_ALLOWED_HOSTS = {"127.0.0.1", "localhost", "testserver"}


@app.middleware("http")
async def local_only(request: Request, call_next):
    """다른 PC나 인터넷 웹페이지가 이 프로그램에 접근하지 못하게 막는다."""
    client = request.client.host if request.client else ""
    host = (request.headers.get("host") or "").split(":")[0]
    if client not in ("127.0.0.1", "::1", "testclient") or host not in _ALLOWED_HOSTS:
        return JSONResponse({"detail": "이 PC에서만 접속할 수 있습니다."}, status_code=403)
    if request.method not in ("GET", "HEAD", "OPTIONS"):
        origin = request.headers.get("origin")
        if origin and origin.split("://", 1)[-1].split(":")[0] not in _ALLOWED_HOSTS:
            return JSONResponse({"detail": "허용되지 않은 요청입니다."}, status_code=403)
    return await call_next(request)


# ---------------------------------------------------------------- 상태 / 설정

@app.get("/api/status")
def status():
    s = config.get_settings()
    try:
        models = ollama_client.list_models()
    except ollama_client.OllamaError as e:
        return {"ollama": False, "message": str(e), "models": [], "missing": [s.chat_model, s.embed_model]}

    missing = [m for m in (s.chat_model, s.embed_model) if not _installed(m, models)]
    return {"ollama": True, "models": models, "missing": missing, "chat_model": s.chat_model, "embed_model": s.embed_model}


@app.get("/api/ping")
def ping():
    return {"app": "local-doc-ai"}


@app.get("/api/setup")
def setup_info():
    """처음 실행 안내 화면용: PC 메모리, 필요한 모델, 설치 여부."""
    s = config.get_settings()
    info = {
        "ram_gb": round(system.total_ram_gb(), 1),
        "ollama_installed": system.find_ollama() is not None,
        "ollama_running": True,
        "required": [s.chat_model, s.embed_model],
        "missing": [],
        "sizes_gb": system.MODEL_SIZES_GB,
    }
    try:
        models = ollama_client.list_models()
    except ollama_client.OllamaError:
        info["ollama_running"] = False
        info["missing"] = info["required"]
        return info
    info["missing"] = [m for m in info["required"] if not _installed(m, models)]
    return info


@app.post("/api/setup/start-ollama")
def setup_start_ollama():
    return {"started": system.start_ollama()}


class PullIn(BaseModel):
    model: str = Field(min_length=1, max_length=200)


@app.post("/api/setup/pull")
def setup_pull(body: PullIn):
    s = config.get_settings()
    if body.model not in (s.chat_model, s.embed_model):
        raise HTTPException(400, "허용되지 않은 모델입니다.")

    def stream():
        try:
            for p in ollama_client.pull_stream(body.model):
                yield json.dumps({"type": "progress", **p}, ensure_ascii=False) + "\n"
            yield json.dumps({"type": "done"}) + "\n"
        except ollama_client.OllamaError as e:
            yield json.dumps({"type": "error", "message": str(e)}, ensure_ascii=False) + "\n"

    return StreamingResponse(stream(), media_type="application/x-ndjson")


def _installed(name: str, models: list[str]) -> bool:
    return any(m == name or m == f"{name}:latest" for m in models)


@app.get("/api/settings")
def get_settings():
    return asdict(config.get_settings())


class SettingsIn(BaseModel):
    chat_model: str | None = None
    top_k: int | None = Field(None, ge=1, le=12)
    num_ctx: int | None = Field(None, ge=2048, le=32768)
    temperature: float | None = Field(None, ge=0, le=1.5)
    min_score: float | None = Field(None, ge=0, le=1)


@app.put("/api/settings")
def put_settings(body: SettingsIn):
    return asdict(config.update_settings(body.model_dump(exclude_none=True)))


# ---------------------------------------------------------------- 노트북

class NotebookIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)


@app.get("/api/notebooks")
def list_notebooks():
    with db.read() as conn:
        rows = conn.execute(
            "SELECT n.*, (SELECT COUNT(*) FROM documents d WHERE d.notebook_id=n.id) AS doc_count "
            "FROM notebooks n ORDER BY n.id"
        ).fetchall()
    return [dict(r) for r in rows]


@app.post("/api/notebooks")
def create_notebook(body: NotebookIn):
    with db.write() as conn:
        cur = conn.execute("INSERT INTO notebooks (name) VALUES (?)", (body.name.strip(),))
    return {"id": cur.lastrowid, "name": body.name.strip()}


@app.patch("/api/notebooks/{nb_id}")
def rename_notebook(nb_id: int, body: NotebookIn):
    with db.write() as conn:
        conn.execute("UPDATE notebooks SET name=? WHERE id=?", (body.name.strip(), nb_id))
    return {"ok": True}


@app.delete("/api/notebooks/{nb_id}")
def delete_notebook(nb_id: int):
    with db.read() as conn:
        paths = [r[0] for r in conn.execute("SELECT stored_path FROM documents WHERE notebook_id=?", (nb_id,))]
    with db.write() as conn:
        conn.execute("DELETE FROM notebooks WHERE id=?", (nb_id,))
    for p in paths:
        Path(p).unlink(missing_ok=True)
    return {"ok": True}


def _require_notebook(nb_id: int) -> None:
    with db.read() as conn:
        if conn.execute("SELECT 1 FROM notebooks WHERE id=?", (nb_id,)).fetchone() is None:
            raise HTTPException(404, "노트북을 찾을 수 없습니다.")


# ---------------------------------------------------------------- 문서

@app.get("/api/notebooks/{nb_id}/documents")
def list_documents(nb_id: int):
    with db.read() as conn:
        rows = conn.execute(
            "SELECT id, filename, size_bytes, status, error, progress, chunk_count, created_at "
            "FROM documents WHERE notebook_id=? ORDER BY id",
            (nb_id,),
        ).fetchall()
    return [dict(r) for r in rows]


@app.post("/api/notebooks/{nb_id}/documents")
async def upload_documents(nb_id: int, files: list[UploadFile] = File(...)):
    _require_notebook(nb_id)
    limit = config.MAX_UPLOAD_MB * 1024 * 1024
    config.ensure_dirs()
    results = []
    for f in files:
        name = Path(f.filename or "문서").name
        ext = Path(name).suffix.lower()
        if ext not in SUPPORTED_EXTS:
            results.append({"filename": name, "error": f"지원하지 않는 형식입니다 ({ext or '확장자 없음'})"})
            continue
        dest = config.FILES_DIR / f"{uuid.uuid4().hex}{ext}"
        size = 0
        too_big = False
        with dest.open("wb") as out:
            while chunk := await f.read(1024 * 1024):
                size += len(chunk)
                if size > limit:
                    too_big = True
                    break
                out.write(chunk)
        if too_big:
            dest.unlink(missing_ok=True)
            results.append({"filename": name, "error": f"파일이 너무 큽니다 (최대 {config.MAX_UPLOAD_MB}MB)"})
            continue
        with db.write() as conn:
            cur = conn.execute(
                "INSERT INTO documents (notebook_id, filename, stored_path, size_bytes) VALUES (?,?,?,?)",
                (nb_id, name, str(dest), size),
            )
        rag.enqueue(cur.lastrowid)
        results.append({"filename": name, "id": cur.lastrowid})
    return results


@app.delete("/api/documents/{doc_id}")
def delete_document(doc_id: int):
    with db.read() as conn:
        row = conn.execute("SELECT stored_path FROM documents WHERE id=?", (doc_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "문서를 찾을 수 없습니다.")
    with db.write() as conn:
        conn.execute("DELETE FROM documents WHERE id=?", (doc_id,))
    Path(row["stored_path"]).unlink(missing_ok=True)
    return {"ok": True}


@app.get("/api/documents/{doc_id}/file")
def download_document(doc_id: int):
    with db.read() as conn:
        row = conn.execute("SELECT filename, stored_path FROM documents WHERE id=?", (doc_id,)).fetchone()
    if row is None or not Path(row["stored_path"]).exists():
        raise HTTPException(404, "문서를 찾을 수 없습니다.")
    return FileResponse(row["stored_path"], filename=row["filename"])


# ---------------------------------------------------------------- 대화

@app.get("/api/notebooks/{nb_id}/messages")
def list_messages(nb_id: int):
    with db.read() as conn:
        rows = conn.execute(
            "SELECT id, role, content, sources, created_at FROM messages WHERE notebook_id=? ORDER BY id",
            (nb_id,),
        ).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        d["sources"] = json.loads(d["sources"]) if d["sources"] else []
        out.append(d)
    return out


@app.delete("/api/notebooks/{nb_id}/messages")
def clear_messages(nb_id: int):
    with db.write() as conn:
        conn.execute("DELETE FROM messages WHERE notebook_id=?", (nb_id,))
    return {"ok": True}


class AskIn(BaseModel):
    question: str = Field(min_length=1, max_length=4000)
    document_ids: list[int]


@app.post("/api/notebooks/{nb_id}/ask")
def ask(nb_id: int, body: AskIn):
    _require_notebook(nb_id)
    with db.read() as conn:
        marks = ",".join("?" * len(body.document_ids)) or "NULL"
        allowed = [
            r[0]
            for r in conn.execute(
                f"SELECT id FROM documents WHERE notebook_id=? AND id IN ({marks})", (nb_id, *body.document_ids)
            )
        ]

    def stream():
        for event in rag.answer(nb_id, body.question.strip(), allowed):
            yield json.dumps(event, ensure_ascii=False) + "\n"

    return StreamingResponse(stream(), media_type="application/x-ndjson")


# ---------------------------------------------------------------- 화면

@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
