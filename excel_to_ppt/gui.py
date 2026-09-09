# -*- coding: utf-8 -*-
"""
엑셀 → PPT 월간 경영실적 자동 반영 (간단한 화면 프로그램)

실행:  python gui.py   (또는 실행.bat 더블클릭)
"""
import os
import sys
import threading
import traceback
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import update_ppt  # noqa: E402


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("엑셀 → PPT 월간 경영실적 반영")
        self.geometry("760x560")
        self.resizable(True, True)

        pad = {"padx": 8, "pady": 4}
        frm = ttk.Frame(self)
        frm.pack(fill="x", **pad)

        self.excel_var = tk.StringVar()
        self.ppt_var = tk.StringVar()
        self.out_var = tk.StringVar()
        self.month_var = tk.StringVar()

        self._row(frm, 0, "손익 엑셀 파일", self.excel_var, self.pick_excel)
        self._row(frm, 1, "기준 PPT (지난달 파일)", self.ppt_var, self.pick_ppt)
        self._row(frm, 2, "저장할 PPT 파일", self.out_var, self.pick_out)

        ttk.Label(frm, text="당월").grid(row=3, column=0, sticky="w", **pad)
        mf = ttk.Frame(frm)
        mf.grid(row=3, column=1, sticky="w", **pad)
        self.month_box = ttk.Combobox(mf, textvariable=self.month_var, width=6, state="readonly",
                                      values=[str(i) for i in range(1, 13)])
        self.month_box.pack(side="left")
        ttk.Label(mf, text="월   (엑셀을 고르면 'N월 누적' 머리글에서 자동으로 채워집니다)").pack(side="left", padx=6)

        frm.columnconfigure(1, weight=1)

        self.run_btn = ttk.Button(self, text="PPT 만들기", command=self.run)
        self.run_btn.pack(pady=6)

        self.log = tk.Text(self, height=18, wrap="word")
        self.log.pack(fill="both", expand=True, padx=8, pady=4)
        self.log.tag_config("warn", foreground="#b00000")

    def _row(self, frm, r, label, var, cmd):
        ttk.Label(frm, text=label).grid(row=r, column=0, sticky="w", padx=8, pady=4)
        ttk.Entry(frm, textvariable=var).grid(row=r, column=1, sticky="ew", padx=8, pady=4)
        ttk.Button(frm, text="찾아보기", command=cmd).grid(row=r, column=2, padx=8, pady=4)

    # ---- 파일 선택 -------------------------------------------------------
    def pick_excel(self):
        p = filedialog.askopenfilename(title="손익 엑셀 파일", filetypes=[("Excel", "*.xlsx *.xlsm"), ("모든 파일", "*.*")])
        if not p:
            return
        self.excel_var.set(p)
        try:
            xl = update_ppt.ExcelReader(p, log=update_ppt.Log(lambda m: None))
            for name in xl.wb_val.sheetnames:
                m = xl.find_month_header(name)
                if m:
                    self.month_var.set(str(m))
                    self.write(f"엑셀 '{name}' 시트에서 '{m}월 누적' 머리글을 찾아 당월을 {m}월로 설정했습니다.\n")
                    break
            else:
                self.write("엑셀에서 'N월 누적' 머리글을 찾지 못했습니다. 당월을 직접 선택하세요.\n", "warn")
        except Exception as e:  # noqa: BLE001
            self.write(f"엑셀을 읽지 못했습니다: {e}\n", "warn")
        self._suggest_out()

    def pick_ppt(self):
        p = filedialog.askopenfilename(title="기준 PPT 파일", filetypes=[("PowerPoint", "*.pptx"), ("모든 파일", "*.*")])
        if p:
            self.ppt_var.set(p)
            self._suggest_out()

    def pick_out(self):
        p = filedialog.asksaveasfilename(title="저장할 PPT 파일", defaultextension=".pptx",
                                         filetypes=[("PowerPoint", "*.pptx")])
        if p:
            self.out_var.set(p)

    def _suggest_out(self):
        if self.out_var.get() or not self.ppt_var.get():
            return
        base, _ = os.path.splitext(self.ppt_var.get())
        import re
        base = re.sub(r"_\d{1,2}월$", "", base)
        m = self.month_var.get() or "N"
        self.out_var.set(f"{base}_{m}월.pptx")

    # ---- 실행 ------------------------------------------------------------
    def write(self, msg, tag=None):
        self.log.insert("end", msg, tag)
        self.log.see("end")
        self.update_idletasks()

    def run(self):
        excel, ppt, out = self.excel_var.get(), self.ppt_var.get(), self.out_var.get()
        if not excel or not os.path.exists(excel):
            messagebox.showerror("오류", "손익 엑셀 파일을 선택하세요.")
            return
        if not ppt or not os.path.exists(ppt):
            messagebox.showerror("오류", "기준 PPT 파일을 선택하세요.")
            return
        if not self.month_var.get():
            messagebox.showerror("오류", "당월을 선택하세요.")
            return
        month = int(self.month_var.get())
        if not out:
            out = None
        self.log.delete("1.0", "end")
        self.run_btn.config(state="disabled")

        def printer(msg):
            self.after(0, lambda: self.write(msg + "\n", "warn" if msg.startswith("[경고]") else None))

        def work():
            try:
                result = update_ppt.run(excel, ppt, out, month, printer=printer)
                self.after(0, lambda: messagebox.showinfo("완료", f"저장했습니다:\n{result}\n\n로그의 경고와 직접 입력 항목을 확인하세요."))
            except Exception as e:  # noqa: BLE001
                err = traceback.format_exc()
                self.after(0, lambda: (self.write(err, "warn"), messagebox.showerror("오류", str(e))))
            finally:
                self.after(0, lambda: self.run_btn.config(state="normal"))

        threading.Thread(target=work, daemon=True).start()


if __name__ == "__main__":
    App().mainloop()
