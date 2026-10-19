# 작업 8 — 광고·콘텐츠 차단 (Gemini 전달용)

> **사용법**: `=== 여기부터 복사 ===` 아래를 Gemini에 붙여넣고, 제가 그때 만들어 드리는 **소스 번들 파일을 함께 첨부**하십시오.
> 번들은 작업 직전에 최신 코드로 새로 만듭니다.

---

=== 여기부터 복사 ===

# 작업 의뢰: tvOS 브라우저 — 광고·콘텐츠 차단

당신은 tvOS 네이티브 앱을 수정하는 Objective-C 개발자입니다. 첨부한 소스 번들이 **현재 저장소의 실제 원본**입니다. 그 내용만을 사실로 삼고, 존재하지 않는 API나 파일을 지어내지 마십시오.

## 공통 제약 — 반드시 지킬 것

1. **Objective-C(ARC)만.** Swift / SwiftUI 금지.
2. **서드파티 라이브러리, CocoaPods, SPM 금지.**
3. **`project.pbxproj`, `Info.plist`, 워크플로 YAML, 스토리보드를 수정하지 마십시오.** 새 소스 파일은 만들어도 되고, 만들었다면 목록을 결과 맨 앞에 적으십시오.
4. **새 프레임워크 링크 금지.** Foundation과 UIKit만 링크되어 있습니다. WebKit은 `dlopen` + `NSClassFromString` + `objc_msgSend`로만 접근합니다.
5. **tvOS에 없는 API 금지.** `UIPasteboard`는 tvOS에 없습니다.
6. **기존 동작 회귀 금지.** 커서/스크롤 모드 토글, 터치=현재 탭·클릭=새 탭, Menu=뒤로가기, PlayPause 1회/2회, 탭 오버뷰(최대 5탭), 상단바 포커스, 네이티브 비디오 플레이어, 방향패드·엣지 스크롤과 JS 스크롤 폴백.
7. 새 기능은 `BrowserPreferencesStore`에 설정을 추가하고 고급 메뉴에 토글을 넣으십시오.
8. 코드 스타일은 기존대로.
9. **동기 JS 평가는 런루프를 돌립니다.** 반복 타이머나 `CADisplayLink`에서 호출하지 마십시오.

## 이 작업의 내용

TV에서 커서로 웹을 보면 광고가 특히 거슬립니다. 광고와 추적 스크립트를 차단합니다.

### 먼저 알아야 할 제약 — 설계의 핵심

`WKContentRuleList`는 WebKit의 콘텐츠 차단 기능이지만, **애플 문서의 지원 플랫폼 목록에 tvOS가 없습니다.** 이 앱은 tvOS에 공개되지 않은 WebKit을 런타임으로 끌어다 쓰고 있어서 `WKContentRuleListStore`도 실제로는 존재할 가능성이 높지만, **보장되지 않습니다.**

그래서 **두 경로를 모두 구현하고 자동으로 떨어지게** 만드십시오.

- **1순위 — 규칙 목록 차단**: `WKContentRuleListStore`가 런타임에 있으면 사용. 네트워크 요청 자체를 막아 가장 효과적입니다.
- **2순위 — JS 외형 차단**: 1순위를 쓸 수 없으면 광고 요소를 CSS/JS로 숨깁니다. 요청은 나가지만 화면은 깨끗해집니다.

**1순위가 없다고 기능을 포기하지 마십시오. 2순위는 반드시 동작해야 합니다.**

### 요구사항

**1. 새 클래스 `BrowserContentBlockerController`** (`.h`/`.m`)

규칙 JSON 보관, 컴파일, 적용, 폴백 주입, 진단 정보 제공을 담당합니다.

**2. 차단 규칙은 직접 작성하십시오 — 중요**

EasyList, uBlock Origin 등 **기존 필터 목록을 가져다 쓰지 마십시오.** 라이선스 문제가 있습니다. 직접 작성한 규칙만 쓰십시오.

- 규모는 **60~150개**. 그 이상 늘리지 마십시오.
- 널리 알려진 광고·추적 도메인(구글 광고, 각종 애드 네트워크, 분석 스크립트)과, 광고 컨테이너에 흔히 쓰이는 class/id 선택자를 대상으로 하십시오.
- 형식은 WebKit 콘텐츠 차단 규칙 JSON입니다.
  ```json
  [
    {"trigger":{"url-filter":"example-ads\\.com"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad-banner"}}
  ]
  ```
- **보수적으로 작성하십시오.** 과차단으로 멀쩡한 사이트가 깨지는 쪽이 광고가 조금 남는 쪽보다 나쁩니다. `url-filter`에 `.*`만 쓰는 차단 규칙처럼 광범위한 것은 넣지 마십시오.
- 규칙 문자열은 상수로 두고, 내용을 바꿀 때마다 식별자의 버전을 올리도록 하십시오(`BrowserAdBlockRules-v1`). 식별자가 같으면 WebKit이 예전 컴파일 결과를 재사용합니다.

