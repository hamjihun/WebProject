import json
from contextlib import contextmanager

import numpy as np
import pytest

from app import ollama_client


class FakeResponse:
    def __init__(self, status_code=200, lines=(), body=None):
        self.status_code = status_code
        self._lines = lines
        self._body = body or {}
        self.text = json.dumps(self._body)

    def iter_lines(self):
        yield from self._lines

    def read(self):
        return b""

    def json(self):
        return self._body


def test_chat_stream_disables_thinking_and_strips_tags(monkeypatch):
    sent = {}
    lines = [json.dumps({"message": {"content": c}}) for c in ["<think>음", "…</think>안녕", "하세요"]]
    lines.append(json.dumps({"done": True}))

    @contextmanager
    def fake_stream(method, url, json=None, timeout=None):
        sent.update(url=url, payload=json)
        yield FakeResponse(lines=lines)

    monkeypatch.setattr(ollama_client.httpx, "stream", fake_stream)
    out = "".join(ollama_client.chat_stream([{"role": "user", "content": "hi"}]))
    assert out == "안녕하세요"
    assert sent["url"].endswith("/api/chat")
    assert sent["payload"]["think"] is False
    assert sent["payload"]["options"]["num_ctx"] > 0


def test_chat_stream_missing_model_message(monkeypatch):
    @contextmanager
    def fake_stream(*a, **k):
        yield FakeResponse(404, body={"error": "model 'qwen3:4b' not found"})

    monkeypatch.setattr(ollama_client.httpx, "stream", fake_stream)
    with pytest.raises(ollama_client.OllamaError, match="ollama pull qwen3:4b"):
        list(ollama_client.chat_stream([]))


def test_embed_normalizes(monkeypatch):
    monkeypatch.setattr(
        ollama_client.httpx, "post",
        lambda *a, **k: FakeResponse(body={"embeddings": [[3.0, 4.0], [0.0, 0.0]]}),
    )
    v = ollama_client.embed(["a", "b"])
    assert np.allclose(v[0], [0.6, 0.8])
    assert np.allclose(v[1], [0, 0])


def test_pull_stream_sums_layers(monkeypatch):
    lines = [
        json.dumps({"status": "pulling manifest"}),
        json.dumps({"status": "pulling a", "digest": "a", "total": 100, "completed": 50}),
        json.dumps({"status": "pulling b", "digest": "b", "total": 300, "completed": 0}),
        json.dumps({"status": "pulling b", "digest": "b", "total": 300, "completed": 300}),
        json.dumps({"status": "success"}),
    ]

    @contextmanager
    def fake_stream(method, url, json=None, timeout=None):
        assert url.endswith("/api/pull") and json["model"] == "bge-m3"
        yield FakeResponse(lines=lines)

    monkeypatch.setattr(ollama_client.httpx, "stream", fake_stream)
    events = list(ollama_client.pull_stream("bge-m3"))
    assert events[2] == {"status": "pulling b", "completed": 50, "total": 400}
    assert events[-1] == {"status": "success", "completed": 350, "total": 400}
