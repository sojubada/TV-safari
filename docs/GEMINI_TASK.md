# tvOS Browser 개선 작업 지침 (Gemini 전달용)

> **사용법**: 아래 `=== 여기부터 복사 ===` 줄 다음부터 문서 끝까지를 그대로 Gemini에 붙여넣으십시오.
> 작업은 5개 단계로 나뉘어 있고, **한 번에 한 단계씩** 받는 것이 좋습니다.
> Gemini가 내놓은 코드는 그대로 Claude에게 전달하면 검수 → 저장소 반영 → 빌드 → IPA 릴리스까지 처리합니다.

---

=== 여기부터 복사 ===

# 작업 의뢰: Apple TV용 웹 브라우저(tvOS) 기능 개선

당신은 tvOS 네이티브 앱을 수정하는 Objective-C 개발자입니다. 아래 프로젝트의 실제 소스 구조를 그대로 전제하고 코드를 작성하십시오. 추측으로 존재하지 않는 API나 파일을 만들지 마십시오.

## 1. 프로젝트 사실 관계 (이미 확인된 내용 — 바꾸지 말 것)

| 항목 | 값 |
|---|---|
| 언어 | Objective-C (ARC 사용) |
| 플랫폼 | tvOS, 배포 타깃 15.6, 실제 기기는 tvOS 16.x |
| 빌드 | GitHub Actions의 macOS 러너 + Xcode 26.x, 미서명 IPA 생성 |
| 설치 | TrollStore (기기에서 자체 서명) |
| 웹 엔진 | `WKWebView` — tvOS에는 WebKit이 공개 노출되지 않으므로 `dlopen` + `NSClassFromString` + `objc_msgSend`로 런타임 로드 |
| 링크된 프레임워크 | **Foundation, UIKit 뿐** |

### 소스 파일 구조 (`_Project/Browser/`)

| 파일 | 줄 수 | 역할 |
|---|---|---|
| `BrowserRemoteInputController.m/.h` | 454 | **리모컨 입력 총괄.** 커서 이동, 스크롤, Select/Menu/PlayPause 프레스 처리 |
| `BrowserWebView.m/.h` | 1168 | WKWebView 런타임 래퍼. `stringByEvaluatingJavaScriptFromString:`(동기), `scrollView`, `goBack`, `goForward` 제공 |
| `BrowserDOMInteractionService.m/.h` | 743 | 커서 좌표 → DOM 좌표 변환, 요소 탐색 JS 실행 |
| `BrowserPageActionCoordinator.m/.h` | 237 | 웹 요소 클릭 처리. 입력란 클릭 시 텍스트 입력 Alert 표시 |
| `BrowserPreferencesStore.m/.h` | 121 | NSUserDefaults 기반 설정 저장소 |
| `BrowserMenuCoordinator.m/.h` | 1107 | Advanced Menu(고급 메뉴) 구성 |
| `BrowserTabCoordinator.m/.h` | 661 | 탭/웹뷰 생성 및 프레임 관리 |
| `ViewController.m/.h` | 847 | 루트 뷰컨트롤러. `BrowserRemoteInputControllerHost` 프로토콜 구현체 |
| `BrowserTopBarView.m/.h` | 468 | 상단 내비게이션 바 |

### 현재 입력 체계 (실제 코드 기준)

- **두 가지 모드**가 있습니다. `cursorModeEnabled`(커서 모드) / 스크롤 모드.
  - 터치면을 **더블 클릭**하면 모드가 토글됩니다 (`handleSelectPressEnded`, 0.3초 지연 판정).
  - 커서 모드에서는 `refreshInteractionState`가 `scrollView.scrollEnabled = NO`로 두고 팬 제스처도 끕니다. **즉 커서 모드에서는 스크롤이 전혀 되지 않습니다.**
- **방향패드**: `Up`만 상단바 포커스 진입에 사용됩니다. `Down`/`Left`/`Right`는 사용되지 않습니다(네이티브 비디오 재생 중 Left/Right 더블탭 = 5초 스킵만 예외).
- **Menu(‹) 버튼**: `goBack`. 히스토리가 없으면 종료 확인 Alert.
- **PlayPause 버튼**: 1회 = URL 입력, 2회 = Advanced Menu.
- **스크롤 구현**: `BrowserRemoteInputController`의 `applyManualScrollDelta:`가 `UIScrollView.contentOffset`을 직접 조작하는 방식 **하나뿐**입니다. JavaScript 기반 스크롤은 코드 어디에도 없습니다.
- **텍스트 입력**: 입력란 클릭 → `UIAlertController` + `UITextField` → tvOS 시스템 키보드 → 확정 시 JS로 DOM의 `value`에 주입하고 `input`/`change` 이벤트 디스패치.
- **키보드 처리**: 전혀 없습니다. `UIPress.key`를 보는 코드도, GameController 사용도 없습니다.

