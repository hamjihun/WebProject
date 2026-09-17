#!/usr/bin/env python3
"""NotebookLM 업로드용 파일 일괄 변환기.

NotebookLM은 PDF / TXT / 마크다운(.md) / 오디오만 업로드할 수 있다.
이 스크립트는 엑셀·한글·워드·파워포인트 등을 그 형식으로 바꿔준다.

  엑셀(.xlsx/.xlsm/.xls), CSV/TSV  ->  .md   (시트별 마크다운 표)
  한글(.hwp), 한글(.hwpx)          ->  .txt
  워드(.doc/.docx/.rtf/.odt)       ->  .pdf
  슬라이드(.ppt/.pptx/.odp)        ->  .pdf
  이미 지원되는 pdf/txt/md         ->  그대로 복사

사용법:
  python3 convert.py <입력파일-또는-폴더> [...] [-o 출력폴더]
  python3 convert.py ./원본 -o ./notebooklm_out
  python3 convert.py ./원본 --docs-to txt      # 워드/슬라이드를 PDF 대신 TXT로
"""

from __future__ import annotations

import argparse
import csv
import datetime
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree

SHEET_EXT = {".xlsx", ".xlsm", ".xltx", ".xls"}
FLAT_EXT = {".csv", ".tsv"}
DOC_EXT = {".doc", ".docx", ".rtf", ".odt", ".dotx"}
SLIDE_EXT = {".ppt", ".pptx", ".odp", ".potx"}
PASSTHRU_EXT = {".pdf", ".txt", ".md", ".markdown"}
AUDIO_EXT = {".mp3", ".m4a", ".wav", ".aac", ".ogg", ".flac"}

SOFFICE = shutil.which("soffice") or shutil.which("libreoffice")


class Result:
    def __init__(self, src: Path, status: str, out: Path | None = None, note: str = ""):
        self.src, self.status, self.out, self.note = src, status, out, note


# ---------------------------------------------------------------- helpers
def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def soffice_convert(src: Path, target: str, outdir: Path, infilter: str | None = None) -> Path | None:
    """LibreOffice로 변환. 성공하면 결과 경로를 돌려준다."""
    if not SOFFICE:
        return None
    outdir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as profile:
        cmd = [
            SOFFICE, "--headless", "--norestore", "--invisible",
            f"-env:UserInstallation=file://{profile}",
            "--convert-to", target, "--outdir", str(outdir), str(src),
        ]
        if infilter:
            cmd[cmd.index("--convert-to") + 1] = target
            cmd.insert(cmd.index(str(src)), f"--infilter={infilter}")
        run(cmd, timeout=600)
    ext = "." + target.split(":")[0]
    cand = outdir / (src.stem + ext)
    return cand if cand.exists() and cand.stat().st_size > 0 else None


def unique(path: Path) -> Path:
    if not path.exists():
        return path
    for n in range(2, 1000):
        cand = path.with_name(f"{path.stem}({n}){path.suffix}")
        if not cand.exists():
            return cand
    return path


def md_cell(value) -> str:
    if value is None:
        return ""
    if isinstance(value, datetime.datetime):
        value = value.date() if value.time() == datetime.time(0, 0) else value
    elif isinstance(value, float) and value.is_integer():
        value = int(value)
    text = str(value).replace("|", "\\|")
    return " ".join(text.split())


def rows_to_md(rows: list[list], title: str) -> list[str]:
    """2차원 값 목록을 마크다운 표 문자열 목록으로."""
    # 뒤쪽 빈 행/열 제거
    while rows and all(md_cell(c) == "" for c in rows[-1]):
        rows.pop()
    if not rows:
        return [f"## {title}\n", "_(빈 시트)_\n"]
    width = max(len(r) for r in rows)
    keep = [i for i in range(width)
            if any(md_cell(r[i]) if i < len(r) else "" for r in rows)]
    if not keep:
        return [f"## {title}\n", "_(빈 시트)_\n"]

    def cells(row):
        return [md_cell(row[i]) if i < len(row) else "" for i in keep]

    head = cells(rows[0])
    if not any(head):  # 첫 행이 비면 열 번호를 헤더로
        head = [f"col{i + 1}" for i in range(len(keep))]
        body = rows
    else:
        body = rows[1:]
    out = [f"## {title}", "", "| " + " | ".join(head) + " |",
           "| " + " | ".join("---" for _ in head) + " |"]
    for row in body:
        vals = cells(row)
        if not any(vals):
            continue
        out.append("| " + " | ".join(vals) + " |")
    out.append("")
    return out


