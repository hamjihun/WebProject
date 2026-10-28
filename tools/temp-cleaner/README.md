# TempCleaner

`%TEMP%` (`C:\Users\<사용자>\AppData\Local\Temp`) 폴더 내용을 주기적으로 **완전 삭제**(휴지통 거치지 않음)하는 스크립트와 작업 스케줄러 자동 등록 도구.

## 설치
1. 이 폴더(`temp-cleaner`) 전체를 PC로 복사
2. 정리할 계정(예: ADMIN)으로 로그인한 상태에서 `install.bat` 더블클릭 → UAC 창에서 **예**
3. 끝. 바로 1회 실행되고, 이후 자동 실행됨

실행 시점: **매주 수요일 11:50** (그 시각에 PC가 꺼져 있었으면 켜진 뒤 바로 실행)

옵션 (cmd에서 실행):
```
install.bat -DayOfWeek Friday -At 18:30   # 요일/시각 변경 (기본 Wednesday 11:50)
install.bat -MinAgeHours 24           # 24시간 지난 항목만 삭제 (실행 중인 설치 프로그램 보호)
```

## 확인 / 제거
- 실행 기록: `C:\Scripts\TempCleaner\cleanup.log` (확보한 용량, 남은 항목 수)
- 작업 스케줄러 → 작업 스케줄러 라이브러리 → `TempCleaner`
- 제거: `uninstall.bat`

## 참고
- 현재 실행 중인 프로그램이 잡고 있는 파일은 건너뛰고 다음 실행 때 다시 삭제 시도
- 안전장치: 대상 경로가 `...\Temp`가 아니면 아무것도 지우지 않고 종료
