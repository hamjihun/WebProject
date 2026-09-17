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
import re
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
    sheets: dict[int, str] = field(default_factory=dict)   # 시트 번호 -> 이름
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
            src.sheets[idx] = ws.title
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
    src.sheets[1] = src.file.stem
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
    """워드 문서를 텍스트로 뽑는다."""
    with tempfile.TemporaryDirectory() as tmp:
        made = soffice_convert(src.file, "txt:Text (encoded):UTF8", Path(tmp))
        if not made:
            src.error = "LibreOffice 변환 실패"
            return
        text = made.read_text(encoding="utf-8", errors="replace")
    src.kind = f"문서 ({src.file.suffix.lower()})"
    src.lines = tag_paragraphs(src.sid, text.splitlines())
    src.detail = f"{len(src.lines) // 2}단락"


def slide_texts(path: Path) -> list[tuple[str, str]]:
    """pptx 슬라이드별 (본문, 발표자노트). XML에서 직접 읽는다.

    LibreOffice의 텍스트 필터는 Writer 전용이라 슬라이드에서는 아무것도 나오지
    않는다. 슬라이드 순서를 지켜야 출처의 장 번호가 원본과 맞는다.
    """
    from xml.etree import ElementTree

    def collect_text(blob: bytes) -> str:
        root = ElementTree.fromstring(blob)
        parts: list[str] = []
        for para in root.iter():
            if not para.tag.endswith("}p"):
                continue
            line = "".join(t.text or "" for t in para.iter() if t.tag.endswith("}t"))
            line = " ".join(line.split())
            if line:
                parts.append(line)
        return "\n".join(parts)

    with zipfile.ZipFile(path) as zf:
        names = [n for n in zf.namelist()
                 if n.startswith("ppt/slides/slide") and n.endswith(".xml")]
        def slide_no(name: str) -> int:
            return int("".join(ch for ch in Path(name).stem if ch.isdigit()) or 0)

        names.sort(key=slide_no)
        out: list[tuple[str, str]] = []
        for name in names:
            note_name = f"ppt/notesSlides/notesSlide{slide_no(name)}.xml"
            note = ""
            if note_name in zf.namelist():
                try:
                    note = collect_text(zf.read(note_name))
                except ElementTree.ParseError:
                    note = ""
            out.append((collect_text(zf.read(name)), note))
    return out


def read_slides(src: Source) -> None:
    """슬라이드를 장별로 읽는다. 출처는 `S07·3장`처럼 장 번호로 남는다."""
    path, tmp = src.file, None
    if src.file.suffix.lower() not in (".pptx", ".potx"):
        tmp = tempfile.TemporaryDirectory()
        made = soffice_convert(src.file, "pptx", Path(tmp.name))
        if not made:
            src.error = "LibreOffice 변환 실패"
            tmp.cleanup()
            return
        path = made

    try:
        slides = slide_texts(path)
    except Exception as exc:  # noqa: BLE001
        src.error = f"읽기 실패: {exc}"
        return
    finally:
        if tmp:
            tmp.cleanup()

    lines: list[str] = []
    filled = 0
    for no, (body, note) in enumerate(slides, 1):
        if not body and not note:
            continue
        filled += 1
        lines.append(f"[{src.sid}·{no}장]")
        lines.append("")
        if body:
            lines += [body, ""]
        if note:
            lines += [f"(발표자 노트) {note}", ""]

    src.kind = f"슬라이드 ({src.file.suffix.lower()})"
    src.detail = f"{len(slides)}장 중 글자 있는 {filled}장"
    src.lines = lines
    if not lines:
        src.error = f"{len(slides)}장 모두 글자가 없음 (스크린샷만 있는 문서)"


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
    elif ext in DOC_EXT:
        read_office_text(src)
    elif ext in SLIDE_EXT:
        read_slides(src)
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


