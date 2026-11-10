이 프로젝트의 작업 규칙은 `CLAUDE.md`, 코드 구조는 `docs/ARCHITECTURE.md`, 설정 키는 `docs/config.schema.json` 을 참고하세요.
핵심: Windows PowerShell 5.1 문법만 사용, PCSetup.ps1 은 UTF-8 BOM + CRLF, 화면/로그/주석은 한국어,
작업 코드는 런스페이스($Worker) 안에서 $Sync 로만 화면과 통신, config.json 에 주석 금지.
