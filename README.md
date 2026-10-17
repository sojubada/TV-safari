# tvOS Browser — 미서명 IPA 빌드

Apple TV(tvOS)용 웹 브라우저 앱을 **최신 Xcode / tvOS SDK로 새로 빌드**해서 IPA로 내려받을 수 있게 만든 저장소입니다.
빌드는 GitHub Actions의 macOS 러너에서 돌아가고, 결과물인 `.ipa`가 Releases에 자동으로 올라갑니다.

## 출처와 저작권

- 앱 소스: [jvanakker/tvOSBrowser](https://github.com/jvanakker/tvOSBrowser) — Objective-C, tvOS 전용
- 참고: [LisaGuide/tvOS_Safari](https://github.com/LisaGuide/tvOS_Safari) 는 이 앱을 재배포하던 저장소로, 소스코드는 포함하고 있지 않습니다

> **주의:** 원본 저장소에는 라이선스 파일이 없습니다. 라이선스가 명시되지 않은 코드는 기본적으로 저작권자의 모든 권리가 유보된 상태이므로,
> 이 저장소와 릴리스 바이너리는 **개인 사용 목적**으로만 두는 것이 안전합니다. 공개 재배포가 필요하면 원저작자에게 먼저 허락을 받으시기 바랍니다.

## 빌드 방법

Actions 탭 → **Build unsigned tvOS IPA** → **Run workflow**.

| 입력값 | 기본값 | 설명 |
|---|---|---|
| `deployment_target` | `15.6` | tvOS 최소 배포 버전. Xcode 26.x는 15 이상만 허용합니다 |
| `release_tag` | (비움) | 비워 두면 `build-<실행번호>` 태그로 릴리스를 만듭니다 |

`v` 로 시작하는 태그(`v1.0` 등)를 푸시해도 같은 빌드가 돌아갑니다.

워크플로가 하는 일:

1. 러너에 설치된 Xcode 중 가장 최신 버전을 선택
2. `-sdk appletvos` 로 arm64 기기용 Release 빌드 (서명 완전히 비활성화)
3. 남아 있는 서명 흔적(`_CodeSignature`, `embedded.mobileprovision`)을 제거
4. `Payload/Browser.app` 구조로 압축해 `.ipa` 생성
5. 아티팩트 업로드 + Releases에 게시 (SHA-256 포함)

## 설치하기 — 서명이 필요합니다

릴리스의 `.ipa`는 **미서명 상태라 그대로는 설치되지 않습니다.** 반드시 본인 인증서로 서명해야 합니다.

- **Xcode** — `Window ▸ Devices and Simulators` 로 Apple TV를 연결한 뒤 설치. 무료 Apple ID로 서명하면 7일마다 재설치가 필요합니다.
- **Sideloadly / AltStore 계열** — Apple ID 또는 개발자 인증서로 서명해 설치. Apple TV는 네트워크 페어링이 필요합니다.
- **유료 개발자 계정(연 $99)** — 1년짜리 인증서로 서명하면 재설치 주기가 길어집니다.

tvOS는 iOS와 달리 사이드로딩 경로가 제한적이고, 기기의 tvOS 버전에 따라 가능한 방법이 달라집니다.
설치 전에 본인 Apple TV의 tvOS 버전을 먼저 확인하시기 바랍니다.

## 로컬에서 직접 빌드하려면

macOS + Xcode가 있다면:

```bash
xcodebuild \
  -project _Project/Browser.xcodeproj \
  -scheme Browser \
  -configuration Release \
  -sdk appletvos \
  -derivedDataPath build \
  TVOS_DEPLOYMENT_TARGET=15.6 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  clean build
```

빌드된 `build/Build/Products/Release-appletvos/Browser.app` 을 `Payload/` 폴더에 넣고 zip으로 묶은 뒤
확장자를 `.ipa` 로 바꾸면 릴리스와 동일한 결과물이 됩니다.

Xcode에서 열어 본인 팀으로 서명해 바로 기기에 설치하는 쪽이 더 간단할 수도 있습니다.

## 알려진 제약

- 이 앱은 WebKit의 비공개 API를 일부 사용합니다. App Store 배포는 불가능하고, tvOS 버전이 올라가면 동작이 깨질 수 있습니다.
- 원본 프로젝트의 배포 타깃은 tvOS 15.6입니다. 그보다 낮은 tvOS에서는 동작하지 않습니다.