# ------------------------------------------------------------------ 민감정보
# 업무 인수인계 문서에는 사이트 로그인 정보가 적혀 있는 경우가 많다. 외부
# 서비스에 올리기 전에 값만 가리고, 어느 단계에서 로그인이 필요한지는 남긴다.
_LABELS = r"P\s*/?\s*W|PW|PASSWORD|PASS|비밀번호|패스워드|암호(?!화)|ID|아이디|계정(?!과목)"
# 값은 다음 라벨이 나오기 전까지만 가져온다. 한 줄에 "ID: x PW: y" 처럼
# 둘이 붙어 있는 경우가 많아서, 값이 뒤 라벨을 삼키면 기록이 꼬인다.
_VALUE = rf"(?P<val>(?:(?!{_LABELS})[^|\n])*)"
SECRET_LABEL = re.compile(
    rf"(?P<label>P\s*/?\s*W|PW|PASSWORD|PASS|비밀번호|패스워드|암호(?!화))\s*[:：]\s*{_VALUE}",
    re.IGNORECASE)
ACCOUNT_LABEL = re.compile(
    rf"(?P<label>ID|아이디|계정(?!과목))\s*[:：]\s*{_VALUE}", re.IGNORECASE)
# 라벨 없이 값만 덩그러니 있는 줄 (앞 줄이 "PW :" 로 끝난 경우가 많다)
BARE_SECRET = re.compile(r"^[A-Za-z0-9!@#$%^&*_.\-]{6,24}$")

MASK = "[삭제됨 — 원본 참조]"


def looks_like_secret(text: str) -> bool:
    if not BARE_SECRET.fullmatch(text.strip()):
        return False
    body = text.strip()
    has_alpha = any(ch.isalpha() for ch in body)
    has_digit = any(ch.isdigit() for ch in body)
    if not (has_alpha and has_digit):
        return False
    # 날짜, 금액, 파일명, 사업자번호, 메일주소처럼 보이는 건 제외한다
    return not re.fullmatch(
        r"[\d.\-]+|\d{6}-\d{7}|.*\.(xlsx?|pptx?|pdf|hwpx?)|[^@\s]+@[^@\s]+",
        body, re.IGNORECASE)


def redact(sid: str, lines: list[str]) -> tuple[list[str], list[tuple[str, str, str]],
                                                 list[tuple[str, str, str]]]:
    """계정 정보를 가린다.

    돌려주는 값은 (가려진 줄, 라벨이 붙어 있던 항목, 라벨 없이 값만 있던 항목).
    뒤의 것은 판단이 확실하지 않으니 목록에 따로 실어서 사람이 확인하게 한다.
    """
    labeled: list[tuple[str, str, str]] = []
    bare: list[tuple[str, str, str]] = []
    out: list[str] = []
    tag = sid

    def mask_labels(text: str) -> str:
        for pattern in (SECRET_LABEL, ACCOUNT_LABEL):
            def repl(m):
                raw = m.group("val")
                value = raw.strip()
                if not value or value == MASK:
                    return m.group(0)
                labeled.append((tag, m.group("label"), value))
                # 표 칸 안에서는 뒤 공백까지 삼키면 `| 값| |` 처럼 붙어버린다
                trail = raw[len(raw.rstrip()):]
                return f"{m.group('label')} : {MASK}{trail}"
            text = pattern.sub(repl, text)
        return text

    for line in lines:
        marker = re.match(r"^(?:\[(?P<t>[^\]]+)\]|\| (?P<c>S\d+-\d+:\d+행))", line)
        if marker:
            tag = marker.group("t") or marker.group("c")

        if line.startswith("| "):  # 표는 칸 단위로 봐야 행이 깨지지 않는다
            cells = line.strip().strip("|").split("|")
            fixed = []
            for cell in cells:
                body = cell.strip()
                if looks_like_secret(body):
                    bare.append((tag, "", body))
                    fixed.append(f" {MASK} ")
                else:
                    fixed.append(mask_labels(cell))
            out.append("|" + "|".join(fixed) + "|")
            continue

        if looks_like_secret(line):
            bare.append((tag, "", line.strip()))
            out.append(MASK)
            continue

        out.append(mask_labels(line))

    return out, labeled, bare


