# -*- coding: utf-8 -*-
"""
월간 경영실적 PPT 자동 생성 - 화면 프로그램

실행:  python gui.py   (또는 실행.bat 더블클릭)
- 엑셀/PPT 파일을 창 안에 끌어다 놓거나, 상자를 클릭해 선택
- [PPT 만들기] 를 누르면 결과가 초록(성공)/빨강(실패) 배너로 표시
"""
import os
import re
import subprocess
import sys
import threading
import traceback
import tkinter as tk
from tkinter import filedialog, ttk

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import update_ppt  # noqa: E402

# 드래그 앤 드롭 (tkinterdnd2 가 없으면 클릭 선택만 동작)
try:
    from tkinterdnd2 import DND_FILES, TkinterDnD
    HAS_DND = True
except Exception:  # noqa: BLE001
    HAS_DND = False

# ----- 색상/글꼴 -------------------------------------------------------------
BG = "#F3F5F9"          # 창 배경
CARD = "#FFFFFF"        # 카드
BORDER = "#D5DAE3"
TEXT = "#1F2937"
MUTED = "#6B7280"
PRIMARY = "#2563EB"     # 파랑
PRIMARY_DK = "#1D4ED8"
OK_BG, OK_FG, OK_LINE = "#DCFCE7", "#166534", "#22C55E"
ERR_BG, ERR_FG, ERR_LINE = "#FEE2E2", "#991B1B", "#EF4444"
WARN_FG = "#B45309"
DROP_IDLE, DROP_HOVER, DROP_DONE = "#F8FAFC", "#EFF6FF", "#F0FDF4"
FONT = "맑은 고딕" if sys.platform.startswith("win") else "NanumGothic"


def font(size=10, bold=False):
    return (FONT, size, "bold" if bold else "normal")


def friendly_error(text: str) -> str:
    """자주 나오는 오류를 알기 쉬운 문장으로."""
    t = text.lower()
    if "does not support" in t and "file format" in t:
        return "엑셀 자리에 엑셀 파일(.xlsx)이 아닌 파일이 들어갔습니다."
    if "permission denied" in t or "errno 13" in t:
        return "파일이 다른 프로그램(엑셀/파워포인트)에서 열려 있습니다. 닫고 다시 시도하세요."
    if "no such file" in t or "errno 2" in t:
        return "파일을 찾을 수 없습니다. 경로를 확인하세요."
    if "package not found" in t or "not a zip" in t or "badzipfile" in t:
        return "PPT 파일이 손상되었거나 .pptx 형식이 아닙니다."
    return text


class DropZone(tk.Frame):
    """파일을 끌어다 놓거나 클릭해서 고르는 상자."""

    def __init__(self, master, title, hint, exts, on_change, **kw):
        super().__init__(master, bg=DROP_IDLE, highlightbackground=BORDER,
                         highlightthickness=2, cursor="hand2", **kw)
        self.exts, self.on_change, self.path = exts, on_change, ""
        self.title_lbl = tk.Label(self, text=title, font=font(11, True), bg=DROP_IDLE, fg=TEXT)
        self.icon_lbl = tk.Label(self, text="⬇", font=(FONT, 26), bg=DROP_IDLE, fg=MUTED)
        self.file_lbl = tk.Label(self, text="", font=font(10, True), bg=DROP_IDLE, fg=OK_FG,
                                 wraplength=300, justify="center")
        self.hint_lbl = tk.Label(self, text=hint, font=font(9), bg=DROP_IDLE, fg=MUTED,
                                 wraplength=300, justify="center")
        self.title_lbl.pack(pady=(14, 2))
        self.icon_lbl.pack()
        self.file_lbl.pack(padx=12)
        self.hint_lbl.pack(pady=(2, 14), padx=12)
        for w in (self, self.title_lbl, self.icon_lbl, self.file_lbl, self.hint_lbl):
            w.bind("<Button-1>", self.pick)
            w.bind("<Enter>", lambda e: self._paint(DROP_HOVER if not self.path else DROP_DONE, PRIMARY))
            w.bind("<Leave>", lambda e: self._paint(DROP_DONE if self.path else DROP_IDLE,
                                                    OK_LINE if self.path else BORDER))
            if HAS_DND:
                w.drop_target_register(DND_FILES)
                w.dnd_bind("<<Drop>>", self.on_drop)
                w.dnd_bind("<<DragEnter>>", lambda e: self._paint(DROP_HOVER, PRIMARY))
                w.dnd_bind("<<DragLeave>>", lambda e: self._paint(DROP_DONE if self.path else DROP_IDLE,
                                                                  OK_LINE if self.path else BORDER))

    def _paint(self, bg, line):
        self.configure(bg=bg, highlightbackground=line, highlightcolor=line)
        for w in (self.title_lbl, self.icon_lbl, self.file_lbl, self.hint_lbl):
            w.configure(bg=bg)

    def pick(self, _=None):
        p = filedialog.askopenfilename(title=self.title_lbl.cget("text"),
                                       filetypes=[(self.title_lbl.cget("text"), " ".join("*" + e for e in self.exts)),
                                                  ("모든 파일", "*.*")])
        if p:
            self.set_path(p)

    def on_drop(self, event):
        for p in self.winfo_toplevel().tk.splitlist(event.data):
            if os.path.splitext(p)[1].lower() in self.exts:
                self.set_path(p)
                return
        self.winfo_toplevel().show_banner("error", f"{'/'.join(self.exts)} 파일만 놓을 수 있습니다.")

    def set_path(self, p):
        self.path = p
        self.icon_lbl.configure(text="✔", fg=OK_LINE)
        self.file_lbl.configure(text=os.path.basename(p))
        self.hint_lbl.configure(text=os.path.dirname(p))
        self._paint(DROP_DONE, OK_LINE)
        self.on_change(p)


