# Hardware keyboard input for Orbrisa (in-place typing, Korean 2-set Hangul + English)

Contributed by **sojubada** — https://github.com/sojubada/TV-safari (branch `main`)

This note explains a text-input feature added on top of Orbrisa 1.1.0 Beta 1. With a Bluetooth keyboard attached, page text fields and the address bar take keys directly, so the full-screen Apple TV keyboard never opens. The feature also composes Korean (Hangul, *Dubeolsik* / 2-set layout), because tvOS gives a hardware keyboard no Korean input method of its own.

Everything is plain Objective-C, about 900 lines in two new files plus small hooks in three existing files. No new framework is linked. It builds for tvOS 15.6+ and has been tested on tvOS 16.6.

---

## 1. Why

- On tvOS, focusing a `UITextField` brings up the system's full-screen keyboard screen. With a Bluetooth keyboard this still takes over the screen, and typing a search feels like leaving the page.
- Outside that screen, a hardware keyboard produces only the Latin letters printed on the keys. **No Korean (or other CJK) input method is available to the app**, even when the user has Korean enabled in Settings. Korean users can't type their own language with a physical keyboard.
- A hardware keyboard can be read directly, though: through the Game Controller framework (`GCKeyboard`, tvOS 14+), or through UIKit presses (`UIPress.key`, tvOS 13.4+). So the app can turn keys into text itself and write that text into the page.

## 2. What the user gets