# ---------------------------------------------------------------- converters
def convert_spreadsheet(src: Path, outdir: Path) -> Result:
    """엑셀 -> 마크다운(시트별 표)."""
    try:
        import openpyxl
    except ImportError:
        return Result(src, "fail", note="openpyxl 미설치 (pip install openpyxl)")

    work = src
    tmp: tempfile.TemporaryDirectory | None = None
    if src.suffix.lower() == ".xls":  # 구형 포맷은 xlsx로 한 번 거쳐 간다
        tmp = tempfile.TemporaryDirectory()
        converted = soffice_convert(src, "xlsx", Path(tmp.name))
        if not converted:
            if tmp:
                tmp.cleanup()
            return Result(src, "fail", note=".xls -> .xlsx 변환 실패")
        work = converted

    try:
        # 계산된 값을 우선 쓰고, 캐시된 값이 없는 셀은 수식 문자열로 채운다.
        wb = openpyxl.load_workbook(work, data_only=True, read_only=True)
        raw = openpyxl.load_workbook(work, data_only=False, read_only=True)
        lines = [f"# {src.stem}", "", f"> 원본 파일: `{src.name}`", ""]
        total = 0
        for ws in wb.worksheets:
            rows = [list(r) for r in ws.iter_rows(values_only=True)]
            if ws.title in raw.sheetnames:
                fallback = [list(r) for r in raw[ws.title].iter_rows(values_only=True)]
                for y, row in enumerate(rows):
                    if y >= len(fallback):
                        break
                    for x, cell in enumerate(row):
                        if cell is None and x < len(fallback[y]):
                            row[x] = fallback[y][x]
            total += len(rows)
            lines += rows_to_md(rows, ws.title)
        wb.close()
        raw.close()
    except Exception as exc:  # noqa: BLE001 - 원본이 깨진 경우까지 보고서에 남긴다
        return Result(src, "fail", note=f"읽기 실패: {exc}")
    finally:
        if tmp:
            tmp.cleanup()

    dest = unique(outdir / (src.stem + ".md"))
    dest.write_text("\n".join(lines), encoding="utf-8")
    return Result(src, "ok", dest, f"{total}행")


def convert_flat(src: Path, outdir: Path) -> Result:
    """CSV/TSV -> 마크다운 표."""
    delim = "\t" if src.suffix.lower() == ".tsv" else ","
    for enc in ("utf-8-sig", "cp949", "euc-kr", "utf-16", "latin-1"):
        try:
            with src.open(newline="", encoding=enc) as fh:
                rows = [list(r) for r in csv.reader(fh, delimiter=delim)]
            break
        except (UnicodeDecodeError, UnicodeError):
            continue
    else:
        return Result(src, "fail", note="인코딩 판별 실패")

    lines = [f"# {src.stem}", "", f"> 원본 파일: `{src.name}`", ""] + rows_to_md(rows, src.stem)
    dest = unique(outdir / (src.stem + ".md"))
    dest.write_text("\n".join(lines), encoding="utf-8")
    return Result(src, "ok", dest, f"{len(rows)}행 ({enc})")


