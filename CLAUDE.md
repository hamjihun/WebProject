# 작업 지침 (토큰 절약)

이 저장소의 작업은 전부 `monitor/` 폴더(사내 서버 모니터링)입니다. 새 세션은 먼저 `monitor/HANDOFF.md` 만 읽고 시작하세요. 다른 파일은 실제로 고칠 때만, 필요한 부분만 (`grep -n`, `sed -n 시작,끝p`) 읽습니다. 전체 파일 읽기, 스크린샷 반복, 긴 탐색은 피합니다.

- 사용자는 IT 담당자이며 개발자가 아닙니다. 한국어로, 짧게, 복사해서 쓸 수 있는 명령 위주로 답합니다.
- 간단한 수정(문구, 스타일, 한 줄 로직)은 테스트 없이 커밋합니다. 화면 검증(Playwright)은 새 화면을 만들 때만 한 번.
- 커밋은 `/home/user/WebProject` 에서 `git add monitor && git commit && git push -u origin claude/server-monitoring-system-u1pues`.
- 코드 규약(인코딩, 버전 동시 수정, PowerShell 5.1 호환)은 HANDOFF.md 의 "코드 규약" 절을 따릅니다.
- 작업이 끝나면 HANDOFF.md 의 "진행 상태" 와 파일 표를 한두 줄로 갱신합니다.
