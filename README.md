MatrixRainSaver
================

This is a macOS screen saver. It draws falling glyphs. It looks like `cmatrix`. It does not save power. Don't kid yourself.

What it does
------------
- Matrix rain with sane defaults. No wrap-around, streams spawn from the top, tails fade.
- Character sets you actually asked for: `01`, printable ASCII (33–126), Hex, Base64.
- Staggered columns, different tail lengths, different step dividers. Looks alive, not stupid.
- A configuration window that opens instantly and does what you click. No drama.
- Wider column spacing so it doesn't look like a green soup.

What it does not do
-------------------
- It does not magically reduce your power bill. LCD/mini‑LED backlights don't care about black pixels. Animation costs CPU/GPU.
- It won't fight macOS caching for you if you deploy the wrong bundle.

Requirements
------------
- macOS 26 (Tahoe Lake) or newer.
- Xcode 16/17 (tested with 17.0 / SDK 26.0).

Install (the easy way)
----------------------
You already have a built artifact on the Desktop if you followed the release script:

1) Double‑click `MatrixRainSaver_v1.0.1.saver` on your Desktop, or
2) Copy the bundle to `~/Library/Screen Savers/`.

Select it in System Settings → Screen Saver. Click “Options” to switch character sets.

Build it yourself (Release)
---------------------------
You want to build? Fine.

```
xcodebuild -scheme MatrixRainSaver -configuration Release -project MatrixRainSaver.xcodeproj
```

The product ends up here (thanks, Xcode):
`~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/MatrixRainSaver.saver`

Copy it where macOS actually looks for it:

```
ditto "~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/MatrixRainSaver.saver" "~/Library/Screen Savers/MatrixRainSaver.saver"
```

Clean redeploy (because the system lies to you)
----------------------------------------------
When you think “nothing changed”, it's usually because you didn't clean. Do this every time:

```
killall "System Preferences" 2>/dev/null || killall "System Settings" 2>/dev/null || true
killall ScreenSaverEngine 2>/dev/null || true
rm -rf "~/Library/Screen Savers/MatrixRainSaver.saver"
xcodebuild clean -scheme MatrixRainSaver -configuration Debug -project MatrixRainSaver.xcodeproj
xcodebuild -scheme MatrixRainSaver -configuration Debug -project MatrixRainSaver.xcodeproj
ditto "~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/MatrixRainSaver.saver" "~/Library/Screen Savers/MatrixRainSaver.saver"
open "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"
```

Configuration
-------------
- Options window → choose one of:
  - Binary (01)
  - ASCII (33–126)
  - Hex (0–9, A–F)
  - Base64 (A–Z, a–z, 0–9, +, /)
Changes apply immediately when you click the radio, and again when you hit “Done”.

Speed and spacing
-----------------
- Speed comes from two numbers: `speed` (rows per step) and `divider` (frames per step).
- We run `speed = 1`. We slow down with `divider` (bigger number = slower).
- Current baseline ships with `divider = 12–20` and wider column spacing.

If you really care about power
------------------------------
- Drop the frame rate: set `setAnimationTimeInterval:1/24.0` or even `1/15.0`.
- Increase `divider` further.
- Draw less: larger `_charWidth`, shorter tails.
- In Low Power Mode, do all of the above automatically. Your battery will thank you more than some “dark theme”.

Troubleshooting
---------------
- Options window won't open? It’s a plain NSWindow now. If you still break it, that’s on you.
- “Why no change?” Because you didn't delete the old bundle. Remove `~/Library/Screen Savers/MatrixRainSaver.saver` first.
- “Where is my .saver?” Xcode likes `.../Build/Products/{Debug|Release}/MatrixRainSaver.saver`. Use that, not `Index.noindex` junk.
- Empty screen? Make sure head characters are written at the new head every move. We do.

Code signing
------------
The release is ad‑hoc signed. If you want your own signature, go ahead. The screen saver engine doesn’t need your App Store sob story.

Contributing
------------
Pull requests welcome if they make it simpler, faster, or less stupid. Don’t add dependencies. Don’t add frameworks to draw text.

License
-------
MIT. No warranty. If it breaks, you get to keep both pieces.