**3. 1순위 경로 — 규칙 목록**

- `WKContentRuleListStore`를 `NSClassFromString`으로 찾고, `defaultStore`와 `compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:`에 `respondsToSelector:`로 확인한 뒤 호출하십시오. 하나라도 없으면 즉시 2순위로 떨어지십시오.
- 앱 시작 시 **한 번만** 컴파일하고 결과 객체를 보관합니다. 페이지마다 컴파일하지 마십시오.
- 적용: 웹뷰 설정의 `userContentController`에 `addContentRuleList:`. 웹뷰 생성은 `BrowserWebView` 안에서 일어나므로, `BrowserWebView`에 컴파일된 목록을 넘겨 두고 새 웹뷰를 만들 때 적용하는 경로를 만드십시오(예: 클래스 레벨 저장소 + 생성 시 적용). 기존 `BrowserInstallYouTubeCaptureUserScript`가 설정 객체를 다루는 방식을 참고하십시오.
- 설정을 끄면 `removeAllContentRuleLists`로 해제하십시오.

**4. 2순위 경로 — JS 외형 차단**

- 1순위를 쓸 수 없거나 컴파일이 실패하면 사용합니다.
- `webViewDidFinishLoad:`에서 한 번 주입하고, **1초 뒤 한 번 더** 실행하십시오(지연 삽입되는 광고 대응). 그 이상 반복하지 마십시오.
- 동작: 광고 선택자에 해당하는 요소를 `display:none`으로 숨기고, 광고 도메인을 가리키는 `iframe`을 제거합니다.
- 숨긴 요소 개수를 세어 돌려주고, 진단에 쓰십시오.
- `MutationObserver`를 무한히 돌리지 마십시오. 느려집니다.

**5. 진단 메뉴**

고급 메뉴 `Diagnostics` 섹션에 `Content Blocker Diagnostics`를 추가하고 다음을 Alert로 보여주십시오. 1순위가 실제로 동작하는지 기기에서 확인할 유일한 수단이므로 반드시 넣으십시오.

- `WKContentRuleListStore` 클래스 발견 여부
- 컴파일 시도 결과(성공 / 실패 사유 / 시도 안 함)
- 현재 적용 경로(규칙 목록 / JS 외형 차단 / 꺼짐)
- 규칙 개수
- 현재 페이지에서 JS로 숨긴 요소 수

**6. 설정과 메뉴**

- `BrowserPreferencesStore`에 `contentBlockingEnabled` 추가, 기본값 **YES**.
- 고급 메뉴에 토글 추가(`Content Blocking: On` / `Off`). 끄면 두 경로 모두 비활성화되고, 다음 로드부터 원래대로 보여야 합니다.

## 결과물 제출 형식

1. **수정한 파일은 전체 내용을 출력하십시오.** 생략 표기 금지.
2. 각 파일 앞에 `FILE: _Project/Browser/<파일명>` 한 줄, 다음 줄부터 ```objc 블록.
3. 맨 앞에 세 가지 요약 — 새로 추가한 파일 / 수정한 기존 파일 / 영향받는 기존 동작.
4. 맨 뒤에 기기 테스트 절차.
5. 자가 점검 — 런타임 조회한 클래스·셀렉터마다 nil 검사를 했는가 / `objc_msgSend` 캐스팅의 인자 타입이 맞는가 / 비동기 컴파일 완료 처리에서 순환 참조가 없는가 / 규칙 JSON이 올바른 JSON이고 Objective-C 문자열 안에서 이스케이프가 맞는가.

## 기기 테스트 절차 (아래를 포함해 보강할 것)

1. 광고가 많은 뉴스 사이트를 열어 적용 전후 비교
2. `Content Blocker Diagnostics` 실행 → 어느 경로로 동작 중인지 확인
3. 규칙 목록 경로가 동작한다면 배너가 **자리까지 사라지는지**(요청 차단), JS 경로면 자리만 비는지 확인
4. 끄기 → 새로고침 → 광고가 다시 보이는가
5. 자주 쓰는 사이트 5곳을 돌며 **레이아웃이 깨지거나 버튼이 사라진 곳이 없는지** 확인
6. 동영상 사이트에서 재생이 정상인지 확인 — 재생 스크립트를 잘못 막지 않았는지
7. 로그인이 필요한 사이트에서 로그인이 되는지
8. 탭을 5개까지 열어도 느려지지 않는지
9. 스크롤·클릭·새 탭 등 기존 동작 유지 확인

=== 여기까지 복사 ===
