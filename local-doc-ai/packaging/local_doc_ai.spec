# PyInstaller 빌드 설정:  pyinstaller packaging/local_doc_ai.spec  (local-doc-ai 폴더에서 실행)
import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

ROOT = Path(SPECPATH).parent

hiddenimports = collect_submodules("uvicorn") + ["app.main"]
if sys.platform == "win32":
    hiddenimports += ["pystray._win32"]

a = Analysis(
    [str(ROOT / "launcher_entry.py")],
    pathex=[str(ROOT)],
    datas=[(str(ROOT / "app" / "static"), "app/static")]
    + collect_data_files("pptx")
    + collect_data_files("docx"),
    hiddenimports=hiddenimports,
    excludes=["tkinter", "matplotlib", "IPython", "pytest"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="LocalDocAI",
    icon=str(ROOT / "packaging" / "app.ico"),
    console=False,  # 검은 창 없이 실행
    upx=False,
)
coll = COLLECT(exe, a.binaries, a.datas, name="LocalDocAI", upx=False)
