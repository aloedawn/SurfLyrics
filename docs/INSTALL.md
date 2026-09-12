# 다른 Mac에 설치하기

## 준비

- Apple Silicon Mac, macOS 27 이상
- 로그인된 Spotify 데스크톱 앱
- 같은 TestFlight 초대로 설치한 최신 SurfLyrics
- 개발 Mac에서 `bash scripts/package-helper.sh`로 만든 도우미 DMG

TestFlight에는 본 앱만 포함됩니다. 도우미는 Mac마다 최초 한 번 설치합니다. 도우미를 설치할 Mac에는 Xcode나 터미널 실행이 필요하지 않습니다.

## 도우미 설치

1. 개발 Mac에서 만든 `SurfLyrics-Helper-1.0-macOS-arm64.dmg`를 AirDrop이나 개인 파일 전송으로 옮깁니다.
2. DMG를 열고 **SurfLyrics Connection Helper.app**을 **Applications**에 드래그합니다. `~/Applications`가 아닌 `/Applications`에 설치합니다.
3. Finder에서 설치한 도우미를 처음 한 번 엽니다. Spotify가 재시작될 수 있습니다.
4. SurfLyrics를 열고 설정 → **가사 소스** → **Spotify 가사 자동 연결 (개인용)**을 켭니다.
5. Spotify 곡을 재생합니다. **Spotify 자동 연결됨**과 **가사 소스: Spotify 클라이언트**가 표시되는지 확인합니다.

자동 연결이 준비된 뒤에는 도우미를 직접 열거나 재시도 버튼을 누를 필요가 없습니다. Spotify에 동기화 가사가 없거나 연결할 수 없는 경우 LRCLIB, Musixmatch를 차례로 확인합니다.

## 최초 실행과 서명

개발 Mac에서 만든 현재 도우미는 프로젝트의 Apple 개발 인증서로 서명됩니다. **Developer ID 서명 및 Apple 공증을 마친 공개 배포판은 아닙니다.** 다른 Mac의 Gatekeeper가 실행을 막을 수 있습니다.

직접 빌드한 파일임을 확인한 후 macOS의 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기** 절차로 해당 앱만 최초 실행할 수 있습니다. 시스템 전체의 Gatekeeper를 끄거나 Spotify 앱의 서명을 변경할 필요는 없습니다. 파일이 변조되었거나 서명이 손상되었다는 메시지라면 다시 빌드하고 전송하세요.

여러 Mac에서 최초 보안 승인 없이 설치하려면 개발 Mac에서 같은 팀의 **Developer ID Application** 인증서로 서명하고, Apple의 `notarytool`로 공증한 후 `stapler`로 공증 결과를 첨부한 설치 파일을 배포해야 합니다. 패키징 스크립트는 인증서 생성·공증 업로드·Release 게시를 대신 실행하지 않습니다.

Apple 안내: [Mac에서 앱 안전하게 열기](https://support.apple.com/102445), [macOS 소프트웨어 공증](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## 연결되지 않을 때

| 표시 또는 상황 | 확인할 항목 |
| --- | --- |
| 도우미 설치 필요 | `/Applications` 설치 위치, 번들 서명, 본 앱과 같은 개발 팀인지 확인 |
| Spotify 연결 실패 | Spotify 로그인 상태를 확인하고 **현재 곡 가사 다시 조회** 실행 |
| LRCLIB 또는 Musixmatch 표시 | Spotify 클라이언트가 해당 곡의 동기화 가사를 반환하지 않았거나 준비에 실패한 상태 |
| Spotify 업데이트 후 계속 실패 | 내부 모듈 변경일 수 있으므로 SurfLyrics 업데이트 필요 |
| 재생 정보가 없음 | 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 SurfLyrics의 Spotify 접근 확인 |

## 제거

SurfLyrics에서 자동 연결을 끈 뒤 Spotify를 완전히 종료합니다. `/Applications/SurfLyrics Connection Helper.app`을 휴지통으로 옮기면 도우미가 제거됩니다. 별도 데몬이나 로그인 항목은 설치되지 않습니다.
