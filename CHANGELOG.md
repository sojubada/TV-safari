# Changelog

All notable changes to Orbrisa. The format follows [Keep a Changelog](https://keepachangelog.com), versions follow [Semantic Versioning](https://semver.org).

## [1.4.1] – 2026-11-25

### Fixed
- **YouTube: ask the way SmartTubeIOS does on tvOS** (milika/SmartTubeIOS, the AVPlayer port of SmartTube):
  - every player request now carries `html5Preference: HTML5_PREF_WANTS`; without it YouTube answers with SABR only, which is why `web` and `web_safari` had "no playable hls or muxed format" in the 1.3.9 log;
  - new first client `visionos` (VISIONOS 1.02), asked after one ordinary watch-page visit (consent cookie, Safari identity): HLS, H.264 up to 1080p, no PO token;
  - new `web_embedded` (WEB_EMBEDDED_PLAYER) with the embedding page (`thirdParty.embedUrl`) it needs;
  - the page's visitor data is sent inside the client context too.
- Order: visionos → web_safari → mweb → web_embedded → android_vr → ios → tv.

### Added
- **Bluetooth mouse** through the ESP32-C3 relay (sojubada/rd4tvos, `firmware/x1bridge`), which re-sends a BLE mouse as a Citrix X1 mouse (service `2B080000-BDB5-F6EB-24AE-9D6AB282AB63`). The browser is the central and connects on its own; nothing is paired in tvOS Settings.
  - movement drives the same pointer as the clickpad; the bar is reached by pointing at it, no snapping;
  - left click = click at the pointer (bar buttons included), right = Back / close, middle = page menu, wheel = scroll (page or the box under the pointer);
  - settings: `BrowserX1MouseEnabled` (default on; off means no Bluetooth use at all), `BrowserX1MouseSpeed` (default 1.0);
  - diagnostics category `Input`: Bluetooth state, scan, found (name, RSSI), connect/disconnect with error, report references, first raw reports, button edges, 30 s counters (reports, clicks, travel).
  - `NSBluetoothAlwaysUsageDescription` added (required before any CoreBluetooth use).

## [1.4.0] – 2026-11-25

### Diagnostics (DiagLog)
- Structured log after the DiagLog guideline: categories Lifecycle / Network / Storage / UI / Media, levels INFO / WARN / ERR, a trace id per playback attempt, errors with `domain= code= msg=`. Each line goes to the unified system log (os_log, subsystem = bundle id) and to `orbrisa-diag.log`.
- Recorded without per-bug code: every alert the viewer sees (title, message, buttons); the page's own video lines (video elements, events, requests, streams found); the Apple TV player's events and a closing summary (position, watched time, stalls, bitrate, live/VOD, host); what YouTube returned to each client (HLS / DASH / SABR / formats / ciphered); when no video is found, an inventory of the page (video elements and their state, frames, recent media requests, player elements).
- System chatter in stderr (AVKit "Attachment range", CATransformLayer, nib images) is counted, not copied.

### Fixed
- **YouTube:** client identities brought up to date (yt-dlp, July 2026). `web_safari` and `mweb` come first because they return HLS, which needs no PO token at present and is what the Apple TV player plays; then `android_vr`, `ios` 21.26.4, `tv` 7.20260707. The dead `tv_embedded` is gone. App clients no longer get browser cookies; a stream is fetched with the identity of the client that asked for it.
- **YouTube:** one press started three or four extractions at once (four identical error boxes). One at a time per video now.
- **Naver news VOD (JTBC etc.):** the stream list arrives as JSON when the player starts and never appears in a `<video>`. JSON answers from player/VOD addresses are scanned for `.m3u8` / `.mp4`.

## [1.3.9] – 2026-11-24

### Fixed
- **Ad blocking and site storage now use `Caches`.** tvOS lets an app write only to `Caches` and `tmp`; the 1.3.8 log showed `Application Support` refused as well (`siteData=default (no folder set)`, `adblock own store unavailable`, WebKit compile error 6). Both now live in `Caches/BrowserContentRules` and `Caches/BrowserWebsiteData`. The log gives the reason when a folder cannot be made.
- **YouTube extractor actually asks YouTube.** It read the page settings from `ytcfg.data_`, which was empty (`apiKey=no clientVersion=`), and then skipped every player request because there was no key, without a word in the log. It now reads them through `ytcfg.get(…)` or the page source, and sends the request without a key when none is found.
- The log now records each player request, its answer, and the final failure shown to the viewer (`yt-extract FAILED …`).

## [1.3.8] – 2026-11-23

### Fixed
- **YouTube: every way into the player uses the extractor.** In 1.3.7 only *Full Screen* did; *Choose Video* and selecting the video handed the page's own stream over (log: `-1002` in the Apple TV player, VLC "missing avcC" with no picture). On a YouTube video page, *Full Screen*, *Choose Video*, selecting the video and *Play Active Video* now all ask YouTube for the video itself. The log names the path taken (`play-path`).
- **VLC no longer sits on a black screen.** It reported "playing" while it decoded nothing, so the 20 s check never fired. The check now looks at whether a picture exists, then shows the error and logs `vlc no picture after 20s`.
- **Ad blocking actually runs.** WebKit could not save the compiled list in `Library/WebKit` ("Moving file failed" on every launch). The list now lives in the app's own `Application Support/BrowserContentRules`; the log says `adblock compiled` / `rule list loaded`. The first launch compiles, blocking starts from the next launch.
- **Site storage works.** LocalStorage, IndexedDB, MediaKeys and the other site folders could not be created in `Library/WebKit/WebsiteData` (`Code=513`). All tabs now share one website data store in `Application Support/BrowserWebsiteData`; the log shows `storage siteData=own(n)`. Cookies stay where they were, so sign-ins are kept. Site data saved before this version (if any) is not carried over.

## [1.3.7] – 2026-11-23

### Fixed
- **YouTube video stopped at 0:00 (page shows only the thumbnail and "Skip ad")**: *Full Screen* handed the page's own stream (HTTP 404 in the Apple TV player, the player shows `-1011`) to the player. On a YouTube watch page it now asks YouTube for the video itself through the extractor, which does not carry the advert. If the page's manifest is refused, the extractor tries the other player clients instead of giving up.

## [1.3.6] – 2026-11-22

### Fixed
- The VLC player no longer spins at 0:00 for ever: after 20 s without picture it shows the error and writes `vlc` lines (state, host) to the diagnostics log.

## [1.3.5] – 2026-11-19

### Fixed
- **YouTube page went blank and the web process died every few seconds** (log: deaths=1..12 on youtube.com / m.youtube.com, none on Naver). YouTube pages now run without in-page media (AVFoundation); its videos are played by the native extractor as before. Other sites keep Play Media Inside Pages.

### Changed
- The diagnostics log now records the YouTube extractor steps (`yt-extract`) and why the Apple TV player handed a stream to VLC (`native-fail`), query strings removed.

## [1.3.4] – 2026-11-18

### Fixed
- **Videos did not play** (YouTube "Your browser can't play this video", Naver News "재생할 수 없는 영상입니다"): tvOS 16 WebKit cannot play page videos itself. *Fullscreen video playback*, which hands a selected video to the native player, was off by default; it is now on, and YouTube's native extraction is enabled. Select the video with the cursor to play it.

### Changed
- The exit button quits at once, without asking.

## [1.3.3] – 2026-11-18

### Fixed
- **YouTube showed text without thumbnails or layout**: youtube.com now always loads the phone page (built-in entry in the phone-page host list).

## [1.3.2] – 2026-11-18

### Changed
- **Housekeeping at launch**: WebKit's network cache (Caches/WebKit/NetworkCache) is emptied once it passes 40 MB, other cache folders and tmp once they pass 20 MB. Only cache files are removed; logins, cookies, favorites and the log are kept.

## [1.3.1] – 2026-11-17

### Fixed
- **Videos on YouTube and Naver News did not appear**: *Play Media Inside Pages* was off unless switched on by hand. It is now on by default (a stored choice is kept); Settings > Video Playback still turns it off.

## [1.3.0] – 2026-11-17

Safety release, guided by Google's Modern Web Guidance (privacy, security and performance parts; no UI changes except the exit button).

### Added
- **Exit button** at the left end of the top bar (asks for confirmation, then saves cookies and quits)

### Changed
- Addresses typed without a scheme use **HTTPS first**, with a single http retry if the secure connection fails
- Cookie banners are **no longer accepted automatically** by default (opt-in in Settings)
- Diagnostic log keeps scheme, host and path only: **no query strings or fragments**
- Video playback requests send only the **origin** as Referer
- Reader extraction is bounded (1500 paragraphs, 300 ms) so a huge page cannot stall the page thread

## [1.1.0-beta.1] – 2026-11-05

**Beta 1** – try the new Reader and RSS feeds. Things may still change; please report anything odd.

### Added
- **Reader mode** – only the article, no ads or menus. Calm, large text you scroll with the touch surface
  - *Reader* button right inside the address bar as soon as a page has an article (found while the page is still loading)
  - Appearance panel (Play/Pause): font size in five steps, background *Light*, *Sepia*, *Grey* or *Dark*, font *Serif* or *System*
  - *Always Open in Reader* per website – articles of that site open straight in the Reader
  - Images of the article are shown in the text
- **RSS feeds**
  - RSS button next to the address bar: orange when the page has a feed (subscribe in one click), grey otherwise (opens your feeds)
  - Feeds overview below the top bar, like the tab overview – the address bar reads *Feeds* and the number of new articles
  - Sidebar with all subscribed feeds and unread counts, *All* / *Unread* filter, article cards with picture
  - *Add Feed* finds the feed of the page you are on; Play/Pause on a feed unsubscribes
  - RSS and Atom supported
- New *Reader & Feeds* section in Settings and *Open in Reader* in the quick menu
- What's New shows the beta features; the version in Settings reads "1.1.0 Beta 1"
- `make-ipa.sh` puts the beta label into the file name (`Orbrisa-1.1.0-Beta-1-unsigned.ipa`)

## [1.0.0] – 2026-11-03

First release as **Orbrisa** (formerly tvOSBrowser).

### Added
- New name, app icon (layered for parallax) and Top Shelf image
- Video popup when a video starts: *Fullscreen*, *Choose video…*, *Stay on page*
- Fullscreen plays the page's real stream in the native Apple TV player (from the player's configuration, the video element or captured network requests)
- Stream capture for HLS, MP4 and DASH, with advert filter and stream picker
- Pre-roll advert detection and skipping on the page and in the player
- VLC player (VLCKit) as fallback for formats AVPlayer can't play
- Top Shelf extension with open tabs and favorites (in development, may not show up yet)
- Address bar and text fields open the keyboard directly
- Top bar hides while scrolling down, returns when scrolling up
- Usage guide with Siri Remote illustrations
- `scripts/make-ipa.sh` builds an unsigned IPA with one command
- Credits for Steven Troughton-Smith, Jip van Akker and Claude (Anthropic) in the README
- Ko-fi link to support Orbrisa (Sponsor button, README)
- Screenshots in the README
- English and German: the app follows the Apple TV language (German for German, English for everything else)
- Version number and studio logo in the menu
- Tab strip under the address bar with site logos, a large preview of the focused tab and optional site colours
- Settings redesigned like the tvOS Settings app: centred panel, section titles, Apple-style switches; the address bar reads "Einstellungen" while it is open
- Liquid Glass switch and intensity slider for the whole app
- Appearance for websites: Automatic (follows the Apple TV), Light or Dark
- Font size slider (50–200 %) instead of separate increase / decrease / reset entries
- *What's New* screen after each update, also under Settings → Help

### Changed
- Siri Remote input in the Apple TV player is handled by the system player (fixes play after scrubbing)
- Tab icon with two squares and the tab count

### Removed
- Developer leftovers: WKWebView proof of concept, two disabled fullscreen experiments, Top Shelf test tile
- Diagnostics menu in release builds (still available in Debug builds)
- Console logging in release builds
- YouTube quality selector (YouTube rejects the required client)
