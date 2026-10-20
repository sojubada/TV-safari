# 탐침 사용법 — v2.8.0

IPA: `tvOSBrowser-2.8.0-unsigned.ipa`
SHA-256: `f62c9666a946c031a78790fd4ce4e0599712a25a67b4f2a79c78e39de458a9a3`

**⋯ → `Web Platform Probe`** 아래 세 항목입니다. 번호 순서대로 하십시오.
AirDrop 때 쓴 방식과 같습니다 — 프레임워크 → 클래스 → 기능 순으로 좁혀 갑니다.

---

## 순서 1 — 아무 평범한 사이트에서 기준선 잡기

네이버 뉴스처럼 **잘 되는** 페이지를 띄워 놓고 찍으십시오. 고장난 데서 먼저 재면 무엇이 정상인지 몰라 비교가 안 됩니다.

- [ ] A. `1. WebKit Runtime` → 사진
- [ ] B. `2. Engine Capabilities` → 사진 (스크롤해서 **전부**)
- [ ] C. `3. Page Script Errors` → 사진

### A에서 제가 보는 것

| 줄 | 뜻 |
|---|---|
| `web content pid` vs `app pid` | **다르면** JS가 WebKit 자체 프로세스에서 돕니다. 그러면 JIT·샌드박스가 우리 앱 권한과 무관해지고, TrollStore 권한으로 건드릴 수 있는 게 거의 없다는 뜻입니다 |
| `[o] setInspectable:` | 맥 Safari 개발자 메뉴로 붙을 길이 열립니다 |
| `[o] _setMediaSourceEnabled:` | 동영상 스트리밍(MSE)을 켤 수 있는지 |
| `[o] WKContentRuleListStore` | 광고 차단이 규칙 목록으로 도는지 JS 폴백인지 확정 |

### B에서 제가 보는 것

`syntax` 절이 핵심입니다. `optional chaining`·`class fields`·`static blocks` 중 **하나라도 `no`면** 요즘 사이트는 파싱 단계에서 죽습니다. 그게 백지의 원인이면 우리가 고칠 수 있는 게 아니라 **엔진 세대 문제**로 확정됩니다.

`customElements`가 `no`면 유튜브는 구조상 불가능합니다. 유튜브 UI가 전부 Web Components입니다.

`media` 절은 어떤 코덱이 되는지를 보여 줍니다. `MSE video/mp4 avc1`이 `yes`면 유튜브 재생의 길이 있고, 전부 `no`면 외부 플레이어 말고는 답이 없다는 뜻입니다.

---

## 순서 2 — 유튜브에서 같은 세 장

- [ ] D. 유튜브를 띄우고 **백지가 된 상태에서** `3. Page Script Errors` → 사진
- [ ] E. 같은 상태에서 `2. Engine Capabilities` → 사진

**D가 이번 탐침의 핵심입니다.** 지금까지 백지의 원인을 추측으로만 좁혀 왔는데, 이제 페이지가 스스로 무엇이 틀어졌는지 말해 줍니다.

읽는 법:

| 보이는 것 | 뜻 |
|---|---|
| `CAPTURE NOT INSTALLED` | 주입 자체가 실패. 그 자체로 큰 단서 |
| `body children: 0` | 페이지가 아무것도 못 그림 |
| `scripts: 0` | 스크립트가 아예 안 옴 — 네트워크나 차단 문제 |
| `scripts: 50` 인데 `body children: 0` | 스크립트는 왔는데 실행에서 죽음 — 아래 에러 목록이 답 |
| `error: ... @...js:...` | **파일 이름과 줄 번호.** 여기가 진짜 원인 |
| `load: SCRIPT https://...` | 그 파일을 못 받음 — 차단이 범인 |
| `No script errors recorded` | 에러 없이 비어 있음 = 렌더링 쪽 문제 |

---

## 순서 3 — 변수 하나씩 끄며 D 반복

D에서 에러가 잡히면 아래는 안 하셔도 됩니다. 안 잡힐 때만 하십시오.

- [ ] F. `방패 → Content Blocking` 끄고 새로고침 → D 다시
- [ ] G. `기어 → User Agent`를 모바일로 바꾸고 → D 다시
- [ ] H. `기어 → YouTube Capture Hook`을 **켜고** → D 다시 (켜면 더 나빠지는지 확인)

---

## 참고 — 이번에 확인된 제약

지난 AirDrop 작업에서 나온 사실이 여기에도 그대로 걸립니다.

TrollStore가 **넣어 주지 못하는 권한이 세 가지**인데, 그중 `dynamic-codesigning`이 **JIT 권한**입니다. 즉 우리 앱 바이너리는 자바스크립트를 기계어로 컴파일할 수 없습니다.

다만 A의 `web content pid`가 우리 앱과 **다르게** 나오면 이야기가 달라집니다. 그 경우 JS는 애플이 서명한 WebKit 프로세스에서 돌고, JIT 여부는 그쪽 권한이 정하므로 우리 제약과 무관합니다. **A 한 줄로 갈립니다.**

크로미움 같은 다른 엔진을 올리는 길은 없습니다. JIT 없이 인터프리터로만 돌리면 지금 WebKit보다 느리고 호환성도 나빠집니다.
