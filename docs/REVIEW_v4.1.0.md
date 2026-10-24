# tvOS Browser v4.1.0 — 코드 검토 요청서

이 문서는 **제미나이에게 코드 검토를 맡기기 위한 지침서**입니다.
프로젝트의 제약, 지금까지 실제로 겪은 실패, 현재 상태, 그리고 **검토해 주었으면 하는 구체적 항목**을 담았습니다.

- 저장소: `sojubada/TV-safari` (fork of `jvanakker/tvOSBrowser`)
- 버전: v4.1.0 (build 5010)
- 작성일: 2026-10-24

---

## 1. 실행 환경과 제약

| 항목 | 내용 |
|---|---|
| 기기 | Apple TV 4K, **tvOS 16.6** |
| 설치 | TrollStore (탈옥 아님) |
| 언어 | Objective-C (ARC) |
| 배포 타깃 | tvOS 15.6 |
| 링크된 프레임워크 | **Foundation, UIKit 뿐** |
| WebKit | 링크하지 않고 **런타임에 `dlopen` + `NSClassFromString` + `objc_msgSend`** 로 접근 |
| 빌드 | 로컬 Xcode 없음. **GitHub Actions에서만 빌드** |
| 화면 | UIScreen 1920×1080 pt, **scale 2.0 / native 3840×2160 (실측)** |

### 절대 지켜야 할 것

1. **시스템 파일을 건드리지 않는다.** 기기가 멈추거나 벽돌이 되는 일이 없어야 한다.
   - 셸 실행 없음 (`NSTask`/`system`/`popen`/`fork` 금지)
   - 앱 샌드박스 밖 쓰기/삭제 없음
   - `Info.plist` · entitlements · 워크플로 변경 없음
   - `/System/` 접근은 WebKit `dlopen` 읽기 전용 하나뿐
2. 모든 상태는 **`NSUserDefaults`** 에 저장한다.
3. 최악의 경우도 **앱 크래시(재설치로 복구)** 선에서 끝나야 한다.

### TrollStore가 넣어줄 수 없는 entitlement

`com.apple.private.cs.debugger`, `dynamic-codesigning`(JIT), `com.apple.private.skip-library-validation`
→ **제3의 브라우저 엔진(Chromium 등)은 불가능.** WebKit 외 선택지가 없다.

---

## 2. 측정으로 확정된 사실 (추측 아님)

이 항목들은 기기에서 직접 재서 확인했다. **다시 의심하지 말 것.**

| 사실 | 근거 |
|---|---|
| **엔진에 MediaSource(MSE)가 없다** | `MediaSource: no`, `ManagedMediaSource: no`, `isTypeSupported unavailable`. `_setMediaSourceEnabled:YES`를 호출해도 객체가 생기지 않음 |
| **따라서 유튜브 재생은 불가능** | 유튜브는 MSE 없이 재생하지 않음. "브라우저에서 이 동영상을 재생할 수 없습니다"는 버그가 아니라 유튜브의 정확한 판단 |
| HLS·MP4는 네이티브 재생 가능 | `canPlayType hls: maybe`, `mp4: maybe`, `webm: no` |
| 앱 UI는 **4K로 렌더링된다** | `scale 2.0`, `nativeBounds 3840×2160` |
| **tvOS에 쓰기 가능한 Documents 디렉터리가 없다** | `NSDocumentDirectory`는 경로를 돌려주지만 쓰기가 조용히 실패. `Library/Caches`만 가능 |
| `getComputedStyle`은 **페이지 확대로 나눈 값**을 돌려준다 | 확대 110%에서 36px 규칙이 32.727로 읽힘. 실제 렌더링은 36px |
| 네이버 뉴스는 **요청 크기와 무관하게 같은 페이지**를 보낸다 | CSS에 `max-width:1110px` 16개 규칙, `1275px` 4개. **668px 위로 `@media` 중단점 없음** |
| 네이버 프린트 화면은 팝업이 아니라 URL | `https://n.news.naver.com/article/print/{oid}/{aid}` → 200 |