## 2. 반드시 지킬 제약

1. **Swift / SwiftUI 금지.** 전부 Objective-C.
2. **서드파티 라이브러리, CocoaPods, SPM 금지.**
3. **`project.pbxproj`를 수정하지 마십시오.** 새 소스 파일을 만드는 것은 허용하되, 만든 경우 "새로 추가한 파일" 목록을 결과 맨 앞에 따로 적으십시오. 프로젝트 등록은 검수자가 처리합니다.
4. **새 프레임워크 링크 금지.** 현재 Foundation과 UIKit만 링크되어 있습니다. GameController(`GCKeyboard`)는 사용하지 마십시오. 키보드 입력은 `UIPress.key`(UIKit, tvOS 13.4+)로만 처리하십시오.
5. **기존 동작을 깨뜨리지 마십시오.** 특히 다음은 그대로 유지되어야 합니다.
   - 터치면 더블 클릭 = 커서/스크롤 모드 토글
   - Menu = 뒤로 가기, 루트에서 종료 확인
   - PlayPause 1회/2회 동작
   - 탭 오버뷰, 상단바 포커스 모드, 네이티브 비디오 플레이어 동작
6. **새 기능은 전부 `BrowserPreferencesStore`에 on/off 설정을 추가**하고, `BrowserMenuCoordinator`의 Advanced Menu에 토글 항목을 넣으십시오. 기본값은 각 작업 항목에 지정되어 있습니다.
7. 로그는 기존 포맷을 따르십시오: `NSLog(@"[InputTrace][...] ...")`.
8. 코드 스타일: 기존대로 `Browser` 접두사, 호스트 프로토콜(delegate) 패턴, `NS_ASSUME_NONNULL_BEGIN/END`.

## 3. 작업 항목

### 작업 1 — 페이지 스크롤이 먹지 않는 문제 해결 (JS 스크롤 도입)

**증상**: 긴 웹페이지인데도 아래로 내려갈 내용이 없는 것처럼 동작한다.

**원인 분석 (코드 확인 결과)**: 스크롤이 오직 `UIScrollView.contentOffset` 조작으로만 구현되어 있습니다. 그런데

- 요즘 사이트 상당수는 `body { overflow: hidden }` + 내부 `div { overflow: auto }` 구조(SPA 레이아웃)를 씁니다. 이 경우 WKWebView 자체 scrollView의 `contentSize`는 `bounds`와 같아서, `applyManualScrollDelta:`의 `maxOffsetY`가 0이 되어 **아무리 스크롤해도 움직이지 않습니다.**
- 또 lazy-load / 무한 스크롤 콘텐츠는 실제 스크롤 이벤트가 있어야 추가 로드됩니다.

**요구사항**

1. `BrowserDOMInteractionService`에 메서드 추가:
   ```objc
   - (BOOL)scrollActiveContainerByX:(CGFloat)dx y:(CGFloat)dy atPoint:(CGPoint)domPoint webView:(BrowserWebView *)webView;
   ```
   동작: 주어진 DOM 좌표의 `document.elementFromPoint`에서 시작해 부모 방향으로 올라가며 **실제로 스크롤 가능한 조상**(`scrollHeight > clientHeight` 이고 `overflow`가 `auto`/`scroll`인 요소)을 찾습니다. 찾으면 그 요소를 `scrollBy`, 못 찾으면 `window.scrollBy`. 스크롤 전후 위치를 비교해 실제로 움직였는지 `true`/`false`로 반환하십시오.

2. `BrowserRemoteInputController`의 `applyManualScrollDelta:`를 다음 순서로 바꾸십시오.
   - ① 기존 `contentOffset` 방식 시도 → 실제로 움직였으면 끝.
   - ② 움직이지 않았으면 위의 JS 스크롤을 호출 → 그 결과를 반환.
   - 호스트 프로토콜(`BrowserRemoteInputControllerHost`)에 JS 스크롤을 요청하는 메서드를 추가하고 `ViewController`에서 구현하십시오. 컨트롤러가 DOM 서비스를 직접 들고 있지 않도록 기존 구조를 따르십시오.

