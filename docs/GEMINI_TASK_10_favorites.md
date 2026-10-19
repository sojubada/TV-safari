# 작업 10 — 즐겨찾기 설정/해제 (Gemini 전달용)

> **사용법**: `=== 여기부터 복사 ===` 아래를 Gemini에 붙여넣고, 제가 그때 만들어 드리는 **소스 번들 파일을 함께 첨부**하십시오.
>
> **이 작업은 11번(시작 페이지)과 12번(링크 길게 눌러 메뉴)의 토대입니다.** 두 작업 모두 여기서 만드는 저장소를 씁니다. 반드시 이 작업을 먼저 끝내십시오.

---

=== 여기부터 복사 ===

# 작업 의뢰: tvOS 브라우저 — 즐겨찾기 저장소 분리와 설정/해제 토글

당신은 tvOS 네이티브 앱을 수정하는 Objective-C 개발자입니다. 첨부한 소스 번들이 **현재 저장소의 실제 원본**입니다. 그 내용만을 사실로 삼고, 존재하지 않는 API나 파일을 지어내지 마십시오.

## 공통 제약 — 반드시 지킬 것

1. **Objective-C(ARC)만.** Swift / SwiftUI 금지.
2. **서드파티 라이브러리, CocoaPods, SPM 금지.**
3. **`project.pbxproj`, `Info.plist`, 워크플로 YAML, 스토리보드를 수정하지 마십시오.** 새 소스 파일은 만들어도 되고, 만들었다면 목록을 결과 맨 앞에 적으십시오.
4. **새 프레임워크 링크 금지.** Foundation과 UIKit만 링크되어 있습니다.
5. **tvOS에 없는 API 금지.** `UIPasteboard`는 tvOS에 없습니다.
6. **기존 동작 회귀 금지.** 커서/스크롤 모드 토글, 터치=현재 탭·클릭=새 탭, Menu=뒤로가기, PlayPause 1회/2회, 탭 오버뷰(최대 5탭), 상단바 포커스, 네이티브 비디오 플레이어, 방향패드·엣지 스크롤과 JS 스크롤 폴백.
7. 코드 스타일은 기존대로.

## 이 작업의 내용

지금은 즐겨찾기를 고급 메뉴 안에서만 다룰 수 있고, 저장·삭제 로직이 `BrowserMenuCoordinator` 안에 흩어져 있습니다. 보고 있는 페이지를 한 번에 즐겨찾기에 넣고 빼는 동작이 없습니다.

### 현재 저장 형식 — 절대 바꾸지 마십시오

`NSUserDefaults`의 `"FAVORITES"` 키에 **배열의 배열**로 저장됩니다.

```objc
@[ @[@"https://example.com", @"사이트 제목"], ... ]   // [0]=URL, [1]=제목
```

기기에 이미 저장된 즐겨찾기가 있습니다. **형식을 딕셔너리 등으로 바꾸면 기존 데이터가 전부 사라집니다.** 마이그레이션 코드를 쓰지 말고, 이 배열 형식을 그대로 유지하십시오.

### 요구사항

**1. 새 클래스 `BrowserFavoritesStore`** (`.h`/`.m`)

흩어진 즐겨찾기 로직을 모읍니다. 공개 API는 아래와 같이 만드십시오. **작업 11과 12가 이 API를 그대로 쓰므로 이름과 시그니처를 바꾸지 마십시오.**

```objc
// 저장된 순서대로. 각 항목은 @[URL문자열, 제목문자열] 형태의 NSArray.
- (NSArray<NSArray<NSString *> *> *)favorites;

- (BOOL)isFavoriteURLString:(nullable NSString *)URLString;
- (void)addFavoriteWithURLString:(nullable NSString *)URLString title:(nullable NSString *)title;
- (void)removeFavoriteWithURLString:(nullable NSString *)URLString;
- (void)removeFavoriteAtIndex:(NSInteger)index;
- (NSUInteger)count;
```

**2. URL 비교 정규화**

같은 페이지인데 즐겨찾기 상태가 다르게 보이면 안 됩니다. 비교할 때만 아래를 적용하고, **저장은 원본 URL 그대로** 하십시오.