class App(TkinterDnD.Tk if HAS_DND else tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("월간 경영실적 PPT 자동 생성")
        self.geometry("860x720")
        self.minsize(760, 620)
        self.configure(bg=BG)
        self._style()
        self.out_var, self.month_var = tk.StringVar(), tk.StringVar()
        self.result_path = None
        self._build()
        if HAS_DND:  # 창 아무 곳에나 놓아도 확장자로 구분해서 받는다
            self.drop_target_register(DND_FILES)
            self.dnd_bind("<<Drop>>", self.on_drop_anywhere)

    # ---------------------------------------------------------------- UI
    def _style(self):
        st = ttk.Style(self)
        try:
            st.theme_use("clam")
        except tk.TclError:
            pass
        st.configure("TCombobox", fieldbackground=CARD, padding=4)
        st.configure("Run.TButton", font=font(13, True), foreground="white", background=PRIMARY,
                     borderwidth=0, padding=(24, 12))
        st.map("Run.TButton", background=[("active", PRIMARY_DK), ("disabled", "#93C5FD")])
        st.configure("Ghost.TButton", font=font(10), foreground=TEXT, background=CARD,
                     bordercolor=BORDER, padding=(12, 6))
        st.map("Ghost.TButton", background=[("active", "#E5E7EB")])

    def _card(self, parent):
        return tk.Frame(parent, bg=CARD, highlightbackground=BORDER, highlightthickness=1)

    def _build(self):
        # 머리글
        head = tk.Frame(self, bg=BG)
        head.pack(fill="x", padx=28, pady=(22, 10))
        tk.Label(head, text="월간 경영실적 PPT 자동 생성", font=font(18, True), bg=BG, fg=TEXT).pack(anchor="w")
        tk.Label(head, text="손익 엑셀과 지난달 PPT 를 끌어다 놓고 [PPT 만들기] 를 누르세요." +
                 ("" if HAS_DND else "   (끌어놓기 모듈이 없어 클릭 선택만 됩니다: pip install tkinterdnd2)"),
                 font=font(10), bg=BG, fg=MUTED).pack(anchor="w", pady=(2, 0))

        # 파일 상자 2개
        zones = tk.Frame(self, bg=BG)
        zones.pack(fill="x", padx=28)
        zones.columnconfigure((0, 1), weight=1, uniform="z")
        self.excel_zone = DropZone(zones, "① 손익 엑셀 파일", "여기에 .xlsx 파일을 끌어다 놓거나 클릭해서 선택",
                                   (".xlsx", ".xlsm"), self.on_excel)
        self.ppt_zone = DropZone(zones, "② 기준 PPT (지난달 파일)", "여기에 .pptx 파일을 끌어다 놓거나 클릭해서 선택",
                                 (".pptx",), self.on_ppt)
        self.excel_zone.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        self.ppt_zone.grid(row=0, column=1, sticky="nsew", padx=(8, 0))

        # 옵션 카드
        card = self._card(self)
        card.pack(fill="x", padx=28, pady=14)
        inner = tk.Frame(card, bg=CARD)
        inner.pack(fill="x", padx=16, pady=12)
        inner.columnconfigure(1, weight=1)
        tk.Label(inner, text="당월", font=font(10, True), bg=CARD, fg=TEXT).grid(row=0, column=0, sticky="w", pady=4)
        mf = tk.Frame(inner, bg=CARD)
        mf.grid(row=0, column=1, sticky="w", padx=12, pady=4)
        self.month_box = ttk.Combobox(mf, textvariable=self.month_var, width=5, state="readonly",
                                      values=[str(i) for i in range(1, 13)], font=font(11))
        self.month_box.pack(side="left")
        tk.Label(mf, text="월", font=font(11), bg=CARD, fg=TEXT).pack(side="left", padx=(4, 12))
        self.month_hint = tk.Label(mf, text="엑셀을 고르면 'N월 누적' 머리글에서 자동으로 채워집니다.",
                                   font=font(9), bg=CARD, fg=MUTED)
        self.month_hint.pack(side="left")
        tk.Label(inner, text="저장 파일", font=font(10, True), bg=CARD, fg=TEXT).grid(row=1, column=0, sticky="w", pady=4)
        of = tk.Frame(inner, bg=CARD)
        of.grid(row=1, column=1, sticky="ew", padx=12, pady=4)
        of.columnconfigure(0, weight=1)
        tk.Entry(of, textvariable=self.out_var, font=font(10), relief="solid", bd=1,
                 highlightthickness=0).grid(row=0, column=0, sticky="ew", ipady=4)
        ttk.Button(of, text="변경", style="Ghost.TButton", command=self.pick_out).grid(row=0, column=1, padx=(8, 0))

        # 실행 버튼
        self.run_btn = ttk.Button(self, text="▶  PPT 만들기", style="Run.TButton", command=self.run)
        self.run_btn.pack(pady=(2, 6))

        # 결과 배너 (평소엔 숨김)
        self.banner = tk.Frame(self, bg=OK_BG, highlightthickness=1, highlightbackground=OK_LINE)
        self.banner_icon = tk.Label(self.banner, text="", font=(FONT, 22, "bold"), bg=OK_BG, fg=OK_FG)
        self.banner_icon.pack(side="left", padx=(16, 8), pady=10)
        bt = tk.Frame(self.banner, bg=OK_BG)
        bt.pack(side="left", fill="x", expand=True, pady=10)
        self.banner_title = tk.Label(bt, text="", font=font(13, True), bg=OK_BG, fg=OK_FG, anchor="w")
        self.banner_title.pack(anchor="w")
        self.banner_msg = tk.Label(bt, text="", font=font(10), bg=OK_BG, fg=OK_FG, anchor="w",
                                   justify="left", wraplength=560)
        self.banner_msg.pack(anchor="w")
        self.banner_btn = ttk.Button(self.banner, text="폴더 열기", style="Ghost.TButton", command=self.open_folder)
        self.banner_btn.pack(side="right", padx=16)

        # 로그
        logf = self._card(self)
        logf.pack(fill="both", expand=True, padx=28, pady=(6, 22))
        tk.Label(logf, text="처리 내용", font=font(10, True), bg=CARD, fg=MUTED).pack(anchor="w", padx=14, pady=(8, 0))
        self.log = tk.Text(logf, height=10, wrap="word", font=font(9), bg=CARD, fg=TEXT, relief="flat",
                           padx=12, pady=6, state="disabled")
        sb = ttk.Scrollbar(logf, command=self.log.yview)
        self.log.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y", pady=6)
        self.log.pack(fill="both", expand=True, padx=(2, 0), pady=(0, 6))
        self.log.tag_config("warn", foreground=WARN_FG)
        self.log.tag_config("err", foreground=ERR_FG)
        self.log.tag_config("ok", foreground=OK_FG)

    # ------------------------------------------------------------ 이벤트
    def on_drop_anywhere(self, event):
        got = False
        for p in self.tk.splitlist(event.data):
            ext = os.path.splitext(p)[1].lower()
            if ext in (".xlsx", ".xlsm"):
                self.excel_zone.set_path(p); got = True
            elif ext == ".pptx":
                self.ppt_zone.set_path(p); got = True
        if not got:
            self.show_banner("error", "엑셀(.xlsx) 또는 PPT(.pptx) 파일을 놓아 주세요.")

    def on_excel(self, p):
        self.hide_banner()
        try:
            xl = update_ppt.ExcelReader(p, log=update_ppt.Log(lambda m: None))
            for name in xl.wb_val.sheetnames:
                m = xl.find_month_header(name)
                if m:
                    self.month_var.set(str(m))
                    self.month_hint.configure(text=f"엑셀 '{name}' 시트의 '{m}월 누적' 머리글에서 자동 인식", fg=OK_FG)
                    break
            else:
                self.month_hint.configure(text="엑셀에서 'N월 누적' 머리글을 찾지 못했습니다. 직접 고르세요.", fg=WARN_FG)
        except Exception as e:  # noqa: BLE001
            self.month_hint.configure(text="엑셀 파일을 읽지 못했습니다. 파일 형식을 확인하세요.", fg=ERR_FG)
            self.write(f"[경고] 엑셀 읽기 실패: {e}\n", "warn")
        self._suggest_out()

    def on_ppt(self, p):
        self.hide_banner()
        self._suggest_out(force=True)

    def _suggest_out(self, force=False):
        ppt = self.ppt_zone.path
        if not ppt or (self.out_var.get() and not force):
            return
        base = re.sub(r"_\d{1,2}월$", "", os.path.splitext(ppt)[0])
        self.out_var.set(f"{base}_{self.month_var.get() or 'N'}월.pptx")

    def pick_out(self):
        p = filedialog.asksaveasfilename(title="저장할 PPT 파일", defaultextension=".pptx",
                                         filetypes=[("PowerPoint", "*.pptx")],
                                         initialfile=os.path.basename(self.out_var.get() or ""))
        if p:
            self.out_var.set(p)

    def open_folder(self):
        if not self.result_path:
            return
        folder = os.path.dirname(os.path.abspath(self.result_path))
        try:
            if sys.platform.startswith("win"):
                subprocess.Popen(["explorer", "/select,", os.path.abspath(self.result_path)])
            elif sys.platform == "darwin":
                subprocess.Popen(["open", folder])
            else:
                subprocess.Popen(["xdg-open", folder])
        except Exception:  # noqa: BLE001
            pass

    # ------------------------------------------------------------ 배너/로그
    def show_banner(self, kind, msg, title=None, show_button=False):
        ok = kind == "ok"
        bg, fg, line = (OK_BG, OK_FG, OK_LINE) if ok else (ERR_BG, ERR_FG, ERR_LINE)
        for w in (self.banner, self.banner_icon, self.banner_title, self.banner_msg, self.banner_msg.master):
            w.configure(bg=bg)
        self.banner.configure(highlightbackground=line)
        self.banner_icon.configure(text="✔" if ok else "✖", fg=fg)
        self.banner_title.configure(text=title or ("성공" if ok else "실패"), fg=fg)
        self.banner_msg.configure(text=msg, fg=fg)
        if show_button:
            self.banner_btn.pack(side="right", padx=16)
        else:
            self.banner_btn.pack_forget()
        self.banner.pack(fill="x", padx=28, pady=(4, 6), before=self.log.master)

    def hide_banner(self):
        self.banner.pack_forget()

    def write(self, msg, tag=None):
        self.log.configure(state="normal")
        self.log.insert("end", msg, tag)
        self.log.see("end")
        self.log.configure(state="disabled")

    def clear_log(self):
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

    # ------------------------------------------------------------ 실행
    def run(self):
        excel, ppt, out = self.excel_zone.path, self.ppt_zone.path, self.out_var.get().strip()
        if not excel or not os.path.exists(excel):
            self.show_banner("error", "① 손익 엑셀 파일을 먼저 선택하세요."); return
        if not ppt or not os.path.exists(ppt):
            self.show_banner("error", "② 기준 PPT 파일을 먼저 선택하세요."); return
        if not self.month_var.get():
            self.show_banner("error", "당월을 선택하세요."); return
        month = int(self.month_var.get())
        self.hide_banner()
        self.clear_log()
        self.run_btn.configure(text="처리 중…", state="disabled")

        def printer(msg):
            tag = "warn" if msg.startswith("[경고]") else None
            self.after(0, lambda: self.write(msg + "\n", tag))

        def work():
            try:
                result = update_ppt.run(excel, ppt, out or None, month, printer=printer)
                self.after(0, lambda: self._done_ok(result))
            except Exception as exc:  # noqa: BLE001
                err_text, err_trace = str(exc), traceback.format_exc()
                self.after(0, lambda: self._done_err(err_text, err_trace))

        threading.Thread(target=work, daemon=True).start()

    def _done_ok(self, result):
        self.result_path = result
        text = self.log.get("1.0", "end")
        n_warn = text.count("[경고]")
        msg = f"저장 위치: {result}"
        if n_warn:
            msg += f"\n경고 {n_warn}건이 있습니다. 아래 처리 내용을 확인하세요."
        self.show_banner("ok", msg, title="완료! PPT 를 만들었습니다.", show_button=True)
        self.write("\n완료\n", "ok")
        self.run_btn.configure(text="▶  PPT 만들기", state="normal")

    def _done_err(self, err_text, err_trace):
        self.write(err_trace, "err")
        self.show_banner("error", f"{friendly_error(err_text)}\n자세한 내용은 아래 처리 내용을 확인하세요.",
                         title="실패: PPT 를 만들지 못했습니다.")
        self.run_btn.configure(text="▶  PPT 만들기", state="normal")


if __name__ == "__main__":
    App().mainloop()
