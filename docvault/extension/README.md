# DocVault 웹 첨부 보호 확장 (브라우저 확장)

웹사이트에 파일을 첨부할 때 **반출(승인)받은 파일만** 올릴 수 있게 하고,
관리자 웹에서 지정한 **예외 사이트**(그룹웨어·협력사·은행 등)에서는 자유롭게
올릴 수 있게 하는 Chrome/Edge/Whale(크로미움) 확장입니다.

## 동작

- 파일 선택/드래그를 가로채 백그라운드(`background.js`)에 물어봅니다.
- 백그라운드는 PC의 DocVault 에이전트가 여는 로컬 서비스(`127.0.0.1`,
  `cmd/agent/upload_oracle.go`)에 정책과 허용 여부를 묻습니다.
  - 기능이 꺼져 있거나 **예외 사이트** → 그대로 통과
  - 그 외 사이트 → 파일의 SHA-256이 **반출 승인 목록**에 있으면 통과, 아니면
    첨부 취소 + 안내
- 관리자 웹: 설정 → *웹 첨부관리*에서 켜기/끄기와 예외 사이트를 정합니다.

## 배포

서버가 서명된 `.crx`를 호스팅하고(`/ext/docvault.crx`, `/ext/update.xml`),
직원 PC 설치 시 Chrome/Edge/Whale의 `ExtensionInstallForcelist` 정책으로
자동 설치됩니다(인터넷 없이 사내망만으로). Chrome 웹스토어를 쓰지 않습니다.

## 서명 키

확장 ID는 `manifest.json`의 `key`(공개키)로 고정되며, 같은 키쌍의 개인키
`tools/crxpack/docvault-ext.key.pem`으로 `.crx`를 서명합니다. 이 키는 **사내
전용**이며 공개 스토어에 올리지 않습니다. 빌드는 `scripts/build-release.sh`가
`tools/crxpack`로 자동 수행합니다.

## 개발 중 수동 로드(테스트)

크롬 `chrome://extensions` → 개발자 모드 → "압축해제된 확장 프로그램을 로드"
→ 이 폴더 선택. (실배포는 위 자동 설치 사용)