- 끝의 `/` 하나 제거
- 호스트(scheme과 도메인 부분)만 소문자로. 경로·쿼리의 대소문자는 유지
- 프래그먼트(`#...`) 제거
- `http`와 `https`는 **다른 주소로 취급**(보안상 구분이 맞습니다)

**3. 중복 방지**

`addFavoriteWithURLString:title:`는 이미 있는 주소면 아무것도 하지 말고 조용히 끝내십시오. 중복 항목을 만들지 마십시오. 제목이 비어 있으면 URL을 제목으로 쓰십시오.

**4. 고급 메뉴에 설정/해제 토글 추가**

`Navigation` 섹션, 기존 `Favorites` 항목 바로 위에 넣으십시오.

- 현재 페이지가 즐겨찾기에 **없으면** 제목 `Add to Favorites` → 선택하면 현재 URL과 페이지 제목으로 추가
- **있으면** 제목 `Remove from Favorites` → 선택하면 삭제
- 현재 URL이 비어 있거나(빈 탭, 시작 페이지) 즐겨찾기로 삼을 수 없으면 이 항목을 아예 넣지 마십시오

메뉴 제목은 메뉴를 열 때마다 현재 URL을 보고 결정됩니다. 기존 토글 항목들과 같은 방식으로 만드십시오.

**5. 기존 즐겨찾기 메뉴를 새 저장소로 옮기기**

`BrowserMenuCoordinator`의 `presentFavoritesMenu`, `presentAddFavoritePrompt`, `presentDeleteFavoriteMenu`, `saveFavoritesArray`가 `NSUserDefaults`를 직접 건드리고 있습니다. 전부 `BrowserFavoritesStore`를 거치도록 바꾸되, **사용자에게 보이는 동작은 그대로 두십시오.** 메뉴 구성과 문구를 바꾸지 마십시오.

**6. 상단바에는 손대지 마십시오**

상단바에 별 버튼을 넣고 싶을 수 있지만, 새 아이콘 자산과 프로젝트 파일 등록이 필요해 이번 범위 밖입니다. `BrowserTopBarView`와 `BrowserTopBarAction`을 수정하지 마십시오.

**7. 설정 값 없음**

켜고 끄는 기능이 아니므로 `BrowserPreferencesStore`에 값을 추가하지 마십시오.

## 결과물 제출 형식

1. **수정한 파일은 전체 내용을 출력하십시오.** 생략 표기 금지.
2. 각 파일 앞에 `FILE: _Project/Browser/<파일명>` 한 줄, 다음 줄부터 ```objc 블록.
3. 맨 앞에 세 가지 요약 — 새로 추가한 파일 / 수정한 기존 파일 / 영향받는 기존 동작.
4. 맨 뒤에 기기 테스트 절차.
5. 자가 점검 — 저장 형식이 `@[URL, 제목]` 배열 그대로인가 / 기존 즐겨찾기 메뉴의 문구와 흐름이 그대로인가 / 헤더에 없는 메서드를 외부에서 부르지 않는가 / 블록 순환 참조 / `NS_ASSUME_NONNULL` 구간의 nullable 표기.

## 기기 테스트 절차 (아래를 포함해 보강할 것)

1. **기존에 저장해 둔 즐겨찾기가 그대로 보이는가** — 가장 먼저 확인할 항목입니다
2. 아무 페이지에서 고급 메뉴 → `Add to Favorites` → 추가되는가
3. 같은 페이지에서 메뉴를 다시 열면 제목이 `Remove from Favorites`로 바뀌어 있는가
4. 선택해서 삭제 → 다시 `Add to Favorites`로 돌아오는가
5. 같은 페이지를 끝에 `/`를 붙이거나 떼고 열어도 **즐겨찾기 상태가 똑같이 인식**되는가
6. 같은 페이지를 두 번 추가 시도 → 중복 항목이 생기지 않는가
7. 기존 `Favorites` 메뉴에서 목록 열기 / 항목 선택해 이동 / 개별 삭제 / 현재 페이지 추가가 모두 전처럼 되는가
8. 앱을 완전히 껐다 켜도 즐겨찾기가 유지되는가
9. 빈 탭이나 로드 실패 페이지에서 메뉴를 열면 토글 항목이 보이지 않는가
10. 기존 동작(모드 토글, 새 탭, 뒤로가기, 탭 오버뷰) 유지 확인

=== 여기까지 복사 ===
