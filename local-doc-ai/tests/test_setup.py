import json

from fastapi.testclient import TestClient

from app import ollama_client, system
from app.main import app


def test_recommended_profile_by_ram():
    assert system.recommended_profile(16)["chat_model"] == "qwen3:4b"
    assert system.recommended_profile(15.7)["chat_model"] == "qwen3:4b"
    small = system.recommended_profile(8)
    assert small["chat_model"] == "qwen3:1.7b" and small["num_ctx"] == 4096


def test_setup_info_when_ollama_down(monkeypatch):
    def down():
        raise ollama_client.OllamaError("x")

    monkeypatch.setattr(ollama_client, "list_models", down)
    with TestClient(app) as client:
        info = client.get("/api/setup").json()
        assert info["ollama_running"] is False
        assert info["missing"] == ["qwen3:4b", "bge-m3"]
        assert client.get("/api/ping").json() == {"app": "local-doc-ai"}


def test_setup_pull_streams_progress(fake_ollama, monkeypatch):
    monkeypatch.setattr(
        ollama_client, "pull_stream",
        lambda model: iter([{"status": "pulling", "completed": 1, "total": 2}]),
    )
    with TestClient(app) as client:
        assert client.get("/api/setup").json()["missing"] == []
        r = client.post("/api/setup/pull", json={"model": "bge-m3"})
        events = [json.loads(l) for l in r.text.splitlines()]
        assert events == [{"type": "progress", "status": "pulling", "completed": 1, "total": 2}, {"type": "done"}]
        # 설정에 없는 임의 모델은 받지 않는다
        assert client.post("/api/setup/pull", json={"model": "llama3:70b"}).status_code == 400
