# 작업 6 — 가벼운 터치 / 클릭 구분, 링크 새 탭 열기 (Gemini 전달용)

> **사용법**: 아래 `=== 여기부터 복사 ===` 다음부터 문서 끝까지를 Gemini에 붙여넣고,
> `docs/SOURCE_BUNDLE_2.md` 파일을 **함께 첨부**하십시오.
> (v2.1.0에서 소스가 바뀌었으므로 이전 번들은 쓰지 마십시오.)

---

=== 여기부터 복사 ===

# 작업 의뢰: tvOS 브라우저 — 터치/클릭 구분과 링크 새 탭 열기

당신은 tvOS 네이티브 앱을 수정하는 Objective-C 개발자입니다. 첨부한 `SOURCE_BUNDLE_2.md`가 **현재 저장소의 실제 원본**입니다. 그 내용만을 사실로 삼고, 존재하지 않는 API나 파일을 지어내지 마십시오.

## 0. 먼저 알아둘 것 — 멀티탭은 이미 구현되어 있습니다

탭 시스템을 새로 만들지 마십시오. 이미 다음이 전부 동작합니다.

| 항목 | 현황 |
|---|---|
| 탭 모델 | `BrowserViewModel.tabs`, 활성 탭 인덱스 관리 |
| 최대 탭 수 | **5개** (`BrowserViewModel.m`의 `kMaximumTabCount`) |
| 탭 오버뷰 UI | `BrowserTabOverviewController` — 썸네일, 전환, 닫기 |
| 세션 저장·복원 | `BrowserSessionStore` |
| 새 탭 생성 | `BrowserTabCoordinator`의 `createNewTabWithRequest:` / `createNewTabLoadingHomePage:` |

이미 새 탭이 열리는 경로도 세 가지 있습니다.

1. `target="_blank"` 링크 클릭 → `BrowserPageActionCoordinator`의 `handleTargetBlankLinkAtDOMPoint:webView:`
2. 웹뷰 델리게이트의 `webView:shouldCreateNewTabWithRequest:navigationType:`
3. 고급 메뉴의 `Open New Tab`

**이번 작업은 기존 탭 API를 호출하는 것이 전부입니다.** 새 탭 자료구조, 새 오버뷰, 새 저장 로직을 만들지 마십시오.

### 이미 쓸 수 있는 API (그대로 호출할 것)

```objc
// BrowserTabCoordinator — 새 탭을 만들어 전면으로 전환한다.
// 탭이 5개를 넘으면 NO를 반환하고 "Maximum Tabs Reached" 알림을 스스로 띄운다.
- (BOOL)createNewTabWithRequest:(NSURLRequest *)request;

// BrowserPageActionCoordinatorHost — 이미 선언되어 있고 ViewController가 구현 중이다.
- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request;

// BrowserDOMInteractionService — a[href]를 closest로 찾아 {href, target}을 돌려준다.
- (NSDictionary *)linkInfoAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView;

// BrowserNavigationService — 문자열 URL을 요청으로 바꾼다. 실패하면 nil.
- (NSURLRequest *)requestForURLString:(NSString *)URLString;
```

## 1. 현재 입력 체계 (실제 코드 기준)

- **물리 클릭(Select 프레스) 1회** = 페이지 클릭. 단 더블 클릭 판정 때문에 **0.3초 지연 후** 실행됩니다 (`handleSelectPressEnded`).
- **물리 클릭 2회** = 커서 / 스크롤 모드 토글.
- **가벼운 터치** = 커서 이동만. 클릭으로 인식되지 않습니다.
- 커서 모드에서 클릭하면 `ViewController`의 `browserHandlePrimaryAction` → `BrowserPageActionCoordinator`의 `handlePageSelectionAtDOMPoint:webView:`로 들어갑니다.

### v2.1.0에서 들어간 것 — 지우거나 되돌리지 마십시오

