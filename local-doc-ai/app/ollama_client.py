"""이 PC에서 실행 중인 Ollama 와 통신한다. 외부 인터넷으로는 아무것도 보내지 않는다."""
from __future__ import annotations

import json
from typing import Iterator

import httpx
import numpy as np

from .config import get_settings


class OllamaError(Exception):
    pass


def _url(path: str) -> str:
    return get_settings().ollama_url.rstrip("/") + path


def list_models() -> list[str]:
    try:
        r = httpx.get(_url("/api/tags"), timeout=5)
        r.raise_for_status()
    except httpx.HTTPError as e:
        raise OllamaError("Ollama에 연결할 수 없습니다. Ollama가 실행 중인지 확인해 주세요.") from e
    return sorted(m["name"] for m in r.json().get("models", []))


def embed(texts: list[str]) -> np.ndarray:
    """정규화된 float32 벡터 (len(texts), dim) 를 돌려준다."""
    s = get_settings()
    try:
        r = httpx.post(
            _url("/api/embed"),
            json={"model": s.embed_model, "input": texts, "truncate": True},
            timeout=600,
        )
    except httpx.HTTPError as e:
        raise OllamaError(f"임베딩 요청 실패: {e}") from e
    if r.status_code != 200:
        raise OllamaError(_err_msg(r, s.embed_model))
    vecs = np.asarray(r.json()["embeddings"], dtype=np.float32)
    norms = np.linalg.norm(vecs, axis=1, keepdims=True)
    norms[norms == 0] = 1
    return vecs / norms


# 생각(thinking) 과정을 먼저 길게 출력하는 모델. 노트북에서는 너무 느려서 끈다.
_THINKING_PREFIXES = ("qwen3", "deepseek-r1", "magistral", "gpt-oss")


def chat_stream(messages: list[dict]) -> Iterator[str]:
    s = get_settings()
    payload = {
        "model": s.chat_model,
        "messages": messages,
        "stream": True,
        "options": {"num_ctx": s.num_ctx, "temperature": s.temperature},
    }
    if s.chat_model.lower().startswith(_THINKING_PREFIXES):
        payload["think"] = False
    try:
        with httpx.stream("POST", _url("/api/chat"), json=payload, timeout=httpx.Timeout(600, connect=5)) as r:
            if r.status_code != 200:
                r.read()
                raise OllamaError(_err_msg(r, s.chat_model))
            yield from strip_think(_content_pieces(r))
    except httpx.HTTPError as e:
        raise OllamaError(f"AI 모델 요청 실패: {e}") from e


def pull_stream(model: str) -> Iterator[dict]:
    """모델 다운로드. {"status", "completed", "total"} 진행 상황을 차례로 돌려준다 (바이트 단위, 전체 합계)."""
    layers: dict[str, tuple[int, int]] = {}
    try:
        with httpx.stream(
            "POST", _url("/api/pull"), json={"model": model, "stream": True},
            timeout=httpx.Timeout(None, connect=5),
        ) as r:
            if r.status_code != 200:
                r.read()
                raise OllamaError(_err_msg(r, model))
            for line in r.iter_lines():
                if not line:
                    continue
                data = json.loads(line)
                if data.get("error"):
                    raise OllamaError(f"'{model}' 다운로드 실패: {data['error']}")
                if data.get("digest") and data.get("total"):
                    layers[data["digest"]] = (data.get("completed", 0), data["total"])
                done = sum(c for c, _ in layers.values())
                total = sum(t for _, t in layers.values())
                yield {"status": data.get("status", ""), "completed": done, "total": total}
    except httpx.HTTPError as e:
        raise OllamaError(f"'{model}' 다운로드 실패: {e}") from e


def _content_pieces(r: httpx.Response) -> Iterator[str]:
    for line in r.iter_lines():
        if not line:
            continue
        data = json.loads(line)
        if data.get("error"):
            raise OllamaError(data["error"])
        piece = data.get("message", {}).get("content", "")
        if piece:
            yield piece
        if data.get("done"):
            break


def strip_think(pieces: Iterator[str]) -> Iterator[str]:
    """일부 모델이 본문에 섞어 보내는 <think>...</think> 부분을 걸러낸다."""
    in_think = False
    for piece in pieces:
        while piece:
            if in_think:
                end = piece.find("</think>")
                if end < 0:
                    piece = ""
                else:
                    in_think, piece = False, piece[end + 8 :]
            else:
                start = piece.find("<think>")
                if start < 0:
                    yield piece
                    piece = ""
                else:
                    if start:
                        yield piece[:start]
                    in_think, piece = True, piece[start + 7 :]


def _err_msg(r: httpx.Response, model: str) -> str:
    try:
        msg = r.json().get("error", r.text)
    except ValueError:
        msg = r.text
    if r.status_code == 404 or "not found" in msg.lower():
        return f"'{model}' 모델이 설치되어 있지 않습니다. 명령 프롬프트에서 'ollama pull {model}' 을 실행해 주세요."
    return f"Ollama 오류 ({r.status_code}): {msg}"
