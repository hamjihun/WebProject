# 사내 문서 AI

NotebookLM처럼 **내가 올린 문서만 근거로** 업무 질문에 답하는 프로그램입니다.
문서, 검색, AI 답변 생성이 모두 **이 PC 안에서만** 처리되어 사내 문서가 외부로 나가지 않습니다.

- 지원 형식: **PDF, 엑셀(xlsx·xlsm·xls·csv), PPT(pptx)**, 워드(docx), 한글(hwp·hwpx), txt·md
- 답변마다 출처 표시: `매출.xlsx · 시트 '2분기' 12~30행`, `전략.pptx · 슬라이드 5`, `보고서.pdf · p.12`
- 출처 번호를 누르면 근거가 된 원문 조각을 바로 볼 수 있음
- 노트북(주제)별로 자료와 대화 기록을 따로 관리
- 인터넷 없이 동작 (설치할 때만 인터넷 필요)

## 권장 사양

| PC 메모리 | 자동으로 선택되는 모델 | 체감 |
|---|---|---|
| 16GB 이상 | `qwen3:4b` | 답변 품질이 적당하고 속도도 쓸 만함 |
| 8~12GB | `qwen3:1.7b` | 빠르지만 복잡한 질문에는 약함 |

별도 그래픽카드는 없어도 되지만, 있으면 더 빨라집니다. 쓸 때는 전원 어댑터를 연결하는 것이 좋습니다.

## 설치 (Windows)

1. 설치 파일 **`LocalDocAI-Setup-x.x.x.exe`**를 받습니다.
   - GitHub 저장소 → **Releases → local-doc-ai-latest**에서 받을 수 있습니다.
2. 받은 파일을 실행하면 설치 마법사가 열립니다. **관리자 권한은 필요 없습니다.**

   | 단계 | 화면 | 할 일 |
   |---|---|---|
   | 1 | 환영 | [다음] |
   | 2 | **AI 엔진(Ollama) 설치 확인** | Ollama가 없으면 **[Ollama 내려받기]**로 받아 설치합니다. 설치가 끝나면 자동으로 확인되고 [다음]이 켜집니다 |
   | 3 | 설치 위치 | 기본값 그대로 [다음] |
   | 4 | 추가 작업 | 바탕화면 바로가기 선택 → [다음] |
   | 5 | 설치 | [설치] |
   | 6 | 완료 | "사내 문서 AI 실행하기"를 체크한 채 [마침] |

3. 처음 실행하면 **처음 설정** 창이 뜹니다. **[모델 받기 시작]**을 누르면 PC 메모리에 맞는 AI 모델(약 2~4GB)을 받습니다. 진행률이 표시되고, 처음 한 번만 받으면 됩니다.
4. 이후에는 바탕화면이나 시작 메뉴의 **사내 문서 AI**를 실행하면 됩니다.

> 프로그램은 작업 표시줄 오른쪽 아래(알림 영역)에 파란 아이콘으로 떠 있습니다.
> 아이콘을 **더블클릭**하면 화면이 다시 열리고, **우클릭 → 종료**로 끌 수 있습니다.

- 삭제: **설정 → 앱 → 사내 문서 AI → 제거**. 제거할 때 올린 문서와 대화 기록도 지울지 묻습니다.
- 데이터 저장 위치: `%LOCALAPPDATA%\LocalDocAI\data` (올린 파일, 검색 데이터, 대화 기록)
- 문제가 생기면 `%LOCALAPPDATA%\LocalDocAI\logs\app.log`를 확인하세요.

## 사용법

1. 왼쪽 **파일 올리기**에 문서를 끌어다 놓습니다. 분석이 끝나면 체크박스가 켜집니다.
2. 질문에 사용할 자료만 체크한 상태로 아래 입력창에 질문합니다.
3. 답변의 `1`, `2` 같은 번호나 아래 출처 칩을 누르면 원문 조각이 오른쪽에 나옵니다.
4. 주제가 다른 자료는 **+ 새 노트북**으로 나눠 두면 검색이 더 정확해집니다.

### 잘 쓰는 요령

- **원본 파일을 그대로 올리세요.** 엑셀은 머리글과 값을 짝지어(`품목: 볼트 | 금액: 1,250,000`), PPT는 슬라이드별로(표, 차트 값, 발표자 노트 포함) 읽습니다. 메모장 파일로 바꾸면 출처 위치 정보가 사라집니다.
- 질문에 **거래처명, 품목명, 날짜 같은 구체적인 단어**를 넣으면 더 잘 찾습니다.
- 답변이 느리면 **⚙ 설정**에서 '참고할 자료 조각 수'를 3~4로 줄이세요.
- 엉뚱한 자료를 근거로 쓰면 '관련도 최소 점수'를 0.4 정도로 올리세요.

### 한계

