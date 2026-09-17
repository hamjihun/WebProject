#!/usr/bin/env python3
"""여러 문서를 NotebookLM용 '출처 추적 가능한' 코퍼스로 묶는다.

파일을 하나씩 변환해서 50개를 따로 올리는 대신, 내용을 몇 개의 마크다운
문서로 묶는다. 대신 모든 표 행과 모든 단락에 출처 표시를 붙여서, NotebookLM이
어떤 문장을 인용하든 그 문장이 원래 어느 파일 몇 번째 행에서 왔는지 드러난다.

  [S07-1:14]  = 7번 원본 파일, 1번째 시트, 원본 14행
  [S12·3]     = 12번 원본 파일, 3번째 단락

출력물
  00_출처목록.md   ID -> 원본 경로/형식/분량 대응표 (이것도 같이 업로드한다)
  01_자료.md ...   내용 본문. --per-file 로 몇 개씩 묶을지 조절한다.

사용법
  python3 build_corpus.py ./원본폴더 -o ./corpus
  python3 build_corpus.py 자료.zip -o ./corpus          # zip 안의 폴더 구조를 경로로 쓴다
  python3 build_corpus.py ./원본폴더 -o ./corpus --per-file 5
"""

from __future__ import annotations

import argparse
import csv
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert import (  # noqa: E402
    AUDIO_EXT, DOC_EXT, FLAT_EXT, SHEET_EXT, SLIDE_EXT,
    md_cell, run, safe_name, soffice_convert,
)

PDFTOTEXT = shutil.which("pdftotext")


@dataclass
class Source:
    sid: str
    path: str                      # 원본 상대 경로 (출처 표시에 쓴다)
    file: Path                     # 실제 읽을 위치
    kind: str = ""
    title: str = ""
    detail: str = ""
    lines: list[str] = field(default_factory=list)
    doc: str = ""                  # 수록된 출력 파일명
    error: str = ""


# ------------------------------------------------------------------ 표 추출
def strip_layout(rows: list[list]) -> tuple[list[list[str]], list[int], list[str]]:
    """빈 행/열과 표 위 제목을 걷어낸다. (정리된 행, 원본 행번호, 제목들)"""
    numbered = [(i + 1, r) for i, r in enumerate(rows)]
    numbered = [(n, r) for n, r in numbered if any(md_cell(c) for c in r)]
    if not numbered:
        return [], [], []

    width = max(len(r) for _, r in numbered)
    keep = [i for i in range(width)
            if any(md_cell(r[i]) if i < len(r) else "" for _, r in numbered)]

    def cells(row):
        return [md_cell(row[i]) if i < len(row) else "" for i in keep]

    captions: list[str] = []
    while len(numbered) >= 2:
        first = [c for c in cells(numbered[0][1]) if c]
        second = [c for c in cells(numbered[1][1]) if c]
        if len(first) == 1 and len(first) < len(second):
            captions.append(first[0])
            numbered.pop(0)
        else:
            break

    return ([cells(r) for _, r in numbered],
            [n for n, _ in numbered], captions)


def sheet_block(sid: str, idx: int, sheet: str, rows: list[list]) -> list[str]:
    """시트 하나를 출처 열이 붙은 마크다운 표로."""
    body, rownums, captions = strip_layout(rows)
    if not body:
        return []

    head, first_data = body[0], 1
    if not all(head):  # 첫 행이 온전한 헤더가 아니면 열 번호를 쓴다
        head = [f"col{i + 1}" for i in range(len(body[0]))]
        first_data = 0

    out = [f"### [{sid}-{idx}] 시트 「{sheet}」", ""]
    for caption in captions:
        out += [f"**{caption}**", ""]
    out += ["| 출처 | " + " | ".join(head) + " |",
            "| --- | " + " | ".join("---" for _ in head) + " |"]
    for row, rownum in zip(body[first_data:], rownums[first_data:]):
        if not any(row):
            continue
        row = row + [""] * (len(head) - len(row))
        out.append(f"| {sid}-{idx}:{rownum}행 | " + " | ".join(row[:len(head)]) + " |")
    out.append("")
    return out


