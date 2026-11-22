# 설치 및 사용 안내

## 요구 사항

- Apple Silicon Mac, macOS 27 이상
- Spotify 데스크톱 앱(로그인 상태) 또는 Apple Music

## Homebrew 설치

```sh
brew install --cask aloedawn/tap/surflyrics
```

업데이트 및 제거:

```sh
brew upgrade --cask surflyrics
brew uninstall --cask surflyrics
```

설정 파일까지 완전히 지우려면 `--zap` 옵션을 추가합니다:

```sh
brew uninstall --cask --zap surflyrics
```

## GitHub Releases 수동 설치

1. [GitHub Releases](https://github.com/aloedawn/SurfLyrics/releases)에서 `SurfLyrics-<버전>-macOS-arm64.dmg`를 다운로드합니다.
2. DMG를 열고 **SurfLyrics.app**을 **Applications** 폴더로 옮깁니다.
3. 앱을 실행한 뒤 Spotify 또는 Apple Music 자동화 접근 권한 요청이 뜨면 **허용**을 선택합니다.

## 자동 연결 동작

SurfLyrics는 별도의 연결 도우미 앱 없이 본 앱이 직접 Spotify 로컬 연결(`127.0.0.1:43827`)을 확인·준비합니다.

- 설정 → **가사 소스** → **Spotify 가사 자동 연결 (개인용)**을 켜면 Spotify가 일반 모드로 실행 중일 때 한 번 재시작해 연결을 엽니다.
- 재연결 후에도 같은 곡이면 재생 위치와 재생·일시정지 상태를 복구합니다.
- Spotify에 동기화 가사가 없거나 연결할 수 없는 경우 LRCLIB, Musixmatch를 순서대로 확인합니다.

## Gatekeeper 확인이 뜰 때

Developer ID 서명 및 Apple 공증이 완료된 정식 릴리스는 별도 승인 없이 실행됩니다. 직접 로컬 개발 인증서로 빌드한 바이너리를 다른 Mac에서 실행하는 경우에는 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**로 최초 1회 승인해야 합니다.

## 문제 해결

| 표시 또는 상황 | 확인할 항목 |
| --- | --- |
| `⚠ 음악 앱 접근 권한 필요` | 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 SurfLyrics의 Spotify / Apple Music 접근 허용 |
| Spotify 연결 실패 | Spotify 로그인 상태를 확인한 뒤 설정에서 **현재 곡 가사 다시 조회** 클릭 |
| LRCLIB 또는 Musixmatch 표시 | Spotify 클라이언트가 해당 곡의 동기화 가사를 제공하지 않았거나 연결 재시도 대기 중 |
| Spotify 업데이트 후 계속 실패 | Spotify 내부 JS 모듈 변경일 수 있으므로 SurfLyrics 최신 버전으로 업데이트 |
| 재생 정보가 표시되지 않음 | Spotify나 Apple Music이 실행 중인지 확인 |
