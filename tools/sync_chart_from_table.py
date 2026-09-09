#!/usr/bin/env python3
"""
슬라이드 표의 숫자를 바로 아래(또는 위) 차트에 반영한다.

파워포인트에는 슬라이드 위의 표와 차트를 연결하는 기능이 없다. 이 스크립트는
각 슬라이드에서 차트 바로 아래에 붙어 있는 표를 찾아, 표의 월별 값(1월~12월)을
차트의 계열 값으로 덮어쓴다. 어느 표 행이 어느 계열인지는 현재 차트 값과 표 값을
비교해 자동으로 알아내므로(예: 25년 행 -> 25년 계열, %는 소수로, 백만 단위는 원
단위로 환산), 표 이름이 조금 달라도 동작한다.

값이 바뀐 달만 고치고 나머지는 원래의 정밀한 값을 그대로 둔다. 표 칸이 비면
차트에서도 그 달의 점이 사라지고, 괄호 안의 값 "(1,787)"은 숫자로 반영된다.
마지막에 차트에 내장된 워크북도 새 값으로 다시 만들어 "데이터 편집"과 일치시킨다.

사용법:
    python3 tools/sync_chart_from_table.py 입력.pptx 출력.pptx

필요 패키지: lxml, openpyxl
"""
import os
import re
import shutil
import sys
import tempfile
import zipfile

from lxml import etree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from embed_chart_data import convert as embed_workbooks  # noqa: E402

NS = {
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "c": "http://schemas.openxmlformats.org/drawingml/2006/chart",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}
REL_CHART = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart"
MONTHS = [f"{m}월" for m in range(1, 13)]
SCALES = [1, 100, 1_000, 1_000_000, 0.01]
MIN_MATCH = 5  # 계열과 표 행을 같은 것으로 보려면 최소 몇 달이 일치해야 하는지


# ---------- 표 읽기 ----------
def cell_text(tc):
    paras = []
    for p in tc.findall("a:txBody/a:p", NS):
        paras.append("".join(t.text or "" for t in p.findall(".//a:t", NS)))
    return "\n".join(paras).strip()


def parse_number(text):
    """'3,311' -> (3311.0, 0자리), '(3.3%)' -> (0.033, 3자리), '-' -> None"""
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        return None
    # 두 줄인 칸("73.7%\n(76.5%)")은 첫 줄이 값, 둘째 줄은 주석
    s = lines[0].replace("　", "").replace(",", "").replace(" ", "").strip()
    s = s.strip("()")
    if s in ("", "-", "—", "X", "x"):
        return None
    pct = s.endswith("%")
    s = s.rstrip("%")
    m = re.fullmatch(r"[-+−]?\d+(?:\.\d+)?", s)
    if not m:
        return None
    v = float(s.replace("−", "-"))
    decimals = len(s.split(".")[1]) if "." in s else 0
    if pct:
        return v / 100.0, decimals + 2
    return v, decimals


def read_table(frame):
    tbl = frame.find(".//a:tbl", NS)
    rows = [[cell_text(tc) for tc in tr.findall("a:tc", NS)] for tr in tbl.findall("a:tr", NS)]
    month_cols = {}
    for r in rows[:2]:
        for j, t in enumerate(r):
            key = t.replace("\n", "").replace(" ", "")
            if key in MONTHS and key not in month_cols:
                month_cols[key] = j
    if len(month_cols) < 6:
        return None
    data_rows = []
    for i, r in enumerate(rows):
        vals = {}
        for mth, j in month_cols.items():
            if j < len(r):
                vals[mth] = parse_number(r[j])
        if any(v is not None for v in vals.values()):
            label = " ".join(x.replace("\n", " ") for x in r[: min(month_cols.values())] if x)
            data_rows.append((i, label, vals))
    return data_rows


# ---------- 차트 읽기/쓰기 ----------
def series_info(ser):
    cat = ser.find("c:cat", NS)
    val = ser.find("c:val", NS)
    if cat is None or val is None:
        return None
    cat_cache = cat.find(".//c:strCache", NS)
    num_cache = val.find(".//c:numCache", NS)
    if cat_cache is None or num_cache is None:
        return None
    idx_of = {}
    for pt in cat_cache.findall("c:pt", NS):
        key = (pt.findtext("c:v", namespaces=NS) or "").replace(" ", "")
        if key in MONTHS:
            idx_of[key] = int(pt.get("idx"))
    if len(idx_of) < 6:
        return None
    values = {int(pt.get("idx")): float(pt.findtext("c:v", namespaces=NS)) for pt in num_cache.findall("c:pt", NS)}
    tx = ser.find("c:tx", NS)
    name = (tx.findtext(".//c:v", namespaces=NS) or "").strip() if tx is not None else ""
    return {"name": name, "idx_of": idx_of, "values": values, "cache": num_cache}


def fmt_num(v):
    if float(v).is_integer():
        return str(int(v))
    return f"{v:.12g}"


def set_point(cache, idx, value):
    """numCache 안의 pt를 idx 순서를 지키며 추가/수정/삭제"""
    pts = {int(pt.get("idx")): pt for pt in cache.findall("c:pt", NS)}
    if value is None:
        if idx in pts:
            cache.remove(pts[idx])
        return
    if idx in pts:
        pts[idx].find("c:v", NS).text = fmt_num(value)
        return
    pt = etree.SubElement(cache, "{%s}pt" % NS["c"])
    pt.set("idx", str(idx))
    etree.SubElement(pt, "{%s}v" % NS["c"]).text = fmt_num(value)
    # idx 순서대로 재정렬
    later = [p for i, p in pts.items() if i > idx]
    if later:
        first = min(later, key=lambda p: int(p.get("idx")))
        first.addprevious(pt)