---

## 3. 실제로 겪은 실패 — 같은 실수를 반복하지 말 것

**이 목록이 이 문서에서 가장 중요합니다.** 전부 실제로 기기에서 터진 것들입니다.

### 3-1. 부분일치 CSS 선택자가 멀쩡한 콘텐츠를 지웠다 (3회)

```css
/* 전부 사고를 냈음 */
[class*="ad-"]      /* load-more, read-more, upload-date, thread-list 를 숨김 */
.*banner.*
```
→ **`~=`(토큰 일치)를 쓸 것. `*=`(부분일치)는 쓰지 말 것.**

### 3-2. 페이지의 모든 DOM 요소를 순회해서 웹 프로세스를 죽였다

```objc
// 과거 updateTextFontSize — 페이지 로드마다, 글자 100%여도 무조건 실행
var elements = document.querySelectorAll('body, body *');
for (...) { window.getComputedStyle(element).fontSize; element.style.setProperty(...); }
```
→ m.naver.com에서 웹 프로세스가 반복 사망. **스타일시트 한 장으로 교체함.**
→ **DOM 전수 순회 금지.** 조상 20단계 같은 유한 탐색만 허용.

### 3-3. "본문에 공간을 주려고" 옆 칼럼을 숨겼더니 본문이 사라졌다

본문 문단의 **형제 요소**를 숨겼는데, 네이버 기사에서는 본문 자체가 그 형제 중 하나였음.
→ 메뉴·푸터·저작권만 남은 페이지가 됨. **현재는 아무것도 숨기지 않음.**

### 3-4. 보이지 않는 문단을 본문으로 골랐다

"글자가 가장 많은 `<p>`"로 본문을 찾았는데 `display:none` 블록이 선택됨
→ `offsetWidth=0` → 모든 조상이 0 → 아무 효과 없음.
→ **가시성(`offsetWidth`, `offsetHeight`)을 먼저 확인할 것.**

### 3-5. 변형(transform)이 걸린 뷰에 frame을 설정했다

`layoutSubviews`에서 아이콘에 frame을 매번 할당 → 변형과 충돌, 포커스 확대가 보이지 않음.
→ **변형이 있으면 `bounds` + `center`를 쓸 것.** frame은 동작이 정의되지 않음.
→ v4.1.0의 화면 확대도 이 규칙으로 작성했음.

### 3-6. 선택 처리 중에 화면을 띄워서 앱이 죽었다 (3회)

- tvOS는 **포커스 갱신 중(select press 처리 중) present를 허용하지 않음**
- 그걸 고치려고 넣은 코드가 **자기 테이블이 실행 중인 객체를 해제** → use-after-free
- `preferredFocusEnvironments`가 **가려진 자식 뷰컨트롤러**를 가리킴 → UIKit 거부

→ **present는 `dispatch_async`로 미룰 것. 콜백 안에서 자기 자신을 해제하지 말 것.**

### 3-7. 평가 실패가 침묵해서 두 판을 낭비했다

`stringByEvaluatingJavaScriptFromString`이 2초 제한에 걸려 빈손으로 돌아오는데, 호출부가 "결과 없음"과 "실패"를 구분하지 않음.
→ **실패는 반드시 구분해서 보고할 것.** 현재 `BrowserScriptEvaluationStatus` enum 존재.

### 3-8. 동기 평가의 특성

`stringByEvaluatingJavaScriptFromString`은 **런루프를 돌려서 동기화**한다.
→ `CADisplayLink`나 반복 타이머에서 호출하면 안 됨. 호출 시점은 문서가 준비된 뒤여야 함.

---

## 4. 현재 구조

