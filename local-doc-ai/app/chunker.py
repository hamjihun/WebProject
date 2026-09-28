"""Block 을 검색 단위인 조각(chunk)으로 나눈다."""
from __future__ import annotations

import re
from dataclasses import dataclass

from .parsers import Block


@dataclass
class Chunk:
    location: str
    text: str


def _split_units(text: str, max_chars: int) -> list[str]:
    """줄 → 문장 → 글자 순서로, max_chars 이하 단위가 될 때까지 쪼갠다."""
    units: list[str] = []
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        if len(line) <= max_chars:
            units.append(line)
            continue
        for sent in re.split(r"(?<=[.!?。])\s+|(?<=다\.)\s*", line):
            sent = sent.strip()
            while len(sent) > max_chars:
                units.append(sent[:max_chars])
                sent = sent[max_chars:]
            if sent:
                units.append(sent)
    return units


def chunk_blocks(blocks: list[Block], chunk_chars: int = 700, overlap: int = 100) -> list[Chunk]:
    chunks: list[Chunk] = []
    for b in blocks:
        body_max = max(100, chunk_chars - len(b.prefix))
        if len(b.text) <= body_max:
            chunks.append(Chunk(b.location, b.prefix + b.text))
            continue
        units = _split_units(b.text, body_max)
        cur: list[str] = []
        size = 0
        for u in units:
            if cur and size + len(u) + 1 > body_max:
                chunks.append(Chunk(b.location, b.prefix + "\n".join(cur)))
                # 앞 조각의 끝부분을 조금 겹쳐서 문맥이 끊기지 않게 한다
                keep: list[str] = []
                kept = 0
                for prev in reversed(cur):
                    if kept + len(prev) > overlap:
                        break
                    keep.insert(0, prev)
                    kept += len(prev) + 1
                cur, size = keep, kept
            cur.append(u)
            size += len(u) + 1
        if cur:
            chunks.append(Chunk(b.location, b.prefix + "\n".join(cur)))
    return chunks