def score(ser, row_vals, scale):
    hits = misses = 0
    for mth, idx in ser["idx_of"].items():
        tv = row_vals.get(mth)
        cv = ser["values"].get(idx)
        if tv is None or cv is None:
            continue
        v, dec = tv
        tol = 0.55 * scale * 10 ** (-dec)
        if abs(cv - v * scale) <= tol:
            hits += 1
        else:
            misses += 1
    return hits, misses


def sync_chart(chart_path, rows, label):
    tree = etree.parse(chart_path)
    root = tree.getroot()
    changes = []
    used = set()
    for ser_el in root.iter("{%s}ser" % NS["c"]):
        ser = series_info(ser_el)
        if ser is None:
            continue
        best = None
        for ri, rlabel, vals in rows:
            if ri in used:
                continue
            for s in SCALES:
                h, m = score(ser, vals, s)
                if h >= MIN_MATCH and (best is None or (h, -m) > (best[0], -best[1])):
                    best = (h, m, ri, rlabel, vals, s)
        if best is None:
            print(f"  [{label}] 계열 '{ser['name']}' 과 맞는 표 행을 찾지 못해 건너뜀")
            continue
        h, m, ri, rlabel, vals, s = best
        used.add(ri)
        for mth, idx in ser["idx_of"].items():
            tv = vals.get(mth)
            cv = ser["values"].get(idx)
            if tv is None:
                if cv is not None:
                    set_point(ser["cache"], idx, None)
                    changes.append(f"{ser['name'] or rlabel} {mth}: {fmt_num(cv)} -> 삭제")
                continue
            v, dec = tv
            if cv is not None and abs(cv - v * s) <= 0.55 * s * 10 ** (-dec):
                continue  # 표시값이 같으면 원래 정밀값 유지
            new = round(v * s, 10)
            set_point(ser["cache"], idx, new)
            changes.append(f"{ser['name'] or rlabel} {mth}: {fmt_num(cv) if cv is not None else '없음'} -> {fmt_num(new)}")
    if changes:
        tree.write(chart_path, xml_declaration=True, encoding="UTF-8", standalone=True)
    return changes


# ---------- 슬라이드 처리 ----------
def frames(slide_root):
    out = []
    for gf in slide_root.iter("{%s}graphicFrame" % NS["p"]):
        off = gf.find("p:xfrm/a:off", NS)
        ext = gf.find("p:xfrm/a:ext", NS)
        if off is None or ext is None:
            continue
        y, h = int(off.get("y")), int(ext.get("cy"))
        chart = gf.find(".//c:chart", NS)
        tbl = gf.find(".//a:tbl", NS)
        if chart is not None:
            out.append(("chart", y, h, chart.get("{%s}id" % NS["r"]), gf))
        elif tbl is not None:
            out.append(("table", y, h, None, gf))
    return out


def pair_charts_with_tables(items):
    charts = [i for i in items if i[0] == "chart"]
    tables = [i for i in items if i[0] == "table"]
    pairs = []
    free = set(range(len(tables)))
    for ch in sorted(charts, key=lambda i: i[1]):
        ch_bottom = ch[1] + ch[2]
        best = None
        for ti in free:
            t = tables[ti]
            if t[1] < ch[1] + ch[2] / 2:  # 표 상단이 차트 중간보다 위면 아래 표가 아님
                continue
            gap = abs(t[1] - ch_bottom)
            if best is None or gap < best[0]:
                best = (gap, ti)
        if best is not None:
            free.discard(best[1])
            pairs.append((ch, tables[best[1]]))
    return pairs


def sync(src, dst):
    work = tempfile.mkdtemp(prefix="pptx_sync_")
    try:
        with zipfile.ZipFile(src) as z:
            names = [i.filename for i in z.infolist()]
            z.extractall(work)
        slide_dir = os.path.join(work, "ppt", "slides")
        total = 0
        for sf in sorted(os.listdir(slide_dir), key=lambda f: int(re.findall(r"\d+", f)[0]) if re.fullmatch(r"slide\d+\.xml", f) else 0):
            if not re.fullmatch(r"slide\d+\.xml", sf):
                continue
            sno = int(re.findall(r"\d+", sf)[0])
            root = etree.parse(os.path.join(slide_dir, sf)).getroot()
            rels = etree.parse(os.path.join(slide_dir, "_rels", sf + ".rels")).getroot()
            rel_target = {e.get("Id"): e.get("Target") for e in rels if e.get("Type") == REL_CHART}
            for ch, tb in pair_charts_with_tables(frames(root)):
                rows = read_table(tb[4])
                if not rows:
                    continue
                cpath = os.path.normpath(os.path.join(slide_dir, rel_target[ch[3]]))
                label = f"슬라이드 {sno} / {os.path.basename(cpath)}"
                changes = sync_chart(cpath, rows, label)
                total += len(changes)
                print(f"{label}: 변경 {len(changes)}건")
                for c in changes:
                    print(f"    {c}")
        tmp = os.path.join(work, "_synced.pptx")
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
            for name in names:
                zout.write(os.path.join(work, name), name)
        print(f"표 -> 차트 반영 {total}건. 내장 워크북 갱신 중...")
        embed_workbooks(tmp, dst)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sync(sys.argv[1], sys.argv[2])
