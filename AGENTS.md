# 작업 규칙

- 변경을 완료하고 검증한 뒤 관련 파일만 자동으로 커밋한다.
- 커밋한 현재 브랜치를 원격 저장소에 자동으로 push한다.
- 관련 없는 변경이나 빈 커밋은 만들지 않는다.

## Xcode Cloud 빌드 번호

- 날짜 기반 빌드 번호는 `YYMMDDNN` 형식을 사용한다. 예: 2026-08-09의 첫 빌드는 `26080901`이다.
- Xcode Cloud로 TestFlight에 배포할 때는 프로젝트의 `CURRENT_PROJECT_VERSION`만 변경해도 TestFlight 빌드 번호가 바뀌지 않는다. Xcode Cloud가 App Store Connect의 독립적인 다음 빌드 번호를 사용하기 때문이다.
- 날짜 기반 번호로 배포하기 전 App Store Connect의 Xcode Cloud 설정에서 `Next Build Number`를 해당 날짜의 `YYMMDD01`로 맞췄는지 확인한다. 같은 날 후속 Cloud 빌드는 `02`, `03`처럼 자동 증가하지만 날짜가 바뀌어도 `01`로 자동 초기화되지 않는다.
- App Store Connect 설정 변경이나 새 Cloud 빌드 실행은 사용자의 명시적 승인 없이 수행하지 않는다.
- 빌드 번호만 별도 커밋해 먼저 push하지 않는다. 배포할 변경을 모두 포함한 최종 커밋을 준비한 뒤 Cloud 번호를 확인하고 한 번에 push하여, 후속 push가 진행 중 빌드를 자동 취소하지 않게 한다.
- 2026-08-09 확인 사례: 소스는 `26080901`이었지만 Cloud는 기존 수열을 이어 `26072704`를 할당했고, 다음 push로 이 빌드를 자동 취소한 뒤 최신 커밋을 `26072705`로 성공적으로 TestFlight에 배포했다.