def read_spreadsheet(src: Source) -> None:
    import openpyxl

    work, tmp = src.file, None
    if src.file.suffix.lower() == ".xls":
        tmp = tempfile.TemporaryDirectory()
        converted = soffice_convert(src.file, "xlsx", Path(tmp.name))
        if not converted:
            src.error = ".xls -> .xlsx 변환 실패"
            tmp.cleanup()
            return
        work = converted

    try:
        wb = openpyxl.load_workbook(work, data_only=True, read_only=True)
        raw = openpyxl.load_workbook(work, data_only=False, read_only=True)
        blocks: list[str] = []
        used, empty, total = [], [], 0
        for idx, ws in enumerate(wb.worksheets, 1):
            rows = [list(r) for r in ws.iter_rows(values_only=True)]
            if ws.title in raw.sheetnames:  # 캐시된 값이 없는 셀은 수식으로 채운다
                fb = [list(r) for r in raw[ws.title].iter_rows(values_only=True)]
                for y, row in enumerate(rows):
                    if y >= len(fb):
                        break
                    for x, cell in enumerate(row):
                        if cell is None and x < len(fb[y]):
                            row[x] = fb[y][x]
            block = sheet_block(src.sid, idx, ws.title, rows)
            if not block:
                empty.append(ws.title)
                continue
            _, _, captions = strip_layout(rows)
            if not src.title and captions:
                src.title = captions[0]
            used.append(ws.title)
            total += sum(1 for line in block if line.startswith("| ")) - 2
            blocks += block
        wb.close()
        raw.close()
    except Exception as exc:  # noqa: BLE001
        src.error = f"읽기 실패: {exc}"
        return
    finally:
        if tmp:
            tmp.cleanup()

    src.kind = f"엑셀 ({src.file.suffix.lower()})"
    src.detail = f"시트 {len(used)}개, 데이터 {total}행"
    if empty:
        src.detail += f" (빈 시트 {len(empty)}개 제외)"
    src.lines = blocks


def read_flat(src: Source) -> None:
    delim = "\t" if src.file.suffix.lower() == ".tsv" else ","
    for enc in ("utf-8-sig", "cp949", "euc-kr", "utf-16", "latin-1"):
        try:
            with src.file.open(newline="", encoding=enc) as fh:
                rows = [list(r) for r in csv.reader(fh, delimiter=delim)]
            break
        except (UnicodeDecodeError, UnicodeError):
            continue
    else:
        src.error = "인코딩 판별 실패"
        return
    src.kind = f"표 ({src.file.suffix.lower()}, {enc})"
    src.lines = sheet_block(src.sid, 1, src.file.stem, rows)
    src.detail = f"데이터 {max(0, sum(1 for l in src.lines if l.startswith('| ')) - 2)}행"


# ------------------------------------------------------------------ 본문 추출
def tag_paragraphs(sid: str, paragraphs: list[str]) -> list[str]:
    """단락마다 출처 번호를 붙인다."""
    out: list[str] = []
    for n, para in enumerate((p.replace("\ufeff", "").strip() for p in paragraphs), 1):
        if para:
            out += [f"[{sid}·{n}] {para}", ""]
    return out


def read_hwp(src: Source) -> None:
    text = ""
    hwp5txt = shutil.which("hwp5txt")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out.txt"
        if hwp5txt and run([hwp5txt, "--output", str(out), str(src.file)]).returncode == 0:
            text = out.read_text(encoding="utf-8", errors="replace")
        if not text.strip():  # 폴백: pyhwp odt -> LibreOffice txt
            hwp5odt = shutil.which("hwp5odt")
            odt = Path(tmp) / "out.odt"
            if hwp5odt and run([hwp5odt, "--output", str(odt), str(src.file)]).returncode == 0:
                made = soffice_convert(odt, "txt:Text (encoded):UTF8", Path(tmp))
                if made:
                    text = made.read_text(encoding="utf-8", errors="replace")
        if not text.strip():  # 폴백: 구형 HWP 97 필터
            made = soffice_convert(src.file, "txt:Text (encoded):UTF8", Path(tmp),
                                   infilter="writer_MIZI_Hwp_97")
            if made:
                text = made.read_text(encoding="utf-8", errors="replace")

    if not text.strip():
        src.error = "한글 파일을 열 수 없음 (암호 설정 또는 손상 여부 확인)"
        return
    paragraphs = text.splitlines()
    src.kind = "한글 (.hwp)"
    src.lines = tag_paragraphs(src.sid, paragraphs)
    src.detail = f"{len(src.lines) // 2}단락"


def read_hwpx(src: Source) -> None:
    from xml.etree import ElementTree
    try:
        with zipfile.ZipFile(src.file) as zf:
            names = sorted(n for n in zf.namelist()
                           if n.startswith("Contents/section") and n.endswith(".xml"))
            paragraphs = []
            for name in names:
                root = ElementTree.fromstring(zf.read(name))
                for para in root.iter():
                    if para.tag.endswith("}p"):
                        paragraphs.append("".join(t.text or "" for t in para.iter()
                                                  if t.tag.endswith("}t")))
    except Exception as exc:  # noqa: BLE001
        src.error = f"읽기 실패: {exc}"
        return
    src.kind = "한글 (.hwpx)"
    src.lines = tag_paragraphs(src.sid, paragraphs)
    src.detail = f"{len(src.lines) // 2}단락"


