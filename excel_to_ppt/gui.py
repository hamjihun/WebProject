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
    """파일을 끌어다 놓거나 클릭해서 고르는 상자. 오른쪽 위 ✕ 로 취소, 읽는 동안 로딩 표시."""

    def __init__(self, master, title, hint, exts, on_change, on_clear, **kw):
        super().__init__(master, bg=DROP_IDLE, highlightbackground=BORDER,
                         highlightthickness=2, cursor="hand2", **kw)
        self.exts, self.on_change, self.on_clear = exts, on_change, on_clear
        self.path, self.busy, self.hint = "", False, hint
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
        # 취소(✕) 버튼: 파일이 들어왔을 때만 오른쪽 위에 표시
        self.clear_btn = tk.Label(self, text="✕", font=font(13, True), bg=DROP_DONE, fg=TEXT, cursor="hand2", padx=6)
        self.clear_btn.bind("<Button-1>", self.clear)
        self.clear_btn.bind("<Enter>", lambda e: self.clear_btn.configure(fg=ERR_LINE))
        self.clear_btn.bind("<Leave>", lambda e: self.clear_btn.configure(fg=TEXT))
        for w in (self, self.title_lbl, self.icon_lbl, self.file_lbl, self.hint_lbl):
            w.bind("<Button-1>", self.pick)
            w.bind("<Enter>", lambda e: self._hover(True))
            w.bind("<Leave>", lambda e: self._hover(False))
            if HAS_DND:
                w.drop_target_register(DND_FILES)
                w.dnd_bind("<<Drop>>", self.on_drop)
                w.dnd_bind("<<DragEnter>>", lambda e: self._hover(True))
                w.dnd_bind("<<DragLeave>>", lambda e: self._hover(False))

    # ---- 상태별 색 ----
    def _paint(self, bg, line):
        self.configure(bg=bg, highlightbackground=line, highlightcolor=line)
        for w in (self.title_lbl, self.icon_lbl, self.file_lbl, self.hint_lbl, self.clear_btn):
            w.configure(bg=bg)

    def _restore(self):
        if self.busy:
            self._paint(DROP_HOVER, PRIMARY)
        elif self.path:
            self._paint(DROP_DONE, OK_LINE)
        else:
            self._paint(DROP_IDLE, BORDER)

    def _hover(self, on):
        if on and not self.busy:
            self._paint(DROP_HOVER, PRIMARY)
        else:
            self._restore()

    # ---- 파일 선택/놓기 ----
    def pick(self, _=None):
        if self.busy:
            return
        p = filedialog.askopenfilename(title=self.title_lbl.cget("text"),
                                       filetypes=[(self.title_lbl.cget("text"), " ".join("*" + e for e in self.exts)),
                                                  ("모든 파일", "*.*")])
        if p:
            self.set_path(p)

    def on_drop(self, event):
        if self.busy:
            return
        for p in self.winfo_toplevel().tk.splitlist(event.data):
            if os.path.splitext(p)[1].lower() in self.exts:
                self.set_path(p)
                return
        self.winfo_toplevel().show_banner("error", f"{'/'.join(self.exts)} 파일만 놓을 수 있습니다.")

    def set_path(self, p):
        """파일을 받아 '읽는 중' 표시 → on_change(경로) 가 백그라운드에서 읽고 set_info() 로 마무리."""
        self.path = p
        self.busy = True
        self.icon_lbl.configure(text="⏳", fg=PRIMARY)
        self.file_lbl.configure(text=os.path.basename(p), fg=PRIMARY)
        self.hint_lbl.configure(text="읽는 중… 잠시만 기다려 주세요", fg=PRIMARY)
        self.clear_btn.place_forget()
        self.configure(cursor="watch")
        self._restore()
        self.on_change(p)

    def set_info(self, ok, info):
        """읽기가 끝난 뒤 결과 표시. ok=False 면 빨간 표시(파일은 그대로 두어 ✕ 로 지울 수 있게)."""
        self.busy = False
        self.configure(cursor="hand2")
        if ok:
            self.icon_lbl.configure(text="✔", fg=OK_LINE)
            self.file_lbl.configure(fg=OK_FG)
            self.hint_lbl.configure(text=info, fg=MUTED)
            self._paint(DROP_DONE, OK_LINE)
        else:
            self.icon_lbl.configure(text="✖", fg=ERR_LINE)
            self.file_lbl.configure(fg=ERR_FG)
            self.hint_lbl.configure(text=info, fg=ERR_FG)
            self._paint(ERR_BG, ERR_LINE)
        self.clear_btn.place(relx=1.0, x=-6, y=6, anchor="ne")

    def clear(self, _=None):
        self.path, self.busy = "", False
        self.icon_lbl.configure(text="⬇", fg=MUTED)
        self.file_lbl.configure(text="", fg=OK_FG)
        self.hint_lbl.configure(text=self.hint, fg=MUTED)
        self.clear_btn.place_forget()
        self.configure(cursor="hand2")
        self._paint(DROP_IDLE, BORDER)
        self.on_clear()


