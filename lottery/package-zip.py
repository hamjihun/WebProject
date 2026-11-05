# 배포용 zip 생성: python3 package-zip.py [--config 설정파일 --out 출력경로]  ->  dist/YearEndLottery.zip
#   --config 를 주면 그 파일을 config.json 으로 넣습니다 (비밀번호가 들어가므로 저장소에 올리지 마세요)
import os, sys, zipfile
ROOT = os.path.dirname(os.path.abspath(__file__))
FILES = ['index.html', 'server.js', 'package.json', 'roster_template.xlsx', 'install.bat', 'install.ps1',
         'start.bat', 'start.sh', 'HOW_TO_USE.txt', 'README.md', 'vendor/xlsx.full.min.js']
os.makedirs(os.path.join(ROOT, 'dist'), exist_ok=True)
args = sys.argv[1:]
opt = lambda k: args[args.index(k) + 1] if k in args else None
out = opt('--out') or os.path.join(ROOT, 'dist', 'YearEndLottery.zip')
cfg = opt('--config')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in FILES:
        info = zipfile.ZipInfo.from_file(os.path.join(ROOT, f), 'YearEndLottery/' + f)
        if f.endswith('.sh'):
            info.external_attr = 0o100755 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(ROOT, f), 'rb') as fh:
            z.writestr(info, fh.read())
    if cfg:
        info = zipfile.ZipInfo('YearEndLottery/config.json'); info.compress_type = zipfile.ZIP_DEFLATED
        with open(cfg, 'rb') as fh:
            z.writestr(info, fh.read())
print(out, os.path.getsize(out) // 1024, 'KB')

# C:\ims\event 같은 웹 폴더에 그대로 넣는 단독 실행용 (서버 없음)
#   dist/event/ 폴더 + dist/event_full.zip  (index.html 한 파일에 엑셀 기능까지 포함)
import shutil
ev = os.path.join(ROOT, 'dist', 'event')
shutil.rmtree(ev, ignore_errors=True); os.makedirs(os.path.join(ev, 'vendor'))
html = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
lib = open(os.path.join(ROOT, 'vendor', 'xlsx.full.min.js'), encoding='utf-8').read()
tag = '<script src="vendor/xlsx.full.min.js"></script>'
assert html.count(tag) == 1 and '</script' not in lib
html = html.replace(tag, '<script>/* SheetJS xlsx 0.18.5 (Apache-2.0) */\n' + lib + '\n</script>')
open(os.path.join(ev, 'index.html'), 'w', encoding='utf-8').write(html)
shutil.copy(os.path.join(ROOT, 'roster_template.xlsx'), ev)
shutil.copy(os.path.join(ROOT, 'event_README.txt'), os.path.join(ev, 'README.txt'))
shutil.copy(os.path.join(ROOT, 'vendor', 'xlsx.full.min.js'), os.path.join(ev, 'vendor'))
static_out = os.path.join(ROOT, 'dist', 'event_full.zip')
with zipfile.ZipFile(static_out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dp, _, fs in os.walk(ev):
        for f in fs:
            full = os.path.join(dp, f)
            z.write(full, os.path.join('event', os.path.relpath(full, ev)).replace(os.sep, '/'))
print(static_out, os.path.getsize(static_out) // 1024, 'KB')
