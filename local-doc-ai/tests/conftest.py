import hashlib
import os
import sys
import tempfile
from pathlib import Path

import numpy as np
import pytest

os.environ["DOCAI_DATA_DIR"] = tempfile.mkdtemp(prefix="docai-test-")
os.environ["DOCAI_CHAT_MODEL"] = "qwen3:4b"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import ollama_client  # noqa: E402

DIM = 256


def fake_embed(texts):
    """글자 2-gram 해시로 만든 가짜 임베딩. 겹치는 글자가 많을수록 유사도가 높다."""
    out = np.zeros((len(texts), DIM), dtype=np.float32)
    for i, t in enumerate(texts):
        t = t.lower()
        for a, b in zip(t, t[1:]):
            h = int(hashlib.md5((a + b).encode()).hexdigest(), 16) % DIM
            out[i, h] += 1
    norms = np.linalg.norm(out, axis=1, keepdims=True)
    norms[norms == 0] = 1
    return out / norms


class FakeChat:
    def __init__(self):
        self.calls = []

    def __call__(self, messages):
        self.calls.append(messages)
        yield "답변입니다 "
        yield "[1]"


@pytest.fixture
def fake_ollama(monkeypatch):
    chat = FakeChat()
    monkeypatch.setattr(ollama_client, "embed", fake_embed)
    monkeypatch.setattr(ollama_client, "chat_stream", chat)
    monkeypatch.setattr(ollama_client, "list_models", lambda: ["qwen3:4b", "bge-m3:latest"])
    return chat