class App(TkinterDnD.Tk if HAS_DND else tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("월간 경영실적 PPT 자동 생성")
        self.geometry("860x780")
        self.minsize(760, 660)
        self.configure(bg=BG)
        self._set_icon()
        self._style()
        self.out_var, self.month_var = tk.StringVar(), tk.StringVar()
        self.result_path = None
        self._build()
        if HAS_DND:  # 창 아무 곳에나 놓아도 확장자로 구분해서 받는다
            self.drop_target_register(DND_FILES)
            self.dnd_bind("<<Drop>>", self.on_drop_anywhere)

    # ---------------------------------------------------------------- UI
    def _set_icon(self):
        base = getattr(sys, "_MEIPASS", HERE)
        try:
            if sys.platform.startswith("win"):
                self.iconbitmap(os.path.join(base, "app.ico"))
            else:
                self.iconphoto(True, tk.PhotoImage(file=os.path.join(base, "app.png")))
        except Exception:  # noqa: BLE001
            pass

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
                                   (".xlsx", ".xlsm"), self.on_excel, self.on_excel_clear)
        self.ppt_zone = DropZone(zones, "② 기준 PPT (지난달 파일)", "여기에 .pptx 파일을 끌어다 놓거나 클릭해서 선택",
                                 (".pptx",), self.on_ppt, self.on_ppt_clear)
        self.excel_zone.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        self.ppt_zone.grid(row=0, column=1, sticky="nsew", padx=(8, 0))

        # 옵션 카드
        card = self._card(self)
        card.pack(fill="x", padx=28, pady=14)
        inner = tk.Frame(card, bg=CARD)
        inner.pack(fill="x", padx=16, pady=12)
        inner.columnconfigure(1, weight=1)
        tk.Label(inner, text="마감 월", font=font(10, True), bg=CARD, fg=TEXT).grid(row=0, column=0, sticky="w", pady=4)
        mf = tk.Frame(inner, bg=CARD)
        mf.grid(row=0, column=1, sticky="w", padx=12, pady=4)
        self.month_box = ttk.Combobox(mf, textvariable=self.month_var, width=5, state="readonly",
                                      values=[str(i) for i in range(1, 13)], font=font(11))
        self.month_box.pack(side="left")
        self.month_box.bind("<<ComboboxSelected>>", lambda e: self._month_changed())
        tk.Label(mf, text="월", font=font(11), bg=CARD, fg=TEXT).pack(side="left", padx=(4, 12))
        self.month_hint = tk.Label(mf, text="엑셀의 'N월 누적' 머리글에서 자동으로 채워집니다.",
                                   font=font(9), bg=CARD, fg=MUTED)
        self.month_hint.pack(side="left")
        tk.Label(inner, text="실적이 확정된 달입니다. 그 다음 달 값이 엑셀에 있으면 예상치로 표에는 (괄호), 차트에는 점선으로 표시되고, "
                 "제목과 '누적' 머리글의 월도 이 값으로 바뀝니다.",
                 font=font(9), bg=CARD, fg=MUTED, wraplength=720, justify="left").grid(row=2, column=0, columnspan=2, sticky="w", pady=(0, 2))
        self.month_note = tk.Label(inner, text="", font=font(9), bg=CARD, fg=OK_FG, wraplength=720, justify="left")
        self.month_note.grid(row=3, column=0, columnspan=2, sticky="w")
        tk.Label(inner, text="저장 파일", font=font(10, True), bg=CARD, fg=TEXT).grid(row=4, column=0, sticky="w", pady=4)
        of = tk.Frame(inner, bg=CARD)
        of.grid(row=4, column=1, sticky="ew", padx=12, pady=4)
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
        """엑셀을 백그라운드에서 읽어 시트 수와 마감 월을 알아낸다 (읽는 동안 상자에 로딩 표시)."""
        self.hide_banner()
        self.month_note.configure(text="")

        def work():
            try:
                xl = update_ppt.ExcelReader(p, log=update_ppt.Log(lambda m: None))
                names = xl.wb_val.sheetnames
                month, found_in = None, None
                for name in names:
                    month = xl.find_month_header(name)
                    if month:
                        found_in = name
                        break
                self.after(0, lambda: self._excel_done(p, names, month, found_in))
            except Exception as e:  # noqa: BLE001
                msg = friendly_error(str(e))
                self.after(0, lambda: self._excel_failed(msg))

        threading.Thread(target=work, daemon=True).start()

    def _excel_done(self, p, names, month, found_in):
        if self.excel_zone.path != p:  # 읽는 동안 다른 파일로 바뀜
            return
        if month:
            self.month_var.set(str(month))
            self.month_hint.configure(text=f"'{found_in}' 시트의 '{month}월 누적' 머리글에서 자동 인식", fg=OK_FG)
            self._month_changed()
        else:
            self.month_hint.configure(text="엑셀에서 'N월 누적' 머리글을 찾지 못했습니다. 직접 고르세요.", fg=WARN_FG)
        self.excel_zone.set_info(True, f"시트 {len(names)}개  ·  {os.path.dirname(p)}")
        self._suggest_out()

    def _excel_failed(self, msg):
        self.month_hint.configure(text="엑셀 파일을 읽지 못했습니다.", fg=ERR_FG)
        self.excel_zone.set_info(False, msg)

    def on_excel_clear(self):
        self.hide_banner()
        self.month_var.set("")
        self.month_hint.configure(text="엑셀의 'N월 누적' 머리글에서 자동으로 채워집니다.", fg=MUTED)
        self.month_note.configure(text="")

    def on_ppt(self, p):
        """PPT 를 백그라운드에서 열어 슬라이드 수와 원본 월을 확인한다."""
        self.hide_banner()

        def work():
            try:
                prs = update_ppt.Presentation(p)
                n = len(prs.slides)
                tm = update_ppt.detect_template_month(prs)
                self.after(0, lambda: self._ppt_done(p, n, tm))
            except Exception as e:  # noqa: BLE001
                msg = friendly_error(str(e))
                self.after(0, lambda: self.ppt_zone.set_info(False, msg))

        threading.Thread(target=work, daemon=True).start()

    def _ppt_done(self, p, n, tm):
        if self.ppt_zone.path != p:
            return
        info = f"슬라이드 {n}장" + (f"  ·  {tm}월 자료" if tm else "") + f"  ·  {os.path.dirname(p)}"
        self.ppt_zone.set_info(True, info)
        self._suggest_out(force=True)

    def on_ppt_clear(self):
        self.hide_banner()
        self.out_var.set("")

    def _month_changed(self):
        m = self.month_var.get()
        if m:
            nxt = int(m) + 1
            self.month_note.configure(
                text=f"→ {m}월까지 실적, " + (f"{nxt}월 값이 있으면 예상치로 (괄호)·점선 표시" if nxt <= 12 else "이후 달 없음")
                     + f", 제목·머리글은 '{m}월'")
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
        if self.excel_zone.busy or self.ppt_zone.busy:
            self.show_banner("error", "파일을 아직 읽는 중입니다. 잠시 후 다시 누르세요."); return
        if not excel or not os.path.exists(excel):
            self.show_banner("error", "① 손익 엑셀 파일을 먼저 선택하세요."); return
        if not ppt or not os.path.exists(ppt):
            self.show_banner("error", "② 기준 PPT 파일을 먼저 선택하세요."); return
        if not self.month_var.get():
            self.show_banner("error", "마감 월을 선택하세요."); return
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
