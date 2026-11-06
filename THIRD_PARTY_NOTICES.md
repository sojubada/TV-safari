# Third-party notices

## VLCKit

Orbrisa uses **VLCKit** (TVVLCKit / VLCKit 4) for playing video formats the system player can't handle.

- Project: https://code.videolan.org/videolan/VLCKit
- License: GNU Lesser General Public License v2.1 (LGPL-2.1-or-later)
- License text: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html

VLCKit is linked as a separate framework through Swift Package Manager (`https://github.com/videolan/vlckit`, version pinned in `Package.resolved`). Its source code is available from the project above. You may replace the VLCKit framework in the app bundle with a modified version.

## EasyList and EasyPrivacy

The ad and tracker blocklist (`Orbrisa/adblock-rules.json`) is made from host entries of EasyList and EasyPrivacy.

- Project: https://easylist.to
- License: dual-licensed under GPL-3.0-or-later and CC BY-SA 3.0

## Orbrisa

This build is based on [Orbrisa](https://github.com/fdm96/Orbrisa) by fdm96 (commit `e6a6db1`, 5 Nov 2026), backported to tvOS 16 and extended with code from TV-safari (this repository, branch `backup/tv-safari-v4.22.0`). Orbrisa's repository has no license file.

## tvOSBrowser

Orbrisa is derived from [tvOSBrowser](https://github.com/jvanakker/tvOSBrowser) by Jip van Akker which is itself a fork of the original [tvOSBrowser](https://github.com/steventroughtonsmith/tvOSBrowser) by Steven Troughton-Smith. Their copyright notices in the source files are kept.