def read_office_text(src: Source) -> None:
    """워드/슬라이드를 텍스트로 뽑는다."""
    with tempfile.TemporaryDirectory() as tmp:
        made = soffice_convert(src.file, "txt:Text (encoded):UTF8", Path(tmp))
        if not made:
            src.error = "LibreOffice 변환 실패"
            return
        text = made.read_text(encoding="utf-8", errors="replace")
    src.kind = f"문서 ({src.file.suffix.lower()})"
    src.lines = tag_paragraphs(src.sid, text.splitlines())
    src.detail = f"{len(src.lines) // 2}단락"


def read_pdf(src: Source) -> None:
    if not PDFTOTEXT:
        src.error = "pdftotext 없음 (apt-get install poppler-utils)"
        return
    proc = run([PDFTOTEXT, "-layout", str(src.file), "-"])
    if proc.returncode != 0 or not proc.stdout.strip():
        src.error = "PDF에서 글자를 뽑지 못함 (스캔 이미지일 수 있음)"
        return
    pages = proc.stdout.split("\f")
    out: list[str] = []
    for pno, page in enumerate(pages, 1):
        body = page.strip()
        if body:
            out += [f"[{src.sid}·{pno}쪽]", "", body, ""]
    src.kind = "PDF"
    src.lines = out
    src.detail = f"{len([p for p in pages if p.strip()])}쪽"


def read_plain(src: Source) -> None:
    for enc in ("utf-8", "cp949", "euc-kr", "utf-16"):
        try:
            text = src.file.read_text(encoding=enc)
            break
        except (UnicodeDecodeError, UnicodeError):
            continue
    else:
        src.error = "인코딩 판별 실패"
        return
    src.kind = f"텍스트 ({src.file.suffix.lower()})"
    src.lines = tag_paragraphs(src.sid, text.splitlines())
    src.detail = f"{len(src.lines) // 2}단락"


def load(src: Source) -> None:
    ext = src.file.suffix.lower()
    if ext in SHEET_EXT:
        read_spreadsheet(src)
    elif ext in FLAT_EXT:
        read_flat(src)
    elif ext == ".hwp":
        read_hwp(src)
    elif ext == ".hwpx":
        read_hwpx(src)
    elif ext in DOC_EXT or ext in SLIDE_EXT:
        read_office_text(src)
    elif ext == ".pdf":
        read_pdf(src)
    elif ext in (".txt", ".md", ".markdown"):
        read_plain(src)
    elif ext in AUDIO_EXT:
        src.kind = "오디오"
        src.error = "오디오는 NotebookLM에 원본 그대로 올린다"
    else:
        src.error = f"지원하지 않는 확장자 {ext or '(없음)'}"
    if not src.error and not src.lines:
        src.error = "내용이 비어 있음"
    if not src.title:
        src.title = src.file.stem


# ------------------------------------------------------------------ 출력
HOWTO = """\
> **이 자료를 읽는 법**
>
> 모든 표 행과 단락 앞에는 출처 표시가 붙어 있다. 형식은 다음과 같다.
>
> - `S99-1:14행` — 99번 원본 파일의 1번째 시트, 원본 파일 기준 14행
> - `S99·3` — 99번 원본 파일의 3번째 단락
> - `S99·5쪽` — 99번 원본 파일(PDF)의 5쪽
>
> `S99` 자리의 번호가 실제로 어느 파일인지는 「00_출처목록」 문서의 대응표에 있다.
> 행 번호는 원본 파일 기준이므로, 엑셀에서 그 번호로 바로 찾아갈 수 있다.
> 답변할 때는 근거가 된 행과 단락의 출처 표시를 그대로 함께 적을 것.
"""


def write_manifest(outdir: Path, sources: list[Source]) -> Path:
    lines = ["# 00_출처목록 (원본 파일 대응표)", "", HOWTO, "",
             "## 수록된 원본 파일", "",
             "| ID | 원본 경로 | 형식 | 분량 | 수록 문서 |",
             "| --- | --- | --- | --- | --- |"]
    for s in sources:
        if s.error:
            continue
        lines.append(f"| {s.sid} | `{s.path}` | {s.kind} | {s.detail} | {s.doc} |")

    failed = [s for s in sources if s.error]
    if failed:
        lines += ["", "## 수록하지 못한 파일", "",
                  "| 원본 경로 | 이유 |", "| --- | --- |"]
        lines += [f"| `{s.path}` | {s.error} |" for s in failed]

    dest = outdir / "00_출처목록.md"
    dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dest