- `applyManualScrollDelta:`의 JavaScript 스크롤 폴백과 **20Hz 스로틀**(`enqueueJavaScriptScrollDelta:`, `flushPendingJavaScriptScroll`, `resetPendingJavaScriptScroll`). 이 평가는 동기 호출이라 매 프레임 호출하면 안 됩니다.
- 방향패드 페이지 스크롤, 길게 누르기 연속 스크롤, 엣지 오토스크롤.
- `handleTouchesEnded`가 `stopEdgeAutoScroll`을 호출하는 것. **이 호출을 반드시 유지하십시오.**

## 2. 만들 동작

| 조작 | 링크 위에서 | 링크가 아닌 요소 위에서 |
|---|---|---|
| **가벼운 터치(탭)** | 현재 탭에서 열기 (지연 없이 즉시) | 기존 동작 — 버튼 클릭, 입력란, 비디오 재생 |
| **물리 클릭 1회** | **새 탭에서 열기** | 기존 동작 |
| **물리 클릭 2회** | 커서 / 스크롤 모드 토글 (기존 유지) | 동일 |

새 탭은 기존 `createNewTabWithRequest:` 동작대로 **전면으로 전환**됩니다. 백그라운드 탭은 만들지 마십시오.

## 3. 구현 요구사항

### 3-1. 탭(가벼운 터치) 판정 — `BrowserRemoteInputController`

타이머로 추측하지 말고 **플래그로 판정**하십시오. 물리 클릭은 터치 이벤트도 함께 발생시키므로, 플래그 없이는 한 번의 클릭이 탭과 클릭 두 번으로 실행됩니다.

tvOS에서 이벤트 순서는 보통 이렇습니다.

```
touchesBegan → pressesBegan(Select) → pressesEnded(Select) → touchesEnded
```

따라서 `touchesEnded` 시점에는 이번 터치 중에 Select 프레스가 있었는지 이미 알 수 있습니다.

- `handleTouchesBegan:` — 시작 시각, 시작 커서 위치를 기록하고 `selectPressDuringCurrentTouch = NO`로 초기화
- `handleTouchesMoved:` — 시작 위치로부터의 **최대 이동 거리**를 갱신
- `handlePressesBegan:` / `handlePressesEnded:` — `press.type == UIPressTypeSelect`이면 `selectPressDuringCurrentTouch = YES`
- `handleTouchesEnded` — 아래 조건을 **전부** 만족하면 탭으로 간주
  - 커서 모드이고, 탭 오버뷰·상단바 포커스·모달이 모두 비활성
  - `tapToClickEnabled`가 켜져 있음
  - 터치 지속 시간 **250ms 미만**
  - 최대 이동 거리 **20pt 미만**
  - `selectPressDuringCurrentTouch == NO`

조건을 만족하면 `browserRemoteInputControllerHandlePrimaryActionWithSource:`를 **지연 없이 즉시** `Tap`으로 호출하십시오. 기존 0.3초 지연 경로를 타게 하지 마십시오.

`handleTouchesEnded`의 기존 내용(`lastTouchLocation` 초기화, `stopEdgeAutoScroll`)은 그대로 두고 그 뒤에 판정을 추가하십시오.

### 3-2. 활성화 소스 전달

`BrowserRemoteInputController.h` 맨 위, `NS_ASSUME_NONNULL_BEGIN` 앞에 선언하십시오.

```objc
typedef NS_ENUM(NSInteger, BrowserPageActivationSource) {
    BrowserPageActivationSourceTap = 0,
    BrowserPageActivationSourceClick,
};
```

이 값을 다음 세 단계로 흘려보내십시오. **세 곳을 모두 함께 고쳐야 컴파일됩니다.**

1. 프로토콜: `browserRemoteInputControllerHandlePrimaryAction` → `browserRemoteInputControllerHandlePrimaryActionWithSource:(BrowserPageActivationSource)source`
2. `ViewController`: `browserHandlePrimaryAction` → `browserHandlePrimaryActionWithSource:`, 프로토콜 구현부도 같이 수정
3. `BrowserPageActionCoordinator`: `handlePageSelectionAtDOMPoint:webView:` → `handlePageSelectionAtDOMPoint:webView:source:` (헤더와 구현부 모두)

