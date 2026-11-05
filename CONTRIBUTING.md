# Contributing to Orbrisa

Thanks for helping! A few notes so things go smoothly.

## Before you start
- Check the [issues](../../issues) – maybe someone is already on it.
- For larger changes, open a feature request first so we can agree on the direction.

## Setup
1. `cp Configs/Local.xcconfig.example Configs/Local.xcconfig` and add your team ID and bundle ID.
2. Open `Orbrisa.xcodeproj`, build and run on an Apple TV or the tvOS Simulator.
3. Never commit `Configs/Local.xcconfig` (it's in `.gitignore`).

## Code style
- Objective-C with ARC, 4 spaces, opening braces on the same line.
- WebKit is loaded at runtime – go through `BrowserWebView`, don't import WebKit headers.
- Keep page scripts (JavaScript inside `BrowserWebView.m`) self-contained and wrapped in `try/catch`.
- Comments explain *why*, in English.
- Texts on screen are written in English inside `BrowserLocalized(@"…")`; add the German translation to `Orbrisa/de.lproj/Localizable.strings`.
- Log with `BrowserLog(...)` from `BrowserLog.h`, not `NSLog` – it prints in Debug builds only.

## Pull requests
- One topic per PR, with a short description and how you tested it (Apple TV model, tvOS version, sites).
- Reference the issue with `Refs #123` or `Fixes #123`.
- The CI build must pass.

## Reporting site problems
Video and ad handling depends on each website. Please include the site, the steps, and – if you can – the Xcode console lines (Debug build) starting with `[MediaCapture]`, `[VideoChoice]` or `[AdDbg]`.
