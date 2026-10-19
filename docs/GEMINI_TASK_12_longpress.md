# 작업 12 — 링크 길게 눌러 메뉴 (Gemini 전달용)

> **사용법**: `=== 여기부터 복사 ===` 아래를 Gemini에 붙여넣고, 제가 그때 만들어 드리는 **소스 번들 파일을 함께 첨부**하십시오.
>
> **반드시 마지막에 하십시오.** 이 작업은 최근에 안정화한 입력 판정(탭 / 클릭 / 더블클릭)을 직접 건드립니다. 다른 기능이 모두 자리를 잡은 뒤에 단독으로 올려야 문제가 생겼을 때 원인을 바로 좁힐 수 있습니다.
> 작업 10(즐겨찾기 저장소)이 끝나 있어야 합니다.

---

=== 여기부터 복사 ===

# 작업 의뢰: tvOS 브라우저 — 링크 길게 눌러 메뉴

당신은 tvOS 네이티브 앱을 수정하는 Objective-C 개발자입니다. 첨부한 소스 번들이 **현재 저장소의 실제 원본**입니다. 그 내용만을 사실로 삼고, 존재하지 않는 API나 파일을 지어내지 마십시오.

## 공통 제약 — 반드시 지킬 것

1. **Objective-C(ARC)만.** Swift / SwiftUI 금지.
2. **서드파티 라이브러리, CocoaPods, SPM 금지.**
3. **`project.pbxproj`, `Info.plist`, 워크플로 YAML, 스토리보드를 수정하지 마십시오.** 새 소스 파일은 만들어도 되고, 만들었다면 목록을 결과 맨 앞에 적으십시오.
4. **새 프레임워크 링크 금지.** Foundation과 UIKit만 링크되어 있습니다.
5. **`UIPasteboard`는 tvOS에 존재하지 않습니다.** 그래서 이 메뉴에 "URL 복사"를 넣을 수 없습니다. 넣지 마십시오.
6. **기존 동작 회귀 금지.** 아래 입력 규칙은 이 작업에서 가장 중요한 제약입니다.
7. 새 기능은 `BrowserPreferencesStore`에 설정을 추가하고 고급 메뉴에 토글을 넣으십시오.
8. 코드 스타일은 기존대로.

## 지금의 입력 규칙 — 하나도 깨뜨리지 마십시오

| 조작 | 동작 |
|---|---|
| 터치면 **가볍게 톡**(250ms 미만, 이동 20pt 미만, Select 프레스 없음) | 커서 아래 요소를 **현재 탭**에서 즉시 활성화 |
| 터치면 **물리 클릭 1회** | 0.3초 더블클릭 대기 후, 링크면 **새 탭**, 아니면 일반 클릭 |
| 터치면 **물리 클릭 2회** | 커서 / 스크롤 모드 토글 |
| Menu 버튼 | 뒤로 가기, 루트에서 종료 확인 |
| PlayPause 1회 / 2회 | 퀵 메뉴 / 고급 메뉴 |

`BrowserRemoteInputController`에는 중복 실행을 막는 장치가 이미 있습니다. Select 프레스가 감지되면 `noteSelectPressActivity`가 플래그와 타임스탬프를 남기고, 터치 종료 시 탭 판정이 이를 확인합니다. **이 장치를 제거하거나 우회하지 마십시오.**

## 이 작업의 내용

링크 위에서 Select 버튼을 **길게 누르면** 메뉴가 떠서, 어디서 열지 고르거나 즐겨찾기에 넣을 수 있게 합니다.

### 요구사항

**1. 길게 누르기 판정 — 0.6초**

`BrowserRemoteInputController`에서 처리하십시오.

- `handlePressesBegan:`에서 `UIPressTypeSelect`를 받으면 0.6초 타이머를 걸고 `selectLongPressTriggered = NO`로 둡니다.
- `handlePressesEnded:`와 `handlePressesCancelled:`에서는 **항상 타이머를 해제**하십시오. 타이머가 살아남아 나중에 엉뚱하게 발화하면 안 됩니다.
- 커서 모드가 아니거나, 탭 오버뷰·상단바 포커스·모달이 떠 있으면 타이머를 걸지 마십시오.

**2. 타이머가 발화하면**

- 호스트에 "커서 아래 링크 정보를 달라"고 요청합니다. `BrowserDOMInteractionService`의 `linkInfoAtDOMPoint:webView:`가 `{href, target}`을 돌려줍니다. `BrowserRemoteInputController`는 DOM 서비스를 직접 들고 있지 않으므로, **호스트 프로토콜(`BrowserRemoteInputControllerHost`)에 메서드를 추가하고 `ViewController`에서 구현**하십시오. 기존 구조를 따르십시오.
- **링크가 없으면 아무것도 하지 마십시오.** `selectLongPressTriggered`를 NO로 둔 채 끝내서, 손을 뗐을 때 평소처럼 클릭이 동작하게 하십시오. 링크가 아닌 곳에서 길게 눌렀다고 엉뚱한 메뉴를 띄우지 마십시오.
- 링크가 있으면 `selectLongPressTriggered = YES`로 두고 메뉴를 띄웁니다.

