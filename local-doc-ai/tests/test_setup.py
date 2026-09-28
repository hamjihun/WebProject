import json

from fastapi.testclient import TestClient

from app import ollama_client, system
from app.main import app


def test_recommended_profile_by_ram():
    assert system.recommended_profile(16)["chat_model"] == "qwen3:4b-instruct"
    assert system.recommended_profile(15.7)["chat_model"] == "qwen3:4b-instruct"
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
        assert events == [{"type": "progress", "status": "pulling", "completed": 1, "total": 2}, {"type": "done", "model": "bge-m3"}]
        # 설정에 없는 임의 모델은 받지 않는다
        assert client.post("/api/setup/pull", json={"model": "llama3:70b"}).status_code == 400


def test_pull_falls_back_when_model_name_missing(fake_ollama, monkeypatch):
    from app import config

    pulled = []

    def fake_pull(model):
        pulled.append(model)
        if model == "qwen3:4b-instruct":
            raise ollama_client.OllamaError("pull model manifest: file does not exist")
        yield {"status": "success", "completed": 1, "total": 1}

    monkeypatch.setattr(ollama_client, "pull_stream", fake_pull)
    old = config.get_settings().chat_model
    config.update_settings({"chat_model": "qwen3:4b-instruct"})
    try:
        with TestClient(app) as client:
            r = client.post("/api/setup/pull", json={"model": "qwen3:4b-instruct"})
            events = [json.loads(l) for l in r.text.splitlines()]
        assert pulled == ["qwen3:4b-instruct", "qwen3:4b-instruct-2507-q4_K_M"]
        assert {"type": "switched", "model": "qwen3:4b-instruct-2507-q4_K_M"} in events
        assert config.get_settings().chat_model == "qwen3:4b-instruct-2507-q4_K_M"
    finally:
        config.update_settings({"chat_model": old})


def test_old_default_model_is_migrated(tmp_path, monkeypatch):
    from app import config

    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"chat_model": "qwen3:4b", "top_k": 3}), encoding="utf-8")
    monkeypatch.setattr(config, "SETTINGS_PATH", path)
    monkeypatch.setattr(config, "_settings", None)
    s = config.get_settings()
    assert s.chat_model == "qwen3:4b-instruct" and s.top_k == 3
    assert json.loads(path.read_text(encoding="utf-8"))["chat_model"] == "qwen3:4b-instruct"