def convert_hwp(src: Path, outdir: Path) -> Result:
    """한글(.hwp) -> txt. pyhwp를 먼저 쓰고, 실패하면 LibreOffice로 넘어간다."""
    dest = unique(outdir / (src.stem + ".txt"))
    hwp5txt = shutil.which("hwp5txt")
    if hwp5txt:
        proc = run([hwp5txt, "--output", str(dest), str(src)], timeout=300)
        if proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0:
            return Result(src, "ok", dest, "pyhwp")
        dest.unlink(missing_ok=True)

    # 2차: pyhwp로 odt를 만든 뒤 LibreOffice로 txt
    hwp5odt = shutil.which("hwp5odt")
    if hwp5odt and SOFFICE:
        with tempfile.TemporaryDirectory() as tmp:
            odt = Path(tmp) / (src.stem + ".odt")
            if run([hwp5odt, "--output", str(odt), str(src)], timeout=300).returncode == 0 and odt.exists():
                made = soffice_convert(odt, "txt:Text (encoded):UTF8", Path(tmp))
                if made:
                    shutil.move(str(made), dest)
                    return Result(src, "ok", dest, "pyhwp+LibreOffice")

    # 3차: LibreOffice의 HWP 97 필터 (구형 .hwp만 열린다)
    with tempfile.TemporaryDirectory() as tmp:
        made = soffice_convert(src, "txt:Text (encoded):UTF8", Path(tmp),
                               infilter="writer_MIZI_Hwp_97")
        if made and made.stat().st_size > 0:
            shutil.move(str(made), dest)
            return Result(src, "ok", dest, "LibreOffice(HWP97)")

    return Result(src, "fail", note="한글 파일을 열 수 없음 (암호 설정 또는 손상 여부 확인)")


def convert_hwpx(src: Path, outdir: Path) -> Result:
    """한글(.hwpx)은 zip+XML이라 직접 읽는다."""
    try:
        with zipfile.ZipFile(src) as zf:
            names = sorted(n for n in zf.namelist()
                           if n.startswith("Contents/section") and n.endswith(".xml"))
            if not names:
                return Result(src, "fail", note="section XML 없음")
            paragraphs: list[str] = []
            for name in names:
                root = ElementTree.fromstring(zf.read(name))
                for para in root.iter():
                    if not para.tag.endswith("}p"):
                        continue
                    text = "".join(t.text or "" for t in para.iter()
                                   if t.tag.endswith("}t"))
                    paragraphs.append(text)
    except Exception as exc:  # noqa: BLE001
        return Result(src, "fail", note=f"읽기 실패: {exc}")

    dest = unique(outdir / (src.stem + ".txt"))
    dest.write_text("\n".join(paragraphs).strip() + "\n", encoding="utf-8")
    return Result(src, "ok", dest, f"{len(paragraphs)}단락")


def convert_via_soffice(src: Path, outdir: Path, target: str, label: str) -> Result:
    with tempfile.TemporaryDirectory() as tmp:
        made = soffice_convert(src, target, Path(tmp))
        if not made:
            return Result(src, "fail", note="LibreOffice 변환 실패")
        dest = unique(outdir / made.name)
        shutil.move(str(made), dest)
    return Result(src, "ok", dest, label)


def passthru(src: Path, outdir: Path) -> Result:
    dest = unique(outdir / src.name)
    shutil.copy2(src, dest)
    return Result(src, "copy", dest, "이미 지원되는 형식")


# ---------------------------------------------------------------- driver
def handle(src: Path, outdir: Path, docs_to: str) -> Result:
    ext = src.suffix.lower()
    if ext in PASSTHRU_EXT or ext in AUDIO_EXT:
        return passthru(src, outdir)
    if ext in SHEET_EXT:
        return convert_spreadsheet(src, outdir)
    if ext in FLAT_EXT:
        return convert_flat(src, outdir)
    if ext == ".hwp":
        return convert_hwp(src, outdir)
    if ext == ".hwpx":
        return convert_hwpx(src, outdir)
    if ext in DOC_EXT:
        target = "pdf" if docs_to == "pdf" else "txt:Text (encoded):UTF8"
        return convert_via_soffice(src, outdir, target, f"LibreOffice -> {docs_to}")
    if ext in SLIDE_EXT:
        return convert_via_soffice(src, outdir, "pdf", "LibreOffice -> pdf")
    return Result(src, "skip", note=f"지원하지 않는 확장자 {ext or '(없음)'}")


