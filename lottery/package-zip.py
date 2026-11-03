# 배포용 zip 생성: python3 package-zip.py  ->  dist/YearEndLottery.zip
import os, zipfile
ROOT = os.path.dirname(os.path.abspath(__file__))
FILES = ['index.html', 'server.js', 'package.json', 'roster_template.xlsx', 'install.bat', 'install.ps1',
         'start.bat', 'start.sh', 'HOW_TO_USE.txt', 'README.md', 'vendor/xlsx.full.min.js']
os.makedirs(os.path.join(ROOT, 'dist'), exist_ok=True)
out = os.path.join(ROOT, 'dist', 'YearEndLottery.zip')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in FILES:
        info = zipfile.ZipInfo.from_file(os.path.join(ROOT, f), 'YearEndLottery/' + f)
        if f.endswith('.sh'):
            info.external_attr = 0o100755 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(ROOT, f), 'rb') as fh:
            z.writestr(info, fh.read())
print(out, os.path.getsize(out) // 1024, 'KB')