- **스캔한 이미지 PDF**나 PPT 속 **그림에 들어간 글자**는 읽지 못합니다 (OCR 미지원).
- 예전 형식 `.ppt`, `.doc`는 PowerPoint/Word에서 `.pptx`, `.docx`로 다시 저장한 뒤 올려주세요.
- 엑셀 수식은 **마지막으로 저장될 때 계산된 값**을 읽습니다.
- 암호가 걸린 파일, 배포용 한글 문서는 읽을 수 없습니다.
- "전체 합계", "평균" 같은 **엑셀 전체 계산**은 AI가 일부 행만 보고 답하므로 정확하지 않을 수 있습니다. 숫자는 출처 원문으로 꼭 확인하세요.

## 보안

- 프로그램은 `127.0.0.1`(이 PC)에서만 열리고, 같은 네트워크의 다른 PC에서는 접속할 수 없습니다.
- 다른 웹사이트가 이 프로그램에 요청을 보내지 못하도록 막아 두었습니다 (Host/Origin 검사).
- 화면에 외부 글꼴, 외부 스크립트, 분석 도구를 쓰지 않습니다.
- 올린 파일, 검색 데이터, 대화 기록은 모두 `%LOCALAPPDATA%\LocalDocAI\data`에만 저장됩니다.
  PC를 반납하거나 초기화할 때는 `data` 폴더를 지우면 됩니다.

## 인터넷이 막힌 PC에 설치하기

인터넷이 되는 PC에서 준비물을 받아 USB 등으로 옮깁니다.

1. `LocalDocAI-Setup-x.x.x.exe`와 `OllamaSetup.exe`(https://ollama.com/download)를 옮겨 차례로 설치합니다.
2. 인터넷이 되는 PC에서 모델을 받습니다: `ollama pull qwen3:4b`, `ollama pull bge-m3` (메모리 8~12GB PC는 `qwen3:1.7b`)
3. 그 PC의 `%USERPROFILE%\.ollama\models` 폴더를 통째로 대상 PC의 같은 위치에 복사합니다.

## 설정 값 (고급)

화면의 ⚙ 설정 또는 `%LOCALAPPDATA%\LocalDocAI\data\settings.json`에서 바꿀 수 있습니다.

| 항목 | 기본값 | 설명 |
|---|---|---|
| `chat_model` | `qwen3:4b` | 답변 모델. `ollama pull`로 받은 다른 모델도 사용 가능 |
| `embed_model` | `bge-m3` | 검색용 모델. 바꾸면 기존 문서를 다시 올려야 함 |
| `top_k` | 5 | 질문 하나에 참고할 문서 조각 수 |
| `num_ctx` | 6144 | AI가 한 번에 읽는 분량(토큰). 메모리 부족 시 4096 |
| `min_score` | 0.3 | 이보다 관련도가 낮은 조각은 근거로 쓰지 않음 |
| `chunk_chars` | 700 | 문서 조각 하나의 최대 글자 수 |

포트를 바꾸려면 환경 변수 `DOCAI_PORT`를 설정합니다 (기본 8765).

## 개발

```bash
python -m venv .venv
.venv/bin/pip install -r requirements-dev.txt   # Windows: .venv\Scripts\pip
.venv/bin/python -m pytest                       # 테스트 (Ollama 없이 동작)
.venv/bin/python -m app                          # 실행
```

### 설치 파일 빌드

`local-doc-ai/` 아래 파일을 고쳐서 GitHub에 올리면, GitHub Actions(`.github/workflows/local-doc-ai-windows.yml`)가
Windows에서 자동으로 다음을 수행합니다.

1. 테스트 실행
2. PyInstaller로 `LocalDocAI.exe` 생성 (`packaging/local_doc_ai.spec`), 빌드된 exe 자체 점검(`--selftest`)
3. Inno Setup으로 설치 마법사 `LocalDocAI-Setup-x.x.x.exe` 생성 (`packaging/installer.iss`)
4. Actions 결과물과 Releases의 `local-doc-ai-latest`에 업로드

직접 빌드하려면 (Windows):

```bat
pip install -r requirements-build.txt
pyinstaller --noconfirm packaging\local_doc_ai.spec
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" packaging\installer.iss
```

구조:

```
packaging/          exe·설치 마법사 빌드 설정 (PyInstaller, Inno Setup)
launcher_entry.py   exe 시작 파일
app/
  launcher.py       실행기: 중복 실행 방지, Ollama 자동 시작, 트레이 아이콘
  main.py           웹 서버(API), 이 PC에서만 접속 허용
  parsers.py        파일 형식별 텍스트 추출 (엑셀 행 묶음, 슬라이드, PDF 페이지 등)
  chunker.py        긴 글을 검색 단위 조각으로 나누기
  ollama_client.py  로컬 Ollama 호출 (임베딩, 답변 생성)
  system.py         PC 메모리 확인, Ollama 찾기/실행
  rag.py            문서 등록 작업, 검색(벡터+키워드), 프롬프트, 답변
  db.py             SQLite 저장소
  static/           화면 (외부 라이브러리 없음)
```