def collect(inputs: list[str]) -> list[Path]:
    files: list[Path] = []
    for item in inputs:
        path = Path(item).expanduser()
        if path.is_dir():
            files += [p for p in sorted(path.rglob("*"))
                      if p.is_file() and not p.name.startswith("~$")]
        elif path.is_file():
            files.append(path)
        else:
            print(f"[경고] 찾을 수 없음: {item}", file=sys.stderr)
    return files


def main() -> int:
    ap = argparse.ArgumentParser(description="NotebookLM 업로드용 파일 일괄 변환")
    ap.add_argument("inputs", nargs="+", help="변환할 파일 또는 폴더")
    ap.add_argument("-o", "--outdir", default="notebooklm_out", help="출력 폴더")
    ap.add_argument("--docs-to", choices=["pdf", "txt"], default="pdf",
                    help="워드 문서를 무엇으로 바꿀지 (기본 pdf)")
    ap.add_argument("--merge", action="store_true",
                    help="변환된 md/txt를 _통합.md 한 파일로도 묶는다 "
                         "(NotebookLM 소스 개수 제한 대응)")
    args = ap.parse_args()

    files = collect(args.inputs)
    if not files:
        print("변환할 파일이 없습니다.", file=sys.stderr)
        return 1

    outdir = Path(args.outdir).expanduser()
    outdir.mkdir(parents=True, exist_ok=True)

    results: list[Result] = []
    for i, src in enumerate(files, 1):
        print(f"[{i}/{len(files)}] {src.name} ... ", end="", flush=True)
        try:
            res = handle(src, outdir, args.docs_to)
        except Exception as exc:  # noqa: BLE001 - 한 파일 때문에 전체가 멈추지 않게
            res = Result(src, "fail", note=f"예외: {exc}")
        results.append(res)
        mark = {"ok": "변환", "copy": "복사", "skip": "건너뜀", "fail": "실패"}[res.status]
        print(f"{mark}" + (f" -> {res.out.name}" if res.out else "") +
              (f" ({res.note})" if res.note else ""))

    if args.merge:
        chunks = []
        for r in results:
            if r.out and r.out.suffix.lower() in (".md", ".txt"):
                body = r.out.read_text(encoding="utf-8", errors="replace").strip()
                if body.startswith("# "):  # 아래에서 제목을 다시 붙이므로 중복 제거
                    body = body.split("\n", 1)[1].strip() if "\n" in body else ""
                chunks.append(f"<!-- 원본: {r.src.name} -->\n\n# {r.src.stem}\n\n{body}")
        if chunks:
            merged = outdir / "_통합.md"
            merged.write_text("\n\n---\n\n".join(chunks) + "\n", encoding="utf-8")
            print(f"\n통합 파일: {merged.name} ({len(chunks)}개 문서)")

    ok = [r for r in results if r.status in ("ok", "copy")]
    bad = [r for r in results if r.status == "fail"]
    skipped = [r for r in results if r.status == "skip"]

    report = ["# 변환 결과", "", f"- 전체 {len(results)}개",
              f"- 성공 {len(ok)}개", f"- 실패 {len(bad)}개", f"- 건너뜀 {len(skipped)}개", "",
              "| 원본 | 결과 | 상태 | 비고 |", "| --- | --- | --- | --- |"]
    for r in results:
        report.append(f"| {r.src.name} | {r.out.name if r.out else '-'} | {r.status} | {r.note} |")
    (outdir / "_변환결과.md").write_text("\n".join(report) + "\n", encoding="utf-8")

    print(f"\n성공 {len(ok)} / 실패 {len(bad)} / 건너뜀 {len(skipped)}")
    print(f"출력 폴더: {outdir.resolve()}")
    for r in bad + skipped:
        print(f"  - {r.src.name}: {r.note}")
    return 0 if not bad else 2


if __name__ == "__main__":
    sys.exit(main())