def secret_kind(label: str) -> str:
    """라벨을 사람이 읽을 종류 이름으로."""
    if not label:
        return "계정정보 (라벨 없음)"
    if re.fullmatch(r"ID|아이디|계정", label, re.IGNORECASE):
        return "아이디"
    return "비밀번호"


def write_secret_report(outdir: Path, items: list[tuple[str, str, str, str]]) -> Path | None:
    """실제 값이 담긴 대조용 목록. 업로드하지 않는다."""
    if not items:
        return None
    lines = ["# 가려진 계정 정보 (대조용 — 업로드 금지)", "",
             "본문에서 가린 값의 원래 내용이다. 외부 서비스에 올리면 안 된다.",
             "업로드용으로는 값이 빠진 「계정정보 위치」 문서를 쓴다.", "",
             "| 출처 | 원본 파일 | 종류 | 가린 값 |", "| --- | --- | --- | --- |"]
    lines += [f"| {tag} | `{path}` | {secret_kind(label)} | {value} |"
              for tag, path, label, value in items]
    dest = outdir / "_민감정보_목록.md"
    dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dest


def describe_spot(tag: str, sheets: dict[str, dict[int, str]]) -> str:
    """출처 표시를 사람이 찾아갈 수 있는 위치 설명으로.

    엑셀은 시트가 수십 개인 경우가 있어서 행 번호만으로는 찾을 수 없다.
    시트 번호를 이름으로 바꿔서 알려준다.
    """
    sheet_match = re.fullmatch(r"(S\d+)-(\d+):(\d+)행", tag)
    if sheet_match:
        sid, idx, row = sheet_match.groups()
        name = sheets.get(sid, {}).get(int(idx))
        where = f"「{name}」 시트 " if name else f"{idx}번째 시트 "
        return f"{where}{row}행"
    if "·" in tag:
        return tag.split("·", 1)[1]
    return tag


def secret_sort_key(item: tuple[str, str, str, str]) -> tuple:
    """S34-10:33행 처럼 생긴 출처를 번호 순서대로 정렬한다."""
    numbers = [int(n) for n in re.findall(r"\d+", item[0])]
    return tuple(numbers) + (item[2],)