```
_Project/Browser/
├─ ViewController.m/.h            앱 호스트. 모든 코디네이터의 델리게이트
├─ BrowserWebView.m/.h            WebKit 런타임 래퍼 (dlopen + objc_msgSend)
├─ BrowserTabCoordinator.m/.h     탭·웹뷰 생애주기, 웹뷰 레이아웃
├─ BrowserMenuCoordinator.m/.h    모든 메뉴 구성
├─ BrowserTopBarView.m/.h         상단 주소줄과 아이콘
├─ BrowserRemoteInputController   리모컨: 커서, 방향키, 스크롤, 포커스 전환
├─ BrowserPageActionCoordinator   링크 클릭/새 탭 판정
├─ BrowserDOMInteractionService   DOM 히트 테스트
├─ BrowserPreferencesStore        NSUserDefaults 래퍼
├─ BrowserFavoritesStore          즐겨찾기 + 폴더
├─ BrowserContentBlockerController 광고 차단
├─ BrowserDarkModeController      강제 다크모드
├─ BrowserReaderModeController    읽기 모드
├─ BrowserNavigationService       주소 정규화
├─ BrowserSessionStore            세션 복원
├─ BrowserTabOverviewController   탭 목록 화면
└─ (그 외 보조 파일)
```

### v4.0.0에서 삭제한 것 (되살리지 말 것)

- 동영상 재생 전체: 재생 코디네이터, 네이티브 플레이어, 에셋 로더, AVPlayer 전체화면 우회, WebCore 쉼
- 시험·진단 전체: 탐침 작업대, 웹 플랫폼 탐침, 리포트 화면, 진단 로그, WKWebView 시험 화면, 미디어/스크롤 진단

---

## 5. v4.1.0에서 새로 넣은 것 — **여기를 집중 검토해 주십시오**

### 5-1. 화면 채우기 (`BrowserTabCoordinator.updateTopNavAndWebView`)

**의도**: 네이버가 1110~1275px 고정폭을 가운데 두므로, 1920 화면에서는 좌우 320px이 빈다.
페이지를 화면에 맞추는 대신 **화면을 페이지에 맞춘다** — 1280px로 레이아웃하고 1.5배 확대.

```objc
CGFloat layoutWidth = self.pageLayoutWidth;      // 기본 1280
CGFloat scale = 1.0;
if (layoutWidth > 200.0 && layoutWidth < availableWidth) {
    scale = availableWidth / layoutWidth;
} else {
    layoutWidth = availableWidth;
}

webView.transform = CGAffineTransformIdentity;
webView.bounds = CGRectMake(0.0, 0.0, layoutWidth, availableHeight / scale);
if (scale != 1.0) {
    webView.transform = CGAffineTransformMakeScale(scale, scale);
}
webView.center = CGPointMake(originX + inset + availableWidth / 2.0,
                             top + availableHeight / 2.0);
```

**검토 요청:**
- (a) 변형 + bounds/center 조합이 올바른가? frame을 쓰지 않은 것이 맞는가?
- (b) 웹뷰 내부 `UIScrollView`의 스크롤·히트테스트가 변형 아래에서 정상인가?
  **특히 리모컨 커서 좌표계** — `BrowserRemoteInputController`의 커서는 루트 뷰 좌표이고, DOM 히트테스트는 웹뷰 좌표다. **1.5배 변형이 이 변환을 깨뜨리지 않는가?** (가장 의심스러운 부분)
- (c) 래스터 업샘플링(2560 → 3840)으로 인한 선명도 저하를 피할 방법이 있는가?
  `WKWebView`의 비공개 `_setViewScale:`가 tvOS 16.6에 존재하는지, 존재한다면 변형보다 나은지.
- (d) 세로 길이를 `availableHeight / scale`로 준 것이 맞는가? 스크롤 영역이 잘리지 않는가?

### 5-2. 프린트 화면 (`ViewController.browserOpenPrintableArticle`)

```objc
// /article/{oid}/{aid}  →  /article/print/{oid}/{aid}
if (![URL.host hasSuffix:@"news.naver.com"] || [path hasPrefix:@"/article/print/"]) return NO;
NSArray *parts = [path componentsSeparatedByString:@"/"];
if (parts.count < 4 || ![parts[1] isEqualToString:@"article"]) return NO;
```