기존 `handleSelectPressEnded`의 지연 실행 경로는 `Click`을 넘기십시오. 탭 오버뷰 선택 경로(`browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:`)는 **손대지 마십시오.**

### 3-3. 새 탭 열기 규칙 — `BrowserPageActionCoordinator`

`handlePageSelectionAtDOMPoint:webView:source:` 안에서 **순서를 반드시 지키십시오.**

1. 비디오 처리 (`handleSelectPressForVideoAtCursor`) — 기존 그대로, 최우선
2. `target="_blank"` 처리 (`handleTargetBlankLinkAtDOMPoint:`) — 기존 그대로. 소스와 무관하게 항상 새 탭
3. **신규**: `source == BrowserPageActivationSourceClick` 이고 `openLinksInNewTabOnClick`이 켜져 있고 링크이면 → 새 탭으로 열고 `YES` 반환
4. 그 외 — 기존 동작 그대로

**링크 판정과 제외 조건**

`linkInfoAtDOMPoint:`의 `href`를 쓰되, 아래는 전부 **기존 동작(같은 탭)으로 넘기십시오.**

- `href`가 비어 있음
- `javascript:`, `mailto:`, `tel:` 로 시작
- `#` 로 시작하거나, 현재 페이지 URL과 **프래그먼트만** 다른 경우 (같은 페이지 내 앵커)
- `requestForURLString:`가 `nil`을 반환

**탭 한도 처리 — 중요**

`browserPageActionCoordinatorCreateNewTabWithRequest:`가 `NO`를 반환하면 탭이 5개라는 뜻이고, 이때 "Maximum Tabs Reached" 알림은 **이미 떠 있습니다.** 그 상태에서 같은 탭으로 다시 열지 마십시오. 알림이 뜬 채로 페이지가 바뀌면 사용자가 무슨 일이 일어났는지 알 수 없습니다. `YES`를 반환하고 그대로 끝내십시오.

### 3-4. 설정 — `BrowserPreferencesStore`

| 키 | 기본값 |
|---|---|
| `tapToClickEnabled` | **YES** |
| `openLinksInNewTabOnClick` | **YES** |

고급 메뉴의 기존 `Scrolling & Input` 섹션에 토글 두 개를 추가하십시오. 제목은 켜짐/꺼짐을 그대로 보이는 방식(`Tap to Click: On` / `Open Links in New Tab: On`)으로, 기존 토글 항목들과 같은 형태로 만드십시오.

**반드시 지킬 상호작용 규칙**: `tapToClickEnabled`가 **꺼져 있으면** `openLinksInNewTabOnClick` 값과 무관하게 물리 클릭은 **기존 동작(같은 탭)** 이어야 합니다. 탭 투 클릭이 꺼진 상태에서 클릭이 새 탭만 연다면 같은 탭에서 링크를 열 수단이 아예 사라지기 때문입니다.

### 3-5. 사용 안내 갱신

`ViewController`의 `showHintsAlert` 메시지에 두 줄을 추가하십시오 (영문, 기존 문장 형식에 맞출 것).

- 가볍게 톡 치면 현재 탭에서 열린다
- 꾹 눌러 클릭하면 링크가 새 탭에서 열린다

## 4. 제약 — 반드시 지킬 것

1. **Swift / SwiftUI 금지.** 전부 Objective-C (ARC).
2. **서드파티 라이브러리, CocoaPods, SPM 금지.**
3. **`project.pbxproj`, `Info.plist`, 워크플로 YAML을 수정하지 마십시오.** 새 파일을 만든 경우 목록만 적으면 등록은 검수자가 합니다.
4. **새 프레임워크 링크 금지.** 현재 Foundation과 UIKit만 링크되어 있습니다.
5. **기존 동작을 깨뜨리지 마십시오.**
   - 물리 클릭 2회 = 커서/스크롤 모드 토글
   - Menu = 뒤로 가기, 루트에서 종료 확인
   - PlayPause 1회 = 퀵 메뉴, 2회 = 고급 메뉴
   - 탭 오버뷰, 상단바 포커스, 네이티브 비디오 플레이어
   - v2.1.0의 스크롤 기능 일체 (1절 참고)
