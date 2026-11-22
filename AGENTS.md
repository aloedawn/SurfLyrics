# 작업 규칙

- 이 저장소의 구현 변경에는 관련 파일만 검증 후 자동 커밋하는 상시 승인이 적용된다. 검토·점검만 요청한 경우에는 편집·커밋하지 않는다.
- 이 저장소의 검증된 관련 커밋에는 현재 브랜치의 설정된 upstream으로 일반 push하는 상시 승인이 적용된다. 먼저 브랜치·원격·작성자·staged 경로를 확인하며 강제 push·배포 설정 변경·별도 릴리스 실행은 포함하지 않는다. 사용자의 현재 제한 지시를 우선한다.
- 관련 없는 변경이나 빈 커밋은 만들지 않는다.

## 배포와 릴리스 (GitHub / Homebrew)

- 릴리스 패키징과 Cask 생성 절차는 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)를 참조한다.
- 공개 GitHub Release 게시, 태그 push, Homebrew Tap(`aloedawn/homebrew-tap`) 업데이트, 서명·공증 설정 변경은 사용자의 명시적 승인 없이 수행하지 않는다.
- 릴리스 전 `scripts/spotify-client-bridge.test.mjs`, 셸 문법 검사, `xcodebuild test`가 모두 통과한 단일 검증 커밋을 `main`에 push한 뒤 패키징·게시한다.