**검토 요청:**
- (e) `hasSuffix:@"news.naver.com"`은 `evilnews.naver.com` 같은 호스트도 통과시킨다. 위험한가? (여기서는 URL 생성만 하므로 영향이 제한적이라 판단했으나 의견을 듣고 싶다)
- (f) 경로 파싱이 쿼리·프래그먼트·인코딩된 경로에서 안전한가?

### 5-3. 즐겨찾기 폴더 (`BrowserFavoritesStore`)

기존 저장 형식은 `[url, title]`. 폴더는 **세 번째 요소**로 덧붙였다.

```objc
- (NSString *)folderOfEntry:(NSArray<NSString *> *)entry {
    if (![entry isKindOfClass:[NSArray class]] || entry.count < 3) return nil;
    NSString *folder = entry[2];
    return [folder isKindOfClass:[NSString class]] && folder.length > 0 ? folder : nil;
}
```

**검토 요청:**
- (g) 구버전 데이터 호환이 실제로 보장되는가? 마이그레이션 없이 안전한가?
- (h) 폴더 삭제 시 즐겨찾기를 보존하는 구현이 올바른가?

### 5-4. 상단바 아이콘 재배치 (`BrowserTopBarView`)

순서: `⭐ 별표 / AA 글자크기 / 🛡 방패 / ⚙ 설정 / ⋯ 메뉴`
전체화면 토글 아이콘은 숨김 처리(`hidden = YES`)하고 `_focusButtons` 배열에서 제외.

**검토 요청:**
- (i) 숨긴 버튼을 배열에서만 빼고 객체는 남겨둔 것이 문제가 되는가? 완전히 제거하는 편이 나은가?
- (j) 리모컨 좌우 포커스 이동 순서가 시각적 순서와 일치하는가?

---

## 6. 남아 있는 미해결 사항

1. **일부 페이지에서 스크립트 평가가 간헐적으로 실패** (`(null)` 반환). news.naver.com에서 관찰됨. 원인 미상.
2. **읽기 모드**는 잘 동작하지만 사진 배치와 관련기사 목록이 사라진다. 의도된 동작이나 개선 여지가 있는지.
3. **다크 모드를 끌 때 배경 탭이 즉시 갱신되지 않음** (탭 전환 시 자가 치유). 낮은 우선순위.

---

## 7. 검토 방식 요청

- **코드를 전부 다시 쓰지 말 것.** 위 3장의 실패 목록은 실제 기기에서 확인된 것이고, 현재 코드는 그 결과물이다.
- 지적은 **파일명·메서드명·구체적 위험 시나리오**로 해 줄 것.
- 특히 **5-1 (b) 커서 좌표계**를 최우선으로 봐 주기 바란다. 변형을 건 뒤 리모컨 커서가 어긋날 가능성이 가장 크다.
- 기기를 벽돌로 만들 수 있는 코드가 하나라도 있는지 확인해 줄 것.

## 8. 첨부 파일

소스는 네 묶음으로 나누어 두었다. 검토 항목과의 대응은 아래와 같다.

| 파일 | 크기 | 담긴 것 | 대응 검토 항목 |
|---|---|---|---|
| `SOURCE_1_LAYOUT_v4.1.0.md` | 171 KB | TabCoordinator, TopBarView, RemoteInputController, DOMInteractionService | **5-1 (a)~(d), 5-4** — 가장 중요 |
| `SOURCE_2_HOST_v4.1.0.md` | 139 KB | ViewController, MenuCoordinator, PageActionCoordinator | 5-2 (e)(f) |
| `SOURCE_3_STORAGE_v4.1.0.md` | 77 KB | WebView, FavoritesStore, PreferencesStore | 5-3 (g)(h) |
| `SOURCE_4_REST_v4.1.0.md` | 87 KB | 나머지 (맥락용) | — |

한 번에 다 넣기 어렵다면 **1번만으로도 최우선 항목(커서 좌표계)은 검토 가능하다.**