6. 로그는 기존 포맷을 따르십시오: `NSLog(@"[InputTrace][...] ...")`.
7. 코드 스타일은 기존대로 — `Browser` 접두사, 호스트 프로토콜 패턴, `NS_ASSUME_NONNULL_BEGIN/END`, 블록 안에서는 `__weak typeof(self) weakSelf = self;`.

### 알려진 한계 — 구현하려 들지 마십시오

`href` 없이 JavaScript `onclick`만으로 이동하는 링크는 열 주소를 미리 알 수 없어 새 탭으로 보낼 수 없습니다. 이런 요소는 그냥 기존 동작(같은 탭)으로 두십시오. 억지로 가로채려 하면 멀쩡한 버튼까지 오작동합니다.

## 5. 결과물 제출 형식

1. **수정한 파일은 전체 내용을 출력하십시오.** 부분 diff, `// ... 기존 코드 ...` 같은 생략 표기는 금지입니다. 검수자가 그대로 덮어쓸 수 있어야 합니다.
2. 각 파일 앞에 경로를 한 줄로 적고 코드 블록을 여십시오.
   ```
   FILE: _Project/Browser/BrowserRemoteInputController.m
   ```
   그 다음 줄부터 ```objc 코드 블록.
3. 응답 맨 앞에 세 가지를 요약하십시오 — **새로 추가한 파일**, **수정한 기존 파일**, **영향받는 기존 동작**.
4. 응답 맨 뒤에 **기기에서 확인할 테스트 절차**를 번호 목록으로 적으십시오.
5. 컴파일러를 쓸 수 없는 환경이므로, 내놓기 전에 스스로 점검하십시오.
   - 메서드 이름을 바꾼 세 곳(프로토콜 선언 / `ViewController` 구현 / `BrowserPageActionCoordinator` 헤더·구현)을 **빠짐없이** 고쳤는가
   - 이름을 바꾼 메서드의 **옛 이름 호출부가 남아 있지 않은가**
   - `typedef`를 쓰는 모든 파일에서 해당 헤더를 import하고 있는가
   - 헤더에 선언하지 않은 메서드를 외부에서 호출하고 있지 않은가
   - 블록에서 `self`를 강하게 캡처해 순환 참조를 만들지 않았는가

## 6. 기기 테스트 절차 (응답에 이 항목들을 포함해 보강할 것)

1. 링크 위에서 가볍게 톡 → **같은 탭**에서 열리는가, 지연 없이 즉시 반응하는가
2. 같은 링크를 꾹 눌러 클릭 → **새 탭**에서 열리는가, 탭 오버뷰에 2개가 보이는가
3. 한 번의 물리 클릭으로 **탭이 두 개 열리지 않는가** (중복 실행 방지 확인)
4. 물리 클릭 2회 → 모드 토글이 그대로 되는가
5. 커서를 크게 움직이다 손을 뗐을 때 → 클릭이 **발생하지 않는가**
6. 버튼·입력란·비디오를 클릭 → 새 탭이 열리지 않고 기존 동작 그대로인가
7. 탭 5개를 채운 뒤 링크 클릭 → 한도 알림만 뜨고 페이지가 바뀌지 않는가
8. 고급 메뉴에서 `Tap to Click`을 끄고 클릭 → 같은 탭에서 열리는가
9. 같은 페이지 내 앵커(`#` 링크) 클릭 → 새 탭이 열리지 않는가

=== 여기까지 복사 ===

---

## 검수 · 업로드 절차 (Claude가 처리)

Gemini 결과를 그대로 전달하시면 다음 순서로 진행합니다.

1. 저장소 원본과 대조 — 기존 코드 누락·변조 확인
2. 코드 리뷰 — 이름 바꾼 메서드의 호출부 누락, 프로토콜 구현 누락, 중복 실행, 순환 참조
3. 파일 반영, 새 파일이 있으면 `project.pbxproj` 등록
4. 버전 2.2.0으로 커밋·푸시, Actions 빌드
5. IPA 릴리스 게시 및 SHA-256 확인