3. **진단 메뉴 추가**: Advanced Menu에 `Page Scroll Diagnostics` 항목을 추가하고, 선택 시 아래 값을 Alert로 표시하십시오. (원인 확정용이므로 반드시 포함)
   - `document.documentElement.scrollHeight`, `document.body.scrollHeight`, `window.innerHeight`
   - 네이티브 `scrollView.contentSize.height`, `scrollView.bounds.size.height`
   - 페이지 내 "스크롤 가능한 내부 컨테이너" 개수와 그중 가장 큰 것의 `scrollHeight`
   - 현재 `pageZoom` 값

---

### 작업 2 — 방향패드 스크롤 + 엣지 오토스크롤

**목표**: 커서 모드를 유지한 채로 긴 페이지를 편하게 읽을 수 있게 한다.

**요구사항**

1. **방향패드 페이지 스크롤**
   - `Down` 프레스: 화면 높이의 85%만큼 아래로 스크롤.
   - `Up` 프레스: 화면 높이의 85%만큼 위로 스크롤. **단 기존 상단바 포커스 기능과 충돌하므로**, 커서 y좌표가 화면 높이의 12% 미만(= 커서가 화면 최상단에 있을 때)이면 기존대로 상단바 포커스로 진입하고, 그 외에는 위로 스크롤하십시오.
   - 스크롤은 0.25초 ease-out 애니메이션으로 부드럽게.
   - 커서 모드/스크롤 모드 양쪽에서 모두 동작해야 합니다.
   - 상단바 포커스 중, 탭 오버뷰 표시 중, 모달이 떠 있을 때는 동작하지 않아야 합니다.

2. **길게 누르기 연속 스크롤**
   - `Up`/`Down`을 0.4초 이상 누르고 있으면 연속 스크롤(초당 약 900pt), 떼면 정지.
   - `UIPressPhaseBegan`에서 타이머를 걸고 `UIPressPhaseEnded`/`Cancelled`에서 해제하십시오.

3. **엣지 오토스크롤**
   - 커서 모드에서 커서가 화면 상단 8% 또는 하단 8% 영역에 들어가면 자동으로 스크롤 시작.
   - 속도는 가장자리에 가까울수록 빨라지게 (가장자리에서 최대 1200pt/s, 경계에서 0).
   - `CADisplayLink`로 구현하고, 커서가 영역을 벗어나거나 모드가 바뀌면 즉시 정지.
   - 기존 `startManualScrollInertiaWithVelocity:` / `stopManualScrollInertia`와 상태가 꼬이지 않도록 하십시오. 엣지 오토스크롤과 관성 스크롤은 동시에 돌면 안 됩니다.

4. 설정: `edgeAutoScrollEnabled` (기본 **YES**), `dpadScrollEnabled` (기본 **YES**).

---

### 작업 3 — 블루투스 키보드 미연결 시 기존 입력 방식 유지

**배경**: 키보드가 없을 때는 지금의 `UIAlertController` 방식이 오히려 편합니다(아이폰으로 입력 가능). 그러니 **키보드가 있을 때만** 직접 입력으로 전환해야 합니다.

**요구사항**

1. 새 클래스 `BrowserKeyboardInputController`를 만드십시오 (`.h`/`.m`). 역할:
   - 하드웨어 키보드 연결 여부 추적
   - 키 입력 수신 및 한/영 조합 처리 (작업 4)
   - 현재 입력 모드 표시 뷰 관리

2. **연결 판정**: `GCKeyboard`를 쓸 수 없으므로 `UIPress.key`로 판정합니다.
   - `pressesBegan:withEvent:`에서 `press.key != nil`인 이벤트를 한 번이라도 받으면 `hardwareKeyboardDetected = YES`로 기록하고, 이 값을 `NSUserDefaults`에 저장해 다음 실행에서도 유지하십시오.
   - Advanced Menu에 `Hardware Keyboard: Auto / Always On / Always Off` 3단 설정을 추가하십시오. 기본값 **Auto**.
   - `Always Off`이거나, `Auto`인데 아직 키 입력을 받은 적이 없으면 → **기존 Alert 경로를 그대로 사용**합니다. `BrowserPageActionCoordinator`의 현재 동작을 건드리지 마십시오.

3. 키보드가 감지된 상태에서 입력란을 클릭하면:
   - Alert를 띄우지 말고, 해당 DOM 요소에 `focus()`를 준 뒤 직접 입력 모드로 들어갑니다.
   - 화면 우측 상단에 작은 인디케이터를 띄우십시오: `⌨ 한` 또는 `⌨ EN`. 반투명 배경, 모서리 둥글게, 입력 모드 종료 시 사라짐.
   - `Esc` 또는 Menu 버튼으로 직접 입력 모드를 빠져나오고, 그때 `blur()` 처리.