def write_secret_locations(outdir: Path, items: list[tuple[str, str, str, str]],
                           number: int, sheets: dict[str, dict[int, str]]) -> Path | None:
    """값을 뺀 '어디서 확인하면 되는지'만 담은 문서. 이건 업로드한다."""
    if not items:
        return None
    lines = [f"# {number:02d}_계정정보 위치", "",
             "> **이 문서에는 실제 아이디와 비밀번호가 들어 있지 않다.**",
             ">",
             "> 계정 정보는 외부에 올리지 않기 위해 본문에서 값을 지웠고, 대신 어느 원본",
             "> 파일 어디에 적혀 있는지만 남겼다. 아래 표가 그 위치다.",
             ">",
             "> 아이디나 비밀번호를 묻는 질문에는 값을 답할 수 없다. 대신 이 표에서",
             "> 해당 업무의 원본 파일과 위치를 찾아 \"그 파일의 그 위치에서 확인하라\"고",
             "> 안내할 것.", "",
             "## 계정 정보가 적혀 있는 위치", "",
             "| 출처 | 원본 파일 | 위치 | 종류 |", "| --- | --- | --- | --- |"]
    for tag, path, label, _ in items:
        lines.append(f"| {tag} | `{path}` | {describe_spot(tag, sheets)} | "
                     f"{secret_kind(label)} |")
    lines += ["", "값을 확인하려면 위 원본 파일을 직접 열어야 한다. 엑셀이면 `Ctrl+G`로",
              "행 번호를 입력하면 해당 행으로 바로 간다."]
    dest = outdir / f"{number:02d}_계정정보 위치.md"
    dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dest


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
    """폴더와 zip을 받아 (상대경로, 실제파일) 목록으로.

    zip을 여러 개 받을 수 있다. 30MB 같은 업로드 용량 제한 때문에 자료를 나눠
    압축한 경우, 두 zip을 한 번에 넘기면 ID와 출처목록이 하나로 이어진다.
    (분할압축(.z01, .zip.001)은 조각 하나만으로 열 수 없어 지원하지 않는다.)
    """
    found: list[tuple[str, Path, str]] = []
    for item in inputs:
        path = Path(item).expanduser()
        if path.is_file() and path.suffix.lower() in (".z01", ".001") or \
                path.name.lower().endswith((".zip.001", ".part1.rar")):
            print(f"[오류] 분할압축은 읽을 수 없습니다: {path.name}\n"
                  f"       각각 단독으로 열리는 zip으로 다시 압축해 주세요.", file=sys.stderr)
            continue
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
                    found.append((name, target, path.stem))
        elif path.is_dir():
            for p in sorted(path.rglob("*")):
                if p.is_file() and not p.name.startswith("~$"):
                    found.append((str(p.relative_to(path)), p, path.name))
        elif path.is_file():
            found.append((path.name, path, ""))
        else:
            print(f"[경고] 찾을 수 없음: {item}", file=sys.stderr)

    # 나눠 압축한 zip끼리 같은 경로가 겹치면 어느 zip에서 온 것인지 밝힌다
    seen: dict[str, set[str]] = {}
    for rel, _, origin in found:
        seen.setdefault(rel, set()).add(origin)
    found = [(f"{origin}/{rel}" if len(seen[rel]) > 1 and origin else rel, f, origin)
             for rel, f, origin in found]

    found.sort(key=lambda t: t[0])
    return [Source(sid=f"S{i:02d}", path=rel, file=f)
            for i, (rel, f, _) in enumerate(found, 1)]


def main() -> int:
    ap = argparse.ArgumentParser(description="NotebookLM용 출처 추적 코퍼스 생성")
    ap.add_argument("inputs", nargs="+", help="원본 폴더 또는 zip")
    ap.add_argument("-o", "--outdir", default="corpus", help="출력 폴더")
    ap.add_argument("--per-file", type=int, default=10,
                    help="출력 문서 하나에 넣을 원본 파일 수 (기본 10)")
    ap.add_argument("--keep-secrets", action="store_true",
                    help="계정 정보를 가리지 않고 그대로 둔다 (기본은 가린다)")
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

        secrets: list[tuple[str, str, str, str]] = []
        if not args.keep_secrets:
            for s_ in sources:
                if s_.error:
                    continue
                s_.lines, hits, bare = redact(s_.sid, s_.lines)
                secrets += [(tag, s_.path, label, value)
                            for tag, label, value in hits + bare]

        docs = write_docs(outdir, sources, max(1, args.per_file))
        manifest = write_manifest(outdir, sources)
        report = write_secret_report(outdir, secrets)
        sheet_names = {s_.sid: s_.sheets for s_ in sources}
        secrets.sort(key=secret_sort_key)
        locations = write_secret_locations(outdir, secrets, len(docs) + 1, sheet_names)

    ok = [s for s in sources if not s.error]
    bad = [s for s in sources if s.error]
    print(f"\n수록 {len(ok)}개 / 제외 {len(bad)}개")
    uploads = [manifest.name] + [d.name for d in docs]
    if locations:
        uploads.append(locations.name)
    print(f"업로드할 파일 {len(uploads)}개: " + ", ".join(uploads))
    if secrets:
        bare_count = sum(1 for _, _, label, _ in secrets if not label)
        print(f"계정 정보 {len(secrets)}건을 가렸습니다"
              + (f" (그중 라벨 없이 값만 있던 것 {bare_count}건)" if bare_count else ""))
        print(f"업로드 금지: {report.name} (가린 값의 원본이 들어 있음)")
    print(f"출력 폴더: {outdir.resolve()}")
    for s in bad:
        print(f"  - {s.path}: {s.error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
