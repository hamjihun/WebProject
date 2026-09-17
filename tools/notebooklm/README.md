# NotebookLM 업로드용 파일 변환기

NotebookLM은 **PDF / TXT / 마크다운(.md) / 구글 문서·슬라이드 / 웹 링크 / 오디오**만
소스로 받는다. 엑셀(`.xlsx`, `.xls`)과 한글(`.hwp`, `.hwpx`)은 직접 올릴 수 없어서
미리 바꿔야 한다. `convert.py`가 폴더 하나를 통째로 받아 그 작업을 한다.

## 변환 규칙

| 원본 | 결과 | 방식 |
| --- | --- | --- |
| `.xlsx` `.xlsm` `.xltx` `.xls` | `.md` (시트별 마크다운 표) | openpyxl (`.xls`는 LibreOffice로 xlsx 경유) |
| `.csv` `.tsv` | `.md` | 파이썬 csv (UTF-8/CP949/EUC-KR 자동 판별) |
| `.hwp` | `.txt` | pyhwp → (실패 시) pyhwp+LibreOffice → LibreOffice HWP97 필터 |
| `.hwpx` | `.txt` | zip 안의 section XML 직접 파싱 |
| `.doc` `.docx` `.rtf` `.odt` | `.pdf` (또는 `--docs-to txt`) | LibreOffice |
| `.ppt` `.pptx` `.odp` | `.pdf` | LibreOffice |
| `.pdf` `.txt` `.md`, 오디오 | 그대로 복사 | - |
| 그 외(이미지 등) | 건너뜀 | 보고서에 이유가 남는다 |

표가 목적이면 PDF보다 **마크다운이 낫다.** 셀 값이 그대로 텍스트로 남아서
NotebookLM이 숫자를 훨씬 정확하게 인용한다. 그래서 엑셀은 PDF가 아니라 `.md`로 뽑는다.

## 사용법

```bash
# 폴더 하나를 통째로 (하위 폴더까지)
python3 convert.py ./원본자료 -o ./notebooklm_out

# 워드 문서를 PDF 대신 TXT로
python3 convert.py ./원본자료 -o ./notebooklm_out --docs-to txt

# 결과를 _통합.md 한 파일로도 묶기 (소스 개수 제한 대응)
python3 convert.py ./원본자료 -o ./notebooklm_out --merge

# 원본 파일명이 깨져 있을 때, 표 위에 적힌 제목을 파일명으로 쓰기
python3 convert.py ./원본자료 -o ./notebooklm_out --name-from-title
```

끝나면 출력 폴더에 `_변환결과.md`가 생긴다. 파일별로 성공/실패와 이유가 적혀 있으니
실패한 것만 따로 처리하면 된다. 종료 코드는 실패가 하나라도 있으면 `2`다.

## 설치

```bash
# 문서·슬라이드·구형 엑셀 변환용
sudo apt-get install -y libreoffice-writer libreoffice-calc libreoffice-impress
sudo apt-get install -y fonts-nanum fonts-noto-cjk   # PDF에서 한글이 깨지지 않게

# 엑셀 읽기
pip install openpyxl

# 한글(.hwp) 읽기 — 빌드 격리를 끄고 설치해야 한다
pip install "setuptools<60" wheel
pip install --no-build-isolation pyhwp
```

`.hwpx`와 `.csv`는 표준 라이브러리만으로 처리하므로 추가 설치가 필요 없다.

## 알아둘 점

- **수식**: 엑셀이 저장한 계산 결과(캐시 값)를 쓴다. 캐시 값이 없는 파일은 수식
  문자열(`=SUM(C2:C4)`)이 그대로 남는다. 그런 파일은 한 번 엑셀에서 열어 저장하면 해결된다.
- **암호가 걸린 파일**은 열리지 않는다. 보고서에 실패로 남으니 암호를 풀고 다시 돌리면 된다.
- **`.hwp`**: pyhwp는 한/글 5.0 형식(2002년 이후 대부분)을 읽는다. 표 안의 글자까지
  나오지만 표 구조는 유지되지 않는다. 서식이 중요하면 한/글에서 직접 PDF로 저장하는 편이 낫다.
- **업무용 엑셀 서식 정리**: 맨 위 빈 행, 표 위에 얹힌 제목 행, 왼쪽 빈 열은 자동으로
  걷어낸다. 제목 행은 표 위 굵은 글씨로 빼고 그 아래 행을 헤더로 잡으므로, 제목이 데이터
  한 줄로 섞여 들어가지 않는다. 내용이 없는 시트는 출력에서 빼고 머리말에 이름만 남긴다.
- **NotebookLM 소스 개수 제한**에 걸리면 `--merge`로 묶어서 올린다.
- 파일명이 겹치면 `이름(2).md` 식으로 번호를 붙여 덮어쓰지 않는다.
