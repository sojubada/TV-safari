# Changelog

All notable changes to Orbrisa. The format follows [Keep a Changelog](https://keepachangelog.com), versions follow [Semantic Versioning](https://semver.org).

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