---

### 작업 4 — 한/영 직접 입력 (두벌식 조합)

**중요**: tvOS 시스템 IME는 앱의 커스텀 입력 경로에 조합된 한글을 주지 않습니다. `UIPress.key`는 raw 키코드만 줍니다. 따라서 **한글 조합 오토마타를 직접 구현해야 합니다.**

**요구사항**

1. **한/영 전환 키**
   - 1순위: `UIKeyboardHIDUsageKeyboardHangul` (= LANG1, raw 0x90). 한국어 키보드의 한/영 키입니다.
   - 2순위(폴백): `UIKeyboardHIDUsageKeyboardCapsLock`, 그리고 `Control + Space`.
   - 전환 시 인디케이터 표시를 즉시 갱신하고, 조합 중이던 글자는 확정하십시오.

2. **두벌식 매핑 테이블** (아래 값을 그대로 쓰십시오)

   ```
   q ㅂ   w ㅈ   e ㄷ   r ㄱ   t ㅅ   y ㅛ   u ㅕ   i ㅑ   o ㅐ   p ㅔ
   a ㅁ   s ㄴ   d ㅇ   f ㄹ   g ㅎ   h ㅗ   j ㅓ   k ㅏ   l ㅣ
   z ㅋ   x ㅌ   c ㅊ   v ㅍ   b ㅠ   n ㅜ   m ㅡ
   Shift:  Q ㅃ   W ㅉ   E ㄸ   R ㄲ   T ㅆ   O ㅒ   P ㅖ
   ```

3. **조합 테이블**

   - 초성 19자 순서: `ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ`
   - 중성 21자 순서: `ㅏ ㅐ ㅑ ㅒ ㅓ ㅔ ㅕ ㅖ ㅗ ㅘ ㅙ ㅚ ㅛ ㅜ ㅝ ㅞ ㅟ ㅠ ㅡ ㅢ ㅣ`
   - 종성 28자 순서: `(없음) ㄱ ㄲ ㄳ ㄴ ㄵ ㄶ ㄷ ㄹ ㄺ ㄻ ㄼ ㄽ ㄾ ㄿ ㅀ ㅁ ㅂ ㅄ ㅅ ㅆ ㅇ ㅈ ㅊ ㅋ ㅌ ㅍ ㅎ`
   - 완성형 코드: `0xAC00 + (초성index × 21 + 중성index) × 28 + 종성index`
   - 복합 중성: `ㅗ+ㅏ=ㅘ`, `ㅗ+ㅐ=ㅙ`, `ㅗ+ㅣ=ㅚ`, `ㅜ+ㅓ=ㅝ`, `ㅜ+ㅔ=ㅞ`, `ㅜ+ㅣ=ㅟ`, `ㅡ+ㅣ=ㅢ`
   - 복합 종성: `ㄱ+ㅅ=ㄳ`, `ㄴ+ㅈ=ㄵ`, `ㄴ+ㅎ=ㄶ`, `ㄹ+ㄱ=ㄺ`, `ㄹ+ㅁ=ㄻ`, `ㄹ+ㅂ=ㄼ`, `ㄹ+ㅅ=ㄽ`, `ㄹ+ㅌ=ㄾ`, `ㄹ+ㅍ=ㄿ`, `ㄹ+ㅎ=ㅀ`, `ㅂ+ㅅ=ㅄ`

4. **오토마타 동작 규칙**
   - 종성이 있는 글자에 모음이 들어오면 **종성을 떼어내 다음 글자의 초성으로 넘깁니다.** 복합 종성이면 뒷자음만 넘깁니다. (예: `각` + `ㅏ` → `가` + `가`, `앉` + `ㅏ` → `안` + `자`)
   - 조합 중 백스페이스는 **자모 하나씩** 지웁니다. 조합 중이 아니면 확정된 글자 하나를 지웁니다.
   - 영문 모드에서는 조합 없이 그대로 입력합니다.
   - 스페이스/엔터/방향키 등 조합 불가 입력이 오면 조합 중이던 글자를 먼저 확정합니다.

5. **DOM 주입 방식**
   - 매 키 입력마다 `확정된 문자열 + 조합 중인 글자`를 포커스된 요소의 `value`(또는 `textContent`)에 통째로 반영하고, `selectionStart`/`selectionEnd`를 끝으로 보내십시오.
   - `input` 이벤트를 `bubbles: true`로 디스패치하십시오(리액트 기반 사이트 대응).
   - `Enter`: 폼이 있으면 `form.submit()`, 없으면 조합만 확정.
   - 문자열은 반드시 기존 `javaScriptEscapedString:`으로 이스케이프하십시오.

