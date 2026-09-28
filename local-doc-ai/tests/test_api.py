import io
import json
import time

import openpyxl
from fastapi.testclient import TestClient

from app import rag
from app.main import app


def _xlsx_bytes():
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "거래처"
    ws.append(["거래처명", "담당자", "연락처"])
    ws.append(["한빛상사", "김민수", "02-111-2222"])
    ws.append(["누리산업", "이서연", "031-333-4444"])
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def _wait_ready(client, nb_id, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        docs = client.get(f"/api/notebooks/{nb_id}/documents").json()
        if docs and all(d["status"] != "processing" for d in docs):
            return docs
        time.sleep(0.05)
    raise AssertionError("문서 처리가 끝나지 않음")


def _ask(client, nb_id, question, doc_ids):
    r = client.post(f"/api/notebooks/{nb_id}/ask", json={"question": question, "document_ids": doc_ids})
    assert r.status_code == 200
    return [json.loads(l) for l in r.text.splitlines() if l.strip()]


def test_upload_ask_and_history(fake_ollama):
    with TestClient(app) as client:
        nb = client.post("/api/notebooks", json={"name": "영업"}).json()
        files = [
            ("files", ("거래처.xlsx", _xlsx_bytes(), "application/octet-stream")),
            ("files", ("악성.exe", b"MZ", "application/octet-stream")),
        ]
        res = client.post(f"/api/notebooks/{nb['id']}/documents", files=files).json()
        assert "id" in res[0] and "error" in res[1]

        docs = _wait_ready(client, nb["id"])
        assert docs[0]["status"] == "ready", docs[0]["error"]
        assert docs[0]["chunk_count"] == 1

        events = _ask(client, nb["id"], "누리산업 담당자 연락처 알려줘", [docs[0]["id"]])
        assert events[0]["type"] == "sources"
        src = events[0]["sources"][0]
        assert src["filename"] == "거래처.xlsx"
        assert src["location"] == "시트 '거래처' 2~3행"
        text = "".join(e["text"] for e in events if e["type"] == "token")
        assert text == "답변입니다 [1]"
        assert events[-1]["type"] == "done"

        prompt = fake_ollama.calls[-1][-1]["content"]
        assert "[1] (거래처.xlsx, 시트 '거래처' 2~3행)" in prompt
        assert "누리산업" in prompt

        msgs = client.get(f"/api/notebooks/{nb['id']}/messages").json()
        assert [m["role"] for m in msgs] == ["user", "assistant"]
        assert msgs[1]["sources"][0]["location"] == "시트 '거래처' 2~3행"

        # 다른 노트북의 문서 id 는 무시된다
        other = client.post("/api/notebooks", json={"name": "다른"}).json()
        events = _ask(client, other["id"], "누리산업", [docs[0]["id"]])
        assert events[0]["sources"] == []
        assert "찾을 수 없습니다" in events[1]["text"]

        assert client.delete(f"/api/documents/{docs[0]['id']}").status_code == 200
        assert client.get(f"/api/notebooks/{nb['id']}/documents").json() == []


def test_unparseable_file_marked_error(fake_ollama):
    with TestClient(app) as client:
        nb = client.post("/api/notebooks", json={"name": "오류"}).json()
        client.post(f"/api/notebooks/{nb['id']}/documents",
                    files=[("files", ("깨진.xlsx", b"not a zip", "application/octet-stream"))])
        docs = _wait_ready(client, nb["id"])
        assert docs[0]["status"] == "error"
        assert "읽을 수 없습니다" in docs[0]["error"]


def test_only_local_host_and_origin_allowed(fake_ollama):
    with TestClient(app) as client:
        assert client.get("/api/notebooks", headers={"host": "evil.example.com"}).status_code == 403
        r = client.post("/api/notebooks", json={"name": "x"}, headers={"origin": "https://evil.example.com"})
        assert r.status_code == 403
        r = client.post("/api/notebooks", json={"name": "x"}, headers={"origin": "http://127.0.0.1:8765"})
        assert r.status_code == 200


def test_status_reports_missing_models(fake_ollama, monkeypatch):
    with TestClient(app) as client:
        assert client.get("/api/status").json()["missing"] == []
        monkeypatch.setattr(rag.ollama_client, "list_models", lambda: ["bge-m3:latest"])
        assert client.get("/api/status").json()["missing"] == ["qwen3:4b"]


def test_keywords_strip_particles():
    assert rag._keywords("누리산업의 담당자는 누구야") == ["누리산업", "담당자", "누구야"]


def test_untagged_thinking_is_removed(fake_ollama, monkeypatch):
    def thinking_chat(messages):
        yield "Okay, the user asks about "
        yield "누리산업. Let me check.</th"
        yield "ink>\n\n담당자는 이서연입니다 [1]"

    monkeypatch.setattr(rag.ollama_client, "chat_stream", thinking_chat)
    with TestClient(app) as client:
        nb = client.post("/api/notebooks", json={"name": "생각"}).json()
        client.post(f"/api/notebooks/{nb['id']}/documents",
                    files=[("files", ("거래처.xlsx", _xlsx_bytes(), "application/octet-stream"))])
        docs = _wait_ready(client, nb["id"])
        events = _ask(client, nb["id"], "누리산업 담당자", [docs[0]["id"]])
        resets = [e for e in events if e["type"] == "reset"]
        assert resets == [{"type": "reset", "text": "담당자는 이서연입니다 [1]"}]
        msgs = client.get(f"/api/notebooks/{nb['id']}/messages").json()
        assert msgs[-1]["content"] == "담당자는 이서연입니다 [1]"
