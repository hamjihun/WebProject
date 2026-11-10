# PC 셋팅 도구 - 작업 안내 (AI 도우미용)

사내 PC(Windows 10/11)를 USB 하나로 자동 셋팅하는 도구. 사용자는 한국어 사용, 화면/로그/주석 모두 한국어.
코드 구조는 `docs/ARCHITECTURE.md`, 사용자 설명은 `README.md`, 설정 키는 `docs/config.schema.json`.

## 꼭 지킬 것

- **Windows PowerShell 5.1** 기준. PowerShell 7 전용 문법 금지 (`??`, `?.`, 삼항 `a ? b : c`, `&&`, `||`, `ForEach-Object -Parallel` 등).
- `PCSetup.ps1` 은 **UTF-8 BOM + CRLF** 로 저장 (BOM 없으면 5.1 이 한글을 깨뜨림). `.editorconfig` / `.vscode/settings.json` 에 설정됨.
- 문자열 안에서 변수 바로 뒤에 한글을 붙이지 말 것: `"$m분"` 은 `$m분` 변수로 읽힘 → `"$($m)분"` 또는 `"${m}분"`.
- `config.json` 에 주석 금지 (ConvertFrom-Json 이 실패함).
- 작업 코드는 `$Worker` 스크립트블록 안(별도 런스페이스) → 화면 컨트롤에 직접 접근 금지, `$Sync` 로만 주고받음
  (`Write-Log`, `Set-TaskState`, `Set-ProgState`, `Set-Status`, `Add-Notice`, `Show-Guide`).
- WinForms 이벤트 스크립트블록은 클로저가 아님 → 함수 밖에서 쓸 값은 `$script:` 변수로.
- 직원이 나중에 바꿀 수 있어야 하는 설정은 잠그지 말 것 (브라우저는 권장값 / 개인 설정).
- 실제 PC 설정을 바꾸는 도구이므로 테스트는 테스트용 PC 에서만.

## 자주 하는 작업

- **설치 프로그램 추가**: `config.json` 의 `programs` 에 항목 추가 (`find`, `args`, `installed`, 필요하면 `auto` 단계). 코드 수정 불필요.
- **설치 화면이 멈춤**: 로그의 `[참고] 창 '...' 버튼: ...` 줄로 실제 버튼 이름 확인 → 해당 프로그램 `auto` 의 `click`/`alsoClick` 패턴 수정.
- **새 작업 추가**: `$TaskDefs`(실행 순서) + `$TaskCategories`(화면 분류) + `$TaskNotes`(진행 순서 창 설명) + Worker 함수 + 메인 루프 `switch ($step.Id)`.
- **마무리 체크리스트**: `config.json` 의 `finishChecklist` (화면에서 [항목 편집] 으로도 수정 가능).

## 검사

- VS Code: `Ctrl+Shift+P` → `Tasks: Run Task` → **문법 검사 (PCSetup.ps1)** / **config.json 형식 검사** / **코드 분석 (PSScriptAnalyzer)**.
- 명령줄:
  ```powershell
  $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\PCSetup.ps1",[ref]$null,[ref]$e); $e
  ```
- 배포: `pc-setup` 폴더의 `Setup.bat`, `PCSetup.ps1`, `config.json` 을 USB 에 복사.