6. 한글 오토마타는 **UIKit에 의존하지 않는 독립 클래스**(`BrowserHangulComposer`)로 분리하십시오. 입력은 자모 문자, 출력은 `(확정 문자열, 조합 중 문자열)` 쌍입니다. 테스트하기 쉬운 순수 로직이어야 합니다.

---

### 작업 5 — 가벼운 터치와 클릭 구분, 탭으로 좌클릭

**현재**: 물리 클릭(Select 프레스)만 클릭으로 인식되고, 더블 클릭 판정 때문에 **0.3초 지연 후에야** 클릭이 실행됩니다. 반응이 둔하게 느껴집니다.

**요구사항**

1. **탭 투 클릭**: 터치면을 가볍게 톡 치면 즉시 좌클릭으로 처리하십시오.
   - 판정 조건: `touchesBegan` → `touchesEnded`가 **250ms 이내**, 그 사이 커서 이동 거리가 **20pt 미만**, 그리고 그동안 `UIPressTypeSelect` 프레스가 오지 않았을 것.
   - 조건을 만족하면 `browserRemoteInputControllerHandlePrimaryAction`을 **지연 없이** 즉시 호출하십시오.

2. **중복 실행 방지**: 물리 클릭은 터치 이벤트도 함께 발생시킵니다. `UIPressTypeSelect` 프레스가 감지되면 대기 중이던 탭 클릭을 **반드시 취소**하십시오. 같은 동작이 두 번 실행되면 안 됩니다.

3. **물리 클릭 동작은 그대로 유지**: 1회 = 클릭, 2회 = 커서/스크롤 모드 토글.

4. 설정: `tapToClickEnabled` (기본 **YES**). 끄면 기존 동작 그대로.

5. 오작동 방지: 커서를 움직이는 중(직전 150ms 내에 커서가 20pt 이상 이동)에 손가락을 떼는 것은 탭으로 보지 마십시오.

---

## 4. 결과물 제출 형식 (반드시 지킬 것)

1. **한 번에 한 작업 단계씩** 내놓으십시오. 지시가 없으면 작업 1과 작업 2만 먼저 작성하십시오.

2. **수정한 파일은 전체 내용을 출력하십시오.** 부분 diff, `// ... 기존 코드 ...` 같은 생략 표기는 금지입니다. 검수자가 그대로 파일에 덮어쓸 수 있어야 합니다.

3. 각 파일 앞에 경로를 한 줄로 적고 코드 블록을 여십시오.

   ```
   FILE: _Project/Browser/BrowserRemoteInputController.m
   ```
   그 다음 줄부터 ```objc 코드 블록.

4. 응답 맨 앞에 다음 3가지를 요약하십시오.
   - **새로 추가한 파일 목록** (없으면 "없음")
   - **수정한 기존 파일 목록**
   - **기존 동작 중 영향을 받는 부분** (없으면 "없음")

5. 응답 맨 뒤에 **기기에서 확인할 테스트 절차**를 번호 목록으로 적으십시오.

6. 다음은 출력하지 마십시오: `project.pbxproj`, Info.plist, 워크플로 YAML, 빌드 설정.

7. 컴파일러를 쓸 수 없는 환경이므로, 코드를 내놓기 전에 스스로 다음을 점검하십시오.
   - 사용한 메서드가 위 "프로젝트 사실 관계"에 실제로 존재하는가
   - 헤더에 선언하지 않은 메서드를 외부에서 호출하고 있지 않은가
   - 프로토콜에 메서드를 추가했다면 `ViewController`의 구현도 같이 수정했는가
   - 블록 안에서 `self`를 강하게 캡처해 순환 참조를 만들지 않았는가 (`__weak typeof(self) weakSelf = self;` 패턴 사용)
   - `NS_ASSUME_NONNULL` 구간에서 nullable 반환을 명시했는가

=== 여기까지 복사 ===

---

## 검수 · 업로드 절차 (Claude가 처리)

Gemini 결과를 받으면 그대로 Claude에게 전달하십시오. 다음 순서로 진행합니다.

1. 코드 리뷰 — 존재하지 않는 API 호출, 프로토콜 구현 누락, 순환 참조, 기존 동작 회귀 여부 점검
2. 저장소 파일 반영, 새 파일이 있으면 `project.pbxproj`에 등록
3. 커밋 및 푸시
4. GitHub Actions 빌드 실행, 실패 시 로그 확인 후 수정
5. 미서명 IPA 릴리스 게시 및 SHA-256 확인