| Action | Result |
|---|---|
| Click a text field on a page (keyboard attached) | A slim typing bar appears at the bottom; letters go straight into the page's field, so suggestions and live search react immediately |
| Click the address bar (keyboard attached) | The typing bar appears at the top; Return opens the address or searches Google, the same as `openAddressOrSearch:` |
| **한/영** key (Lang1), **Caps Lock** or **Control+Space** | Toggle Korean / English; a short "한글" / "English" notice appears, and the bar shows "한" or "EN" |
| Typing in Korean | 2-set Hangul composition; the syllable in progress is **underlined and highlighted**, as in a desktop IME |
| **Option** + key in Korean mode | Types the Latin character anyway |
| **Return** | Sends: fills the field, then Enter `keydown`/`keypress`/`keyup` and `requestSubmit()` (reuses Orbrisa's `fillAndSendEditableElementAtPoint:`) |
| **Esc** or Siri Remote **Menu** | Cancels typing; what was already written stays in the field |
| **Backspace** | Removes one jamo from the syllable in progress, otherwise one visible character (composed-character aware) |
| Password fields | The bar shows bullets |
| No keyboard attached | Unchanged: Orbrisa's direct Apple TV keyboard path |
| Keyboard reported but silent for 2.5 s (asleep, or a different route) | Falls back to the Apple TV keyboard automatically |

## 3. Files

### New

| File | Role |
|---|---|
| `Orbrisa/BrowserHangulComposer.h/.m` | Pure string arithmetic over the Unicode Hangul block. Takes compatibility jamo (U+3131–U+3163) and builds syllables (U+AC00 + (cho·21 + jung)·28 + jong). No UIKit, no system calls. |
| `Orbrisa/BrowserHardwareKeyboardController.h/.m` | Reads the keyboard through two routes, maps HID key codes to characters, tracks shift/control/option, handles the language toggle, holds "settled text + composing syllable", and reports to a delegate. |

### Changed

| File | Change |
|---|---|
| `BrowserPageActionCoordinator.h/.m` | `@optional` host method `browserPageActionCoordinatorBeginHardwareTypingForFieldType:atDOMPoint:webView:existingText:`, tried before `presentDirectKeyboardForFieldType:…`. New public `presentSystemKeyboardForFieldType:atDOMPoint:webView:` (the fallback), and `fillEditableElementAtPoint:` / `fillAndSendEditableElementAtPoint:` made public. |
| `BrowserRemoteInputController.h/.m` | `@optional` host methods `browserRemoteInputControllerHardwareTypingActive` and `browserRemoteInputControllerHandleHardwareKeyPress:`. Keys are offered to the typing session first in `handlePressesEnded:`. While typing, `handlePressesBegan:` and the global Select notification are ignored. |
| `ViewController.m` | Owns the controller, the typing bar and the language notice, implements the delegate, and adds address-bar typing at the start of `showInputURLorSearchGoogle`. Menu and a click both end the session. |

The new host methods are all `@optional`, so the feature does nothing unless a host implements them.

## 4. How it works

### 4.1 Two input routes

```
                ┌────────────── Game Controller route ──────────────┐
Bluetooth  ───► │ GCKeyboard.coalesced.keyboardInput                 │
keyboard        │   .keyChangedHandler(input, button, keyCode, down) │──┐
                └────────────────────────────────────────────────────┘  │  main queue
                ┌──────────────────── UIKit route ──────────────────┐   ├──► handleResolvedKeyCode:shift:
           ───► │ -pressesEnded: → RemoteInputController             │   │        │
                │   → host → controller.handleKeyPress:(UIPress*)    │──┘        ▼
                │     uses press.key.keyCode + modifierFlags         │     settledText + composer
                └────────────────────────────────────────────────────┘           │
                                                                                 ▼
                                                     delegate didChangeText: / didSubmit / didCancel
```

- **GameController** is loaded with `dlopen` (in the same style as WebKit in `BrowserWebView.m`) and called through `objc_msgSend`, so nothing new is linked. A device without it simply reports "no keyboard".
- The keyboard is looked up **fresh each time** (`GCKeyboard.coalesced`), because one can be paired or go to sleep between two fields.
- Some systems deliver keys only through UIKit. The first real `UIPress.key` sets `sawUIKitKeyEvent`, and from then on the keyboard counts as present.
- **No double input.** While the GC handler is live, UIKit presses are *swallowed* (`handleKeyPress:` returns YES) rather than processed again. Otherwise every letter would be doubled, and Return would also arrive as `UIPressTypeSelect` and click the page under the pointer.
- For **0.4 s after a session ends**, keyboard presses are still swallowed. The Return or Esc that ended typing can still be on its way through UIKit, and it must not then click or go back.
- Siri Remote presses have `press.key == nil` and are never touched.

### 4.2 Key mapping

Key codes are USB HID usage IDs, which are the values `GCKeyCode` and `UIKeyboardHIDUsage` use:

- `0x04–0x1D` a–z, `0x1E–0x27` 1–0 (shifted `!@#$%^&*()`), `0x2C` space, `0x2D–0x38` punctuation (US layout, unshifted/shifted tables)
- `0x28` / `0x58` Return / keypad Enter → submit, `0x29` Esc → cancel, `0x2A` Backspace
- `0x90` Lang1 (한/영), `0x39` Caps Lock, or Control+Space → toggle language
- Modifiers on their own (`0xE0–0xE7`) are consumed so they don't move the pointer. Control/Command chords are otherwise ignored.

### 4.3 Hangul composition (`BrowserHangulComposer`)

- Latin key → jamo via the standard 2-set map (`r`→ㄱ, `R`→ㄲ, `k`→ㅏ, …).
- State is `choIndex` (19 initials), `jungIndex` (21 medials) and `jongIndex` (28 finals, 0 = none). `composingText` is computed from these.
- Rules: compound vowels (ㅗ+ㅏ→ㅘ, ㅜ+ㅓ→ㅝ, ㅡ+ㅣ→ㅢ …) and compound finals (ㄱ+ㅅ→ㄳ, ㄹ+ㄱ→ㄺ …). A vowel after a final takes the final with it as the next initial (간 + ㅏ → 가 + 나), and a compound final splits (닭 + ㅏ → 달 + 가). Backspace undoes one jamo at a time.
- `inputJamo:` returns any text that has **settled**. The controller appends it to `settledText`, and the visible text is `settledText + composingText`.

### 4.4 Writing into the page

- On start, the field is focused with the existing `browserEditableTarget()` helper, so the page shows the caret and reacts to it.
- Text changes are debounced by **0.25 s**, then written with `value = …` (or `textContent` for contenteditable), followed by `setSelectionRange(end, end)` and an `input` event. Only `input` is fired while typing, so sites that search on `change` don't fire on every key.
- **Submit** reuses Orbrisa's `fillAndSendEditableElementAtPoint:` (Enter key events, then `requestSubmit()`).
- **Navigation guard:** the page URL is remembered when typing starts. If the page has changed (a search was sent), the pending text is dropped instead of being written into whatever field now sits at the same spot.
- The address bar never touches the page. Its text stays in the controller, and Return calls `openAddressOrSearch:`.

### 4.5 Typing bar

A plain `UIView` + two `UILabel`s, non-interactive: language badge on the left, text on the right, head-truncated. The composing syllable gets `NSUnderlineStyleSingle` and a yellow foreground. Page fields show the bar near the bottom, so it stays clear of the page's own suggestion lists under the field. The address bar shows it near the top.

## 5. Notes for tvOS 16 (found while backporting)

These are not part of the input feature, but came up while getting Orbrisa running on tvOS 16.6 and may be useful upstream.

1. **`registerForTraitChanges:` is tvOS 17+.** `ViewController viewDidLoad` and `BrowserMenuToggleView` call it unguarded. On tvOS 16 that is an unrecognized selector, and the app ends at launch. The fix is to guard it with `@available(tvOS 17.0, *)` and add a `traitCollectionDidChange:` fallback. Building with `TVOS_DEPLOYMENT_TARGET=15.6` shows both as `-Wunguarded-availability-new` warnings.
2. **The `_privacyStance` shim never applies.** `BrowserPrivacyStanceShim +load` runs before WebKit is `dlopen`'ed, so `WebCoreNSURLSessionTaskTransactionMetrics` doesn't exist yet and the shim returns early. The fix is to make the install a C function (`BrowserInstallPrivacyStanceShim()`), keep calling it from `+load`, and call it again at the end of `BrowserEnsureWebKitRuntimeLoaded()`. On tvOS 16, AVFoundation calls `-_privacyStance` on that class and the web content process dies when media plays (cf. jvanakker/tvOSBrowser issue #54 / PR #58).
3. Lowering `TVOS_DEPLOYMENT_TARGET` to 15.6 for both targets was otherwise enough. The Liquid Glass code is already guarded with `@available(tvOS 26.0, *)`, and VLCKit 4 declares tvOS 12.

## 6. Known limits / ideas

- **The caret is always at the end of the text.** Arrow keys are consumed but don't move the caret, and there is no mid-text editing or selection.
- No clipboard (Cmd+V) and no Hanja conversion.
- Korean only. The composer is self-contained, so other layouts (Japanese kana, 3-set Hangul) could be added the same way.
- The bar's strings ("한", "EN", "한글", "English", the address placeholder) are hard-coded. They should go through `BrowserLocalized` and the `en`/`de` string files if this is adopted.
- contenteditable fields are written with `textContent`, which drops inline formatting.
- The language choice isn't saved between launches; it could go into `BrowserPreferencesStore`.

## 7. How to test

1. Pair a Bluetooth keyboard with the Apple TV.
2. Open google.com, then click the search box. The bar should appear at the bottom, with no system keyboard.
3. Type `dkssudgktpdy` in Korean mode and check that it reads **안녕하세요**; `ekfr` + `k` should give **달가**.
4. Press Return. The search should be sent, and nothing under the pointer should be clicked.
5. Click the address bar, type `apple.com` and press Return. The site should open; Korean text should search Google instead.
6. Unpair the keyboard and click a field. The Apple TV keyboard should open, as in stock Orbrisa.

## 8. Diff

All changes are in https://github.com/sojubada/TV-safari, in the commit "Type with a Bluetooth keyboard in place: 두벌식 Hangul and English" (on top of the tvOS 16 backport commits). The code is offered back under whatever license you choose for Orbrisa. Feel free to take, change or drop any of it.
