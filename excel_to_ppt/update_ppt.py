# -*- coding: utf-8 -*-
"""
엑셀 손익 자료 → 월간 경영실적 PPT 자동 반영 프로그램

사용법 (명령줄):
    python update_ppt.py --excel "손익.xlsx" --ppt "지난달_PPT.pptx" --month 8 --out "8월_경영실적.pptx"

--month 를 생략하면 엑셀의 "N월 누적" 머리글에서 월을 자동으로 찾습니다.
--out   을 생략하면 PPT 파일과 같은 폴더에 "<원본이름>_N월.pptx" 로 저장합니다.

동작 내용
  1. 차트  : PPT 안의 모든 차트가 참조하는 엑셀 셀 주소(예: Insulation!$E$18:$P$18)를 읽어
             해당 셀 값을 차트 데이터로 그대로 밀어 넣습니다. (별도 설정 불필요)
  2. 표    : mapping.json 에 정의된 대로 엑셀 행 → PPT 표 행을 채웁니다.
  3. 월 표기: "7월 경영실적", "7월 누적" 같은 문구의 월 숫자를 새 월로 바꿉니다.
  4. 예상치 : 당월 다음 달 값이 엑셀에 있으면 표에는 (괄호)로, 차트에는 점선으로 표시합니다.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
from decimal import Decimal, ROUND_HALF_UP

import openpyxl
from openpyxl.utils import column_index_from_string, get_column_letter
from pptx import Presentation
from pptx.oxml.ns import qn

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MAPPING = os.path.join(HERE, "mapping.json")

# 월 숫자를 바꿀 문구 패턴 (숫자 부분만 캡처)
MONTH_TEXT_PATTERNS = [
    re.compile(r"(\d{1,2})(?=월\s*경영실적)"),
    re.compile(r"(\d{1,2})(?=월\s*누적)"),
]
MONTH_HEADER_RE = re.compile(r"^\s*(\d{1,2})월\s*누적\s*$")


class Log:
    """실행 중 발생한 안내/경고를 모아 두었다가 화면에 출력."""

    def __init__(self, printer=print):
        self.printer = printer
        self.warnings: list[str] = []
        self.infos: list[str] = []

    def info(self, msg):
        self.infos.append(msg)
        self.printer(msg)

    def warn(self, msg):
        self.warnings.append(msg)
        self.printer("[경고] " + msg)


# ---------------------------------------------------------------------------
# 엑셀 읽기
# ---------------------------------------------------------------------------
class ExcelReader:
    def __init__(self, path: str, sheet_alias: dict | None = None, log: Log | None = None):
        self.path = path
        self.log = log or Log()
        self.alias = sheet_alias or {}
        # 값 전용(수식 계산 결과) + 수식 확인용 두 번 로드
        self.wb_val = openpyxl.load_workbook(path, data_only=True, read_only=False)
        self.wb_fml = openpyxl.load_workbook(path, data_only=False, read_only=False)
        self._missing_sheets: set[str] = set()
        self._uncached_reported = False

    def sheet_name(self, name: str) -> str | None:
        name = self.alias.get(name, name)
        if name in self.wb_val.sheetnames:
            return name
        # 앞뒤 공백 차이 허용
        for s in self.wb_val.sheetnames:
            if s.strip() == name.strip():
                return s
        return None

    def has_sheet(self, name: str) -> bool:
        ok = self.sheet_name(name) is not None
        if not ok and name not in self._missing_sheets:
            self._missing_sheets.add(name)
            self.log.warn(f"엑셀에 '{name}' 시트가 없어 관련 항목은 건너뜁니다. "
                          f"(엑셀 시트: {', '.join(self.wb_val.sheetnames)})")
        return ok

    def cell(self, sheet: str, col, row: int):
        """값을 돌려준다. 수식인데 계산 결과가 저장돼 있지 않으면 경고."""
        real = self.sheet_name(sheet)
        if real is None:
            return None
        if isinstance(col, str):
            col = column_index_from_string(col)
        v = self.wb_val[real].cell(row=row, column=col).value
        if v is None:
            f = self.wb_fml[real].cell(row=row, column=col).value
            if isinstance(f, str) and f.startswith("=") and not self._uncached_reported:
                self._uncached_reported = True
                self.log.warn(f"{real}!{get_column_letter(col)}{row} 수식의 계산 값이 파일에 저장되어 있지 않습니다. "
                              "엑셀에서 파일을 한 번 열어 저장한 뒤 다시 실행하세요.")
        if isinstance(v, str) and v.strip() == "":
            return None
        return v

    def number_format(self, sheet: str, col, row: int) -> str:
        real = self.sheet_name(sheet)
        if real is None:
            return "General"
        if isinstance(col, str):
            col = column_index_from_string(col)
        return self.wb_val[real].cell(row=row, column=col).number_format or "General"

    def row_labels(self, sheet: str, row: int, before_col: int) -> list[str]:
        real = self.sheet_name(sheet)
        if real is None:
            return []
        ws = self.wb_val[real]
        out = []
        for c in range(1, before_col):
            v = ws.cell(row=row, column=c).value
            if v is not None and str(v).strip():
                out.append(str(v).strip())
        return out

    def find_month_header(self, sheet: str) -> int | None:
        """시트 안에서 'N월 누적' 이라는 머리글을 찾아 N을 돌려준다."""
        real = self.sheet_name(sheet)
        if real is None:
            return None
        found = []
        for row in self.wb_val[real].iter_rows():
            for c in row:
                if isinstance(c.value, str):
                    m = MONTH_HEADER_RE.match(c.value)
                    if m:
                        found.append(int(m.group(1)))
        if not found:
            return None
        # 여러 개면 가장 많이 나온 값
        return max(set(found), key=found.count)


# ---------------------------------------------------------------------------
# 셀 주소 파싱 / 숫자 서식
# ---------------------------------------------------------------------------
REF_RE = re.compile(r"^(?:'((?:[^']|'')+)'|([^'!]+))!\$?([A-Z]{1,3})\$?(\d+)(?::\$?([A-Z]{1,3})\$?(\d+))?$")


def parse_ref(ref: str):
    """'시트'!$E$16:$P$16 → (시트, [(col,row), ...])"""
    m = REF_RE.match(ref.strip())
    if not m:
        return None, []
    sheet = (m.group(1) or m.group(2)).replace("''", "'")
    c1, r1 = column_index_from_string(m.group(3)), int(m.group(4))
    if m.group(5):
        c2, r2 = column_index_from_string(m.group(5)), int(m.group(6))
    else:
        c2, r2 = c1, r1
    cells = []
    for r in range(min(r1, r2), max(r1, r2) + 1):
        for c in range(min(c1, c2), max(c1, c2) + 1):
            cells.append((c, r))
    return sheet, cells


def is_pct_format(number_format: str) -> bool:
    return "%" in (number_format or "")


def _q(value, places: str) -> Decimal:
    return Decimal(str(value)).quantize(Decimal(places), rounding=ROUND_HALF_UP)


def format_value(value, fmt: str, paren: bool = False) -> str:
    """엑셀 값 → PPT 표 문자열. fmt = 'pct' | 'amount' (백만 단위)"""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return ""
    try:
        if fmt in ("pct", "pct_plain"):
            # pct: 엑셀 값이 0.974 같은 비율 / pct_plain: 엑셀 값이 이미 97.4 같은 퍼센트 숫자
            d = _q(Decimal(str(value)) * (100 if fmt == "pct" else 1), "0.1")
            if d == 0:
                d = Decimal("0.0")
            s = f"{d:.1f}%"
        else:
            d = _q(Decimal(str(value)) / Decimal(1_000_000), "1")
            if d == 0:
                d = Decimal(0)
            s = f"{int(d):,}"
    except Exception:
        return str(value)
    return f"({s})" if paren else s


def format_eok(value, arrow: bool = False) -> str:
    """억 단위 표기. arrow=True 면 증감(↑/↓) 표기."""
    if value is None:
        return ""
    d = _q(Decimal(str(value)) / Decimal(100_000_000), "0.01")
    if arrow:
        if d == 0:
            return "0.00억"
        return f"{abs(d):.2f}억{'↑' if d > 0 else '↓'}"
    return f"{d:.2f}억"


def format_summary(value, fmt: str) -> str:
    """슬라이드 9 요약표용 서식.
    eok / eok_diff      : 223.89억 / 25.39억↓
    pct_paren           : (9.8%)
    pp_diff_paren       : (2.0%p↓)   (비율 차이, %p)
    그 외               : format_value 와 동일 (pct, amount ...)
    """
    if value is None:
        return ""
    if fmt == "eok":
        return format_eok(value)
    if fmt == "eok_diff":
        return format_eok(value, arrow=True)
    if fmt == "pct_paren":
        return "(" + format_value(value, "pct") + ")"
    if fmt == "pp_diff_paren":
        d = _q(Decimal(str(value)) * 100, "0.1")
        if d == 0:
            return "(0.0%p)"
        return f"({abs(d):.1f}%p{'↑' if d > 0 else '↓'})"
    return format_value(value, fmt)


# ---------------------------------------------------------------------------
# PPT 텍스트 유틸
# ---------------------------------------------------------------------------
A_R, A_T, A_BR, A_FLD, A_P = qn("a:r"), qn("a:t"), qn("a:br"), qn("a:fld"), qn("a:p")
A_RPR, A_ENDPARARPR = qn("a:rPr"), qn("a:endParaRPr")


def set_cell_text(tc, text: str):
    """표 셀의 글자만 바꾼다(글꼴/크기/정렬은 기존 것을 유지)."""
    txBody = tc.find(qn("a:txBody"))
    paras = txBody.findall(A_P)
    p = paras[0]
    for extra in paras[1:]:
        txBody.remove(extra)
    runs = p.findall(A_R)
    for br in p.findall(A_BR):
        p.remove(br)
    end = p.find(A_ENDPARARPR)
    if text == "":
        if runs and end is None:
            rpr = runs[0].find(A_RPR)
            if rpr is not None:
                end = copy.deepcopy(rpr)
                end.tag = A_ENDPARARPR
                p.append(end)
        for r in runs:
            p.remove(r)
        return
    if runs:
        runs[0].find(A_T).text = text
        for r in runs[1:]:
            p.remove(r)
        return
    # 빈 셀이었으면 endParaRPr 서식을 복사해 새 run 생성
    r = p.makeelement(A_R, {})
    if end is not None:
        rpr = copy.deepcopy(end)
        rpr.tag = A_RPR
        r.append(rpr)
        p.insert(list(p).index(end), r)
    else:
        p.append(r)
    t = r.makeelement(A_T, {})
    t.text = text
    r.append(t)


def set_cell_color(tc, negative: bool):
    """음수는 빨간색(FF0000), 그 외는 기본색(tx1). 기존 템플릿 규칙과 동일."""
    p = tc.find(qn("a:txBody")).find(A_P)
    for r in p.findall(A_R):
        rpr = r.find(A_RPR)
        if rpr is None:
            rpr = r.makeelement(A_RPR, {})
            r.insert(0, rpr)
        fill = rpr.find(qn("a:solidFill"))
        if fill is None:
            fill = rpr.makeelement(qn("a:solidFill"), {})
            # solidFill 은 ln 다음, effectLst/latin 앞에 와야 함
            anchor = None
            for tag in ("a:effectLst", "a:highlight", "a:latin", "a:ea", "a:cs", "a:sym"):
                anchor = rpr.find(qn(tag))
                if anchor is not None:
                    break
            if anchor is not None:
                anchor.addprevious(fill)
            else:
                rpr.append(fill)
        for ch in list(fill):
            fill.remove(ch)
        if negative:
            fill.append(fill.makeelement(qn("a:srgbClr"), {"val": "FF0000"}))
        else:
            fill.append(fill.makeelement(qn("a:schemeClr"), {"val": "tx1"}))


def get_cell_text(tc) -> str:
    return "".join(t.text or "" for t in tc.iter(A_T))


def replace_month_in_paragraphs(paragraphs, new_month: int) -> int:
    """여러 문단(표 셀·텍스트 상자)을 하나의 글로 보고 'N월 경영실적' / 'N월 누적' 의 N 을
    new_month 로 바꾼다. 문단이 나뉘어 있어도('7월' + 줄바꿈 + '누적') 찾아내며 run 서식은 유지."""
    pieces = []  # (a:t element or None, text)
    for pi, p in enumerate(paragraphs):
        if pi > 0:
            pieces.append((None, "\n"))
        for child in p:
            if child.tag == A_R or child.tag == A_FLD:
                t = child.find(A_T)
                if t is not None:
                    pieces.append((t, t.text or ""))
            elif child.tag == A_BR:
                pieces.append((None, "\n"))
    full = "".join(t for _, t in pieces)
    if not full:
        return 0
    edits = []  # (start, end, replacement)
    for pat in MONTH_TEXT_PATTERNS:
        for m in pat.finditer(full):
            if int(m.group(1)) != new_month:
                edits.append((m.start(1), m.end(1), str(new_month)))
    if not edits:
        return 0
    # 뒤에서부터 적용해야 앞쪽 위치가 흔들리지 않음
    for start, end, rep in sorted(edits, reverse=True):
        pos = 0
        first = True
        for t_el, text in pieces:
            seg_start, seg_end = pos, pos + len(text)
            pos = seg_end
            if t_el is None or seg_end <= start or seg_start >= end:
                continue
            lo, hi = max(start, seg_start) - seg_start, min(end, seg_end) - seg_start
            cur = t_el.text or ""
            t_el.text = cur[:lo] + (rep if first else "") + cur[hi:]
            first = False
        pieces = [(t, (t.text or "") if t is not None else txt) for t, txt in pieces]
    return len(edits)


# ---------------------------------------------------------------------------
# 차트 갱신
# ---------------------------------------------------------------------------
C = lambda tag: qn("c:" + tag)  # noqa: E731


def _fill_str_cache(cache_parent, values):
    """strRef/numRef 아래 캐시를 values 로 교체."""
    for old in cache_parent.findall(C("strCache")) + cache_parent.findall(C("numCache")):
        cache_parent.remove(old)


def _set_str_ref(ref_el, values: list):
    cache = ref_el.find(C("strCache"))
    if cache is None:
        cache = ref_el.makeelement(C("strCache"), {})
        ref_el.append(cache)
    for ch in list(cache):
        cache.remove(ch)
    pc = cache.makeelement(C("ptCount"), {"val": str(len(values))})
    cache.append(pc)
    for i, v in enumerate(values):
        if v is None:
            continue
        pt = cache.makeelement(C("pt"), {"idx": str(i)})
        ve = pt.makeelement(C("v"), {})
        ve.text = str(v)
        pt.append(ve)
        cache.append(pt)


def _set_num_ref(ref_el, values: list, default_format="General"):
    cache = ref_el.find(C("numCache"))
    if cache is None:
        cache = ref_el.makeelement(C("numCache"), {})
        ref_el.append(cache)
    fc = cache.find(C("formatCode"))
    fmt = fc.text if fc is not None else default_format
    for ch in list(cache):
        cache.remove(ch)
    fc = cache.makeelement(C("formatCode"), {})
    fc.text = fmt
    cache.append(fc)
    cache.append(cache.makeelement(C("ptCount"), {"val": str(len(values))}))
    for i, v in enumerate(values):
        if not isinstance(v, (int, float)) or isinstance(v, bool):
            continue
        pt = cache.makeelement(C("pt"), {"idx": str(i)})
        ve = pt.makeelement(C("v"), {})
        ve.text = repr(float(v)) if isinstance(v, float) else str(v)
        pt.append(ve)
        cache.append(pt)


def _read_ref_values(xl: ExcelReader, ref_el):
    f = ref_el.find(C("f"))
    if f is None or not f.text:
        return None, None
    sheet, cells = parse_ref(f.text)
    if sheet is None:
        return None, None
    if not xl.has_sheet(sheet):
        return sheet, None
    return sheet, [xl.cell(sheet, c, r) for c, r in cells]


def _series_name(ser) -> str:
    tx = ser.find(C("tx"))
    if tx is None:
        return ""
    return "".join(v.text or "" for v in tx.iter(C("v"))).strip()


def _cat_labels(ser) -> list[str]:
    cat = ser.find(C("cat"))
    if cat is None:
        return []
    labels = {}
    for pt in cat.iter(C("pt")):
        v = pt.find(C("v"))
        labels[int(pt.get("idx"))] = (v.text or "").strip() if v is not None else ""
    n = 0
    pc = cat.find(".//" + C("ptCount"))
    if pc is not None:
        n = int(pc.get("val"))
    return [labels.get(i, "") for i in range(max(n, (max(labels) + 1) if labels else 0))]


def _has_value_at(ser, idx: int) -> bool:
    val = ser.find(C("val"))
    if val is None:
        return False
    for pt in val.iter(C("pt")):
        if int(pt.get("idx")) == idx:
            return True
    return False


def _move_forecast_dash(ser, month: int, log: Log, chart_label: str):
    """'실적' 계열의 점선 구간(예상치)을 당월 다음 달 위치로 옮긴다."""
    dotted = []
    for dPt in ser.findall(C("dPt")):
        sp = dPt.find(C("spPr"))
        if sp is None:
            continue
        dash = sp.find(".//" + qn("a:prstDash"))
        if dash is not None and dash.get("val") in ("sysDot", "dot", "dash", "sysDash", "lgDash", "dashDot"):
            dotted.append(dPt)
    if not dotted:
        return
    # 첫 점(idx 0)의 스타일은 예상치 표시가 아니므로 그대로 둔다
    dotted = [d for d in dotted if int(d.find(C("idx")).get("val")) != 0]
    if not dotted:
        return
    sp_template = copy.deepcopy(dotted[0].find(C("spPr")))
    for d in dotted:
        d.remove(d.find(C("spPr")))
        # idx / bubble3D / extLst 만 남은 빈 dPt 는 지운다
        rest = [ch for ch in d if ch.tag not in (C("idx"), C("bubble3D"), C("extLst"))]
        if not rest:
            ser.remove(d)

    labels = _cat_labels(ser)
    target = f"{month + 1}월"
    if target not in labels:
        return
    idx = labels.index(target)
    if not _has_value_at(ser, idx):
        return  # 다음 달 예상치가 없으면 점선 없음

    existing = None
    for d in ser.findall(C("dPt")):
        if int(d.find(C("idx")).get("val")) == idx:
            existing = d
            break
    if existing is None:
        existing = ser.makeelement(C("dPt"), {})
        existing.append(existing.makeelement(C("idx"), {"val": str(idx)}))
        existing.append(existing.makeelement(C("bubble3D"), {"val": "0"}))
        # 위치: 기존 dPt 들 중 idx 순서에 맞게, 없으면 dLbls/cat/val 앞
        placed = False
        for d in ser.findall(C("dPt")):
            if int(d.find(C("idx")).get("val")) > idx:
                d.addprevious(existing)
                placed = True
                break
        if not placed:
            dpts = ser.findall(C("dPt"))
            if dpts:
                dpts[-1].addnext(existing)
            else:
                anchor = None
                for tag in ("dLbls", "trendline", "errBars", "cat", "val", "smooth", "extLst"):
                    anchor = ser.find(C(tag))
                    if anchor is not None:
                        break
                if anchor is not None:
                    anchor.addprevious(existing)
                else:
                    ser.append(existing)
    ext = existing.find(C("extLst"))
    if ext is not None:
        ext.addprevious(sp_template)
    else:
        existing.append(sp_template)
    log.info(f"  {chart_label}: '{_series_name(ser)}' {target} 구간을 점선(예상)으로 표시")


def update_chart(chart, xl: ExcelReader, month: int, log: Log, chart_label: str) -> bool:
    cs = chart._chartSpace
    touched = False
    for ser in cs.iter(C("ser")):
        # 계열 이름
        tx = ser.find(C("tx"))
        if tx is not None:
            sref = tx.find(C("strRef"))
            if sref is not None:
                sheet, vals = _read_ref_values(xl, sref)
                if vals is not None:
                    _set_str_ref(sref, [None if v is None else str(v) for v in vals])
                    touched = True
        # 범주(월)
        cat = ser.find(C("cat"))
        if cat is not None:
            sref = cat.find(C("strRef"))
            nref = cat.find(C("numRef"))
            if sref is not None:
                sheet, vals = _read_ref_values(xl, sref)
                if vals is not None:
                    _set_str_ref(sref, [None if v is None else str(v) for v in vals])
                    touched = True
            elif nref is not None:
                sheet, vals = _read_ref_values(xl, nref)
                if vals is not None:
                    _set_num_ref(nref, vals)
                    touched = True
        # 값
        val = ser.find(C("val"))
        if val is not None:
            nref = val.find(C("numRef"))
            if nref is not None:
                sheet, vals = _read_ref_values(xl, nref)
                if vals is not None:
                    _set_num_ref(nref, vals)
                    touched = True
        if "실적" in _series_name(ser):
            _move_forecast_dash(ser, month, log, chart_label)
    return touched


# ---------------------------------------------------------------------------
# 표 갱신
# ---------------------------------------------------------------------------
def _find_table_shape(slide, name: str):
    for sh in slide.shapes:
        if sh.has_table and sh.name == name:
            return sh
    return None


def _slide_text(slide) -> str:
    parts = []
    for sh in slide.shapes:
        if sh.has_text_frame:
            parts.append(sh.text_frame.text)
        if sh.has_table:
            for row in sh.table.rows:
                for c in row.cells:
                    parts.append(c.text)
    return "\n".join(parts)


def find_slide(prs, spec: dict, log: Log):
    """spec['slide'] 가 숫자면 그 번호의 슬라이드, 문자열이면 그 문구가 들어 있고
    spec['shape'] 표가 있는 슬라이드를 찾는다. (한 장짜리 PPT 든 전체 PPT 든 같은 설정으로 동작)"""
    key = spec["slide"]
    where = f"'{key}'"
    if isinstance(key, int):
        if 1 <= key <= len(prs.slides):
            return prs.slides[key - 1], f"슬라이드 {key}"
        log.warn(f"슬라이드 {key} 이(가) 없습니다(총 {len(prs.slides)}장).")
        return None, where
    key_n = str(key).replace(" ", "")
    hits = []
    for i, slide in enumerate(prs.slides, 1):
        if key_n in _slide_text(slide).replace(" ", "") and _find_table_shape(slide, spec["shape"]) is not None:
            hits.append((i, slide))
    if not hits:
        return None, where
    if len(hits) > 1:
        log.warn(f"'{key}' 문구와 '{spec['shape']}' 표가 있는 슬라이드가 {[i for i, _ in hits]} 여러 장입니다. 첫 번째를 사용합니다.")
    i, slide = hits[0]
    return slide, f"슬라이드 {i}({key})"


def _month_col_start(table) -> int | None:
    """머리글 행에서 '1월' 이 있는 열 번호."""
    for ci, cell in enumerate(table.rows[0].cells):
        if get_cell_text(cell._tc).strip() == "1월":
            return ci
    return None


def update_table(prs, spec: dict, xl: ExcelReader, month: int, log: Log):
    slide, where = find_slide(prs, spec, log)
    shape = _find_table_shape(slide, spec["shape"]) if slide is not None else None
    if shape is None:
        if slide is not None:
            names = [s.name for s in slide.shapes if s.has_table]
            log.warn(f"{where} 에 '{spec['shape']}' 표가 없습니다. (있는 표: {names})")
        else:
            log.info(f"{where} 문구가 있는 슬라이드가 이 PPT 에 없어 '{spec['shape']}' 표는 건너뜁니다.")
        return
    sheet = spec["sheet"]
    if not xl.has_sheet(sheet):
        return
    table = shape.table
    c0 = _month_col_start(table)
    if c0 is None:
        log.warn(f"{where} '{spec['shape']}' 표에서 '1월' 머리글을 찾지 못했습니다.")
        return
    ncols = len(table.columns)
    excel_c0 = column_index_from_string(spec["month_col"])
    filled = 0
    for rs in spec["rows"]:
        prow, erow = rs["ppt_row"], rs.get("excel_row")
        if erow is None:
            log.warn(f"{where} '{spec['shape']}' {prow}행: mapping.json 에 엑셀 행(excel_row)이 비어 있어 건너뜁니다.")
            continue
        kind = rs.get("kind", "fixed")
        row_excel_c0 = column_index_from_string(rs["month_col"]) if rs.get("month_col") else excel_c0
        # 라벨 검증(엑셀 행이 맞는지 확인용)
        label = rs.get("label")
        if label:
            labels = xl.row_labels(sheet, erow, row_excel_c0)
            if not any(label.replace(" ", "") in l.replace(" ", "") for l in labels):
                log.warn(f"'{sheet}' {erow}행 라벨이 '{label}' 이 아닙니다(실제: {labels}). mapping.json 의 excel_row 를 확인하세요.")
        fmt_override = rs.get("fmt")
        for k in range(ncols - c0):
            ci = c0 + k
            ecol = row_excel_c0 + k
            v = xl.cell(sheet, ecol, erow)
            fmt = fmt_override or ("pct" if is_pct_format(xl.number_format(sheet, ecol, erow)) else "amount")
            if k < 12:
                m = k + 1
                if kind == "actual" and m > month:
                    # 당월 다음 달은 예상치 → (괄호). 값이 없거나 0(수식만 있는 빈 칸)이면 빈칸
                    is_num = isinstance(v, (int, float)) and not isinstance(v, bool)
                    text = format_value(v, fmt, paren=True) if (m == month + 1 and is_num and v != 0) else ""
                elif kind == "diff" and m > month:
                    text = ""
                else:
                    text = format_value(v, fmt)
            else:
                text = format_value(v, fmt)
            tc = table.cell(prow, ci)._tc
            set_cell_text(tc, text)
            if text:
                set_cell_color(tc, isinstance(v, (int, float)) and not isinstance(v, bool) and v < 0)
            filled += 1
    log.info(f"{where} '{spec['shape']}' 표: {len(spec['rows'])}행 반영 ({sheet})")


def update_summary_cells(prs, spec: dict, xl: ExcelReader, log: Log):
    """슬라이드 9 처럼 개별 셀에 값을 넣는 항목."""
    slide, where = find_slide(prs, spec, log)
    shape = _find_table_shape(slide, spec["shape"]) if slide is not None else None
    if shape is None:
        if slide is not None:
            log.warn(f"{where} 에 '{spec['shape']}' 표가 없습니다.")
        else:
            log.info(f"{where} 문구가 있는 슬라이드가 이 PPT 에 없어 '{spec['shape']}' 요약표는 건너뜁니다.")
        return
    sheet = spec["sheet"]
    if not xl.has_sheet(sheet):
        return
    table = shape.table
    values = {}
    for item in spec["cells"]:
        r, c = item["ppt_row"], item["ppt_col"]
        src = item.get("excel")
        if src:
            col = re.match(r"([A-Z]+)(\d+)", src)
            v = xl.cell(sheet, col.group(1), int(col.group(2)))
        else:  # 계산식: "a-b" 형태로 같은 spec 안의 셀 이름 참조
            expr = item["calc"]
            a, b = [values.get(x.strip()) for x in expr.split("-")]
            v = None if a is None or b is None else a - b
        values[item.get("name", f"{r},{c}")] = v
        # 요약표는 템플릿의 글자색 규칙(%p 증감은 빨강 등)을 그대로 유지
        set_cell_text(table.cell(r, c)._tc, format_summary(v, item.get("fmt", "eok")))
    log.info(f"{where} '{spec['shape']}' 요약 셀 반영 ({sheet})")


# ---------------------------------------------------------------------------
# 월 문구 갱신
# ---------------------------------------------------------------------------
def update_month_text(prs, month: int, log: Log):
    n = 0
    for si, slide in enumerate(prs.slides, 1):
        for sh in slide.shapes:
            elems = []
            if sh.has_text_frame:
                elems.append(sh._element)
            if sh.has_table:
                elems.append(sh._element)
            for el in elems:
                for body in el.iter(qn("a:txBody"), qn("p:txBody")):
                    n += replace_month_in_paragraphs(body.findall(A_P), month)
    log.info(f"월 표기 문구 {n}곳을 '{month}월' 로 변경")


def detect_template_month(prs) -> int | None:
    for sh in prs.slides[0].shapes:
        if sh.has_text_frame:
            m = re.search(r"(\d{1,2})월\s*경영실적", sh.text_frame.text)
            if m:
                return int(m.group(1))
    return None


# ---------------------------------------------------------------------------
# 메인
# ---------------------------------------------------------------------------
def run(excel: str, ppt: str, out: str | None = None, month: int | None = None,
        mapping_path: str = DEFAULT_MAPPING, printer=print) -> str:
    log = Log(printer)
    with open(mapping_path, encoding="utf-8") as f:
        mapping = json.load(f)

    xl = ExcelReader(excel, mapping.get("sheet_alias"), log)
    prs = Presentation(ppt)

    if month is None:
        for t in mapping["tables"]:
            month = xl.find_month_header(t["sheet"])
            if month:
                break
        if month is None:
            raise SystemExit("월을 자동으로 찾지 못했습니다. --month 로 지정하세요.")
        log.info(f"엑셀 머리글에서 '{month}월 누적' 을 찾아 {month}월 자료로 처리합니다.")
    if not 1 <= month <= 12:
        raise SystemExit("월은 1~12 사이여야 합니다.")
    tmpl_month = detect_template_month(prs)
    log.info(f"PPT 원본: {tmpl_month}월 자료 → {month}월 자료로 갱신 (슬라이드 {len(prs.slides)}장)"
             if tmpl_month else f"PPT {len(prs.slides)}장을 {month}월 자료로 갱신")

    # 1) 차트
    n_chart = 0
    for si, slide in enumerate(prs.slides, 1):
        for sh in slide.shapes:
            if sh.has_chart:
                label = f"슬라이드 {si} '{sh.name}'"
                if update_chart(sh.chart, xl, month, log, label):
                    n_chart += 1
    log.info(f"차트 {n_chart}개 데이터 갱신")

    # 2) 표
    for spec in mapping["tables"]:
        if spec.get("enabled", True):
            update_table(prs, spec, xl, month, log)
    for spec in mapping.get("summary_cells", []):
        if spec.get("enabled", True):
            update_summary_cells(prs, spec, xl, log)

    # 3) 월 문구
    update_month_text(prs, month, log)

    if not out:
        base, _ = os.path.splitext(ppt)
        base = re.sub(r"_\d{1,2}월$", "", base)
        out = f"{base}_{month}월.pptx"
    prs.save(out)
    log.info(f"저장 완료: {out}")

    manual = mapping.get("manual_checklist", [])
    if manual:
        log.info("\n※ 아래 항목은 엑셀에 없는 자료라 직접 입력/확인이 필요합니다:")
        for m in manual:
            log.info("  - " + m)
    if log.warnings:
        log.info(f"\n경고 {len(log.warnings)}건이 있습니다. 위 내용을 확인하세요.")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="엑셀 손익 자료를 월간 경영실적 PPT 에 반영합니다.")
    ap.add_argument("--excel", required=True, help="손익 엑셀 파일(.xlsx)")
    ap.add_argument("--ppt", required=True, help="기준이 될 PPT 파일(지난달 PPT 또는 템플릿)")
    ap.add_argument("--out", help="저장할 PPT 파일 경로")
    ap.add_argument("--month", type=int, help="당월(1~12). 생략하면 엑셀 'N월 누적' 머리글에서 자동 인식")
    ap.add_argument("--mapping", default=DEFAULT_MAPPING, help="표 매핑 설정 파일(mapping.json)")
    a = ap.parse_args(argv)
    run(a.excel, a.ppt, a.out, a.month, a.mapping)


if __name__ == "__main__":
    main()