**3. 프레스 종료 처리 — 중복 실행 방지의 핵심**

`handlePressesEnded:`에서 Select를 처리할 때, `selectLongPressTriggered`가 YES면 **플래그만 NO로 되돌리고 `YES`를 반환**해 그대로 끝내십시오. 기존의 클릭·더블클릭 경로(`handleSelectPressEnded`)로 넘어가면 안 됩니다. 메뉴를 띄운 뒤 링크가 새 탭에서 또 열리는 일이 생깁니다.

`handleGlobalSelectPressEndedNotification`으로 들어오는 경로에도 같은 조건을 적용하십시오. 이쪽을 빠뜨리면 알림 경로로 클릭이 한 번 더 실행됩니다.

**4. 메뉴 구성**

`UIAlertController`(Alert 스타일)로 띄우십시오.

- 제목: 링크의 텍스트 또는 `title` 속성. 없으면 `Link`
- 메시지: 링크 URL. **80자를 넘으면 뒤를 잘라 `…`** 를 붙이십시오. 긴 URL이 Alert를 화면 밖까지 늘립니다
- 항목:
  1. `Open in New Tab` — `browserPageActionCoordinatorCreateNewTabWithRequest:`와 같은 경로로 새 탭에서 엽니다. 탭이 5개면 기존 한도 알림이 뜨고 끝납니다
  2. `Open in This Tab` — 현재 탭에서 이동
  3. `Add to Favorites` / `Remove from Favorites` — `BrowserFavoritesStore`로 링크 URL의 즐겨찾기 상태를 보고 제목을 정합니다. 제목은 링크 텍스트를 쓰십시오
  4. `Cancel`
- **`Copy URL`을 넣지 마십시오.** tvOS에는 클립보드가 없습니다

**5. 열 수 없는 링크는 거르기**

`javascript:`, `mailto:`, `tel:` 로 시작하거나 `href`가 비었으면 메뉴를 띄우지 마십시오(2번의 "링크 없음"과 같게 처리).

**6. 설정**

- `BrowserPreferencesStore`에 `linkLongPressMenuEnabled` 추가, 기본값 **YES**.
- 고급 메뉴 `Scrolling & Input` 섹션에 토글 추가(`Link Long-Press Menu: On` / `Off`).
- 꺼져 있으면 타이머 자체를 걸지 마십시오.

## 결과물 제출 형식

1. **수정한 파일은 전체 내용을 출력하십시오.** 생략 표기 금지.
2. 각 파일 앞에 `FILE: _Project/Browser/<파일명>` 한 줄, 다음 줄부터 ```objc 블록.
3. 맨 앞에 세 가지 요약 — 새로 추가한 파일 / 수정한 기존 파일 / 영향받는 기존 동작.
4. 맨 뒤에 기기 테스트 절차.
5. 자가 점검 — **호스트 프로토콜에 메서드를 추가했다면 선언과 `ViewController` 구현을 모두 고쳤는가** / 타이머를 거는 모든 경로에 해제 경로가 있는가 / `selectLongPressTriggered`를 되돌리지 않고 빠져나가는 분기가 없는가 / `dealloc`에서 타이머를 해제하는가 / 블록 순환 참조.

## 기기 테스트 절차 (아래를 포함해 보강할 것)

**새 기능**

1. 링크 위에서 Select를 0.6초 이상 길게 누르기 → 메뉴가 뜨는가
2. `Open in New Tab` → 새 탭에서 열리는가
3. `Open in This Tab` → 현재 탭에서 열리는가
4. `Add to Favorites` → 추가되고, 같은 링크를 다시 길게 누르면 `Remove from Favorites`로 보이는가
5. `Cancel` → 아무 일도 일어나지 않는가
6. 링크가 **아닌** 곳에서 길게 누르기 → 메뉴가 뜨지 않고, 손을 떼면 평소대로 클릭되는가
7. 매우 긴 URL의 링크 → Alert가 화면을 벗어나지 않는가
8. 토글을 끄면 길게 눌러도 메뉴가 뜨지 않는가

**기존 동작 회귀 — 이쪽을 더 꼼꼼히 보십시오**

9. 링크를 **가볍게 톡** → 현재 탭에서 열리는가 (지연 없이)
10. 링크를 **짧게 물리 클릭** → 새 탭에서 열리는가
11. 길게 눌러 메뉴를 띄운 뒤 항목을 고르면 → **링크가 두 번 열리지 않는가** (새 탭이 두 개 생기지 않는가)
12. 길게 눌러 메뉴를 띄우고 `Cancel` → 손을 뗀 뒤 **아무것도 열리지 않는가**
13. 물리 클릭 2회 → 커서 / 스크롤 모드 토글이 그대로 되는가
14. 길게 누르다 중간에 손을 떼기(0.6초 직전) → 평소 클릭으로 동작하는가
15. Menu 버튼 뒤로가기, PlayPause 1회·2회 정상인가
16. 탭 오버뷰를 띄운 상태에서 길게 누르기 → 메뉴가 뜨지 않고 탭 선택이 정상인가
17. 방향패드 스크롤·엣지 오토스크롤 정상인가

=== 여기까지 복사 ===