def write_docs(outdir: Path, sources: list[Source], per_file: int) -> list[Path]:
    ok = [s for s in sources if not s.error]
    written: list[Path] = []
    groups = [ok[i:i + per_file] for i in range(0, len(ok), per_file)] or []
    for gno, group in enumerate(groups, 1):
        name = f"{gno:02d}_자료.md"
        lines = [f"# {gno:02d}_자료 ({group[0].sid}~{group[-1].sid})", "", HOWTO, ""]
        for s in group:
            s.doc = name
            lines += [f"## [{s.sid}] {s.title}", "",
                      f"- 원본 경로: `{s.path}`",
                      f"- 형식: {s.kind}",
                      f"- 분량: {s.detail}", ""]
            lines += s.lines
            lines.append("")
        dest = outdir / name
        dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
        written.append(dest)
    return written


def decode_zip_name(info: zipfile.ZipInfo) -> str:
    """zip 안 한글 파일명을 되살린다.

    UTF-8 플래그가 없는 zip은 파이썬이 이름을 cp437로 디코딩해 둔다. 원래
    바이트로 되돌린 뒤, 리눅스에서 만든 zip(UTF-8)과 윈도우에서 만든
    zip(CP949)을 차례로 시도한다.
    """
    if info.flag_bits & 0x800:
        return info.filename
    try:
        raw = info.filename.encode("cp437")
    except UnicodeEncodeError:
        return info.filename
    for enc in ("utf-8", "cp949"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return info.filename


def collect(inputs: list[str], workdir: Path) -> list[Source]:
    """폴더와 zip을 받아 (상대경로, 실제파일) 목록으로."""
    found: list[tuple[str, Path]] = []
    for item in inputs:
        path = Path(item).expanduser()
        if path.is_file() and path.suffix.lower() == ".zip":
            dest = workdir / safe_name(path.stem)
            with zipfile.ZipFile(path) as zf:
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    name = decode_zip_name(info)
                    if Path(name).name.startswith(("~$", ".")):
                        continue
                    target = dest / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with zf.open(info) as fh, target.open("wb") as out:
                        shutil.copyfileobj(fh, out)
                    found.append((name, target))
        elif path.is_dir():
            for p in sorted(path.rglob("*")):
                if p.is_file() and not p.name.startswith("~$"):
                    found.append((str(p.relative_to(path)), p))
        elif path.is_file():
            found.append((path.name, path))
        else:
            print(f"[경고] 찾을 수 없음: {item}", file=sys.stderr)

    found.sort(key=lambda t: t[0])
    return [Source(sid=f"S{i:02d}", path=rel, file=f)
            for i, (rel, f) in enumerate(found, 1)]


def main() -> int:
    ap = argparse.ArgumentParser(description="NotebookLM용 출처 추적 코퍼스 생성")
    ap.add_argument("inputs", nargs="+", help="원본 폴더 또는 zip")
    ap.add_argument("-o", "--outdir", default="corpus", help="출력 폴더")
    ap.add_argument("--per-file", type=int, default=10,
                    help="출력 문서 하나에 넣을 원본 파일 수 (기본 10)")
    args = ap.parse_args()

    outdir = Path(args.outdir).expanduser()
    outdir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        sources = collect(args.inputs, Path(tmp))
        if not sources:
            print("처리할 파일이 없습니다.", file=sys.stderr)
            return 1

        for i, s in enumerate(sources, 1):
            print(f"[{i}/{len(sources)}] {s.sid} {s.path} ... ", end="", flush=True)
            try:
                load(s)
            except Exception as exc:  # noqa: BLE001
                s.error = f"예외: {exc}"
            print(s.error if s.error else f"{s.kind}, {s.detail}")

        docs = write_docs(outdir, sources, max(1, args.per_file))
        manifest = write_manifest(outdir, sources)

    ok = [s for s in sources if not s.error]
    bad = [s for s in sources if s.error]
    print(f"\n수록 {len(ok)}개 / 제외 {len(bad)}개")
    print(f"업로드할 파일 {len(docs) + 1}개: {manifest.name}, " +
          ", ".join(d.name for d in docs))
    print(f"출력 폴더: {outdir.resolve()}")
    for s in bad:
        print(f"  - {s.path}: {s.error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
