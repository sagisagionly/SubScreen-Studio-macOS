# SubScreen Studio

A native macOS scene editor for USB status displays. **Supports MiraBox D92 and darkFlash V92**
(9.2-inch, 1920×462), plus the DQ 2.88-inch 480×480 display. It is designed around the
open-source `sub-screen-player` (`ssp`) service.

This is an independent community project and is not affiliated with MiraBox, darkFlash, Apple,
Google, Microsoft, Spotify, Tesla, or their subsidiaries. Product and service names are used only
to describe compatibility.

## Download

Download the latest Apple Silicon ZIP from [Releases](../../releases/latest), unzip it, and move
**SubScreen Studio.app** into Applications. The current community build is ad-hoc signed rather
than Apple-notarized. On first launch, right-click the app and choose **Open**. If macOS still
quarantines the downloaded build, run:

```bash
xattr -dr com.apple.quarantine "/Applications/SubScreen Studio.app"
```

Requires macOS 14 or newer. The bundled `ssp` helper means no separate display-driver installation
is needed.

## Current prototype

- macOS-style three-pane editor
- System, Light, and Dark appearances using native macOS materials and colors
- Searchable widget gallery organized by category
- Multiple scenes with autosave
- Per-scene output targeting for D92 wide and 2.88-inch square displays
- A compact, ready-to-use **2.88 Dashboard** scene and square-safe widget presets
- Both supported displays can stay connected; the selected scene is routed to the matching hardware
- Automatic scene rotation
- Deterministic canvas-level dragging and lightweight local-frame resizing; scene data commits once on mouse-up
- Layer selection, locking, hiding, ordering, opacity, colors, and corner radius
- Clock, live weather, Codex usage, text, shape, image, looping video, YouTube,
  Now Playing, synced lyrics, notifications, calendar, reminders, focus timer,
  CPU/RAM/GPU, network speed, AirPods, RSS, finance, sports, transit, world clocks,
  GitHub, smart home, chat, creator counters, visualizer, photo album, web snapshot,
  package tracking, environment, message-board, and darkFlash VD1200P power-supply widgets
- Exact macOS Now Playing metadata and artwork for Apple Music, browsers and compatible players
- Automatic Pear Desktop support through its local API Server, with browser-title fallback
- Automatic in-memory original-language lyrics with selectable YouTube Music, LRCLIB, Musixmatch, and Megalobiz providers (nothing cached after quit)
- Apple Music and Spotify metadata matching, including order-independent multi-artist and relaxed album/single matching
- Optional local `.lrc` synchronized lyrics override
- Five-line synchronized lyric view with dimmed previous/next lines
- OBS-style eight-handle resize, ratio/free resize, center resize, magnetic guides and alignment tools
- Arrow-key movement (1 px, or 10 px with Shift) and editor-wide Option + Arrow shortcuts
- Resizable sidebars, inspector, layers panel, Fit preview, and exact 15–120% canvas zoom entry
- Selectable clock time zone and Celsius/Fahrenheit weather display
- Three customizable world-clock city labels and time zones
- Numeric layout, opacity, corner-radius, font-size, zoom, and output-FPS controls
- Searchable city/country weather setup powered by Open-Meteo
- Selectable CNN, Yahoo News, TechCrunch, The Verge, or custom RSS/Atom news feeds
- Real Codex account quota, reset time, and bridge approval status via local app-server
- Live microphone-driven audio visualizer
- Live local CPU, RAM, Apple GPU, upload, and download readings
- Live darkFlash VD1200P USB telemetry for 3.3 V, 5 V, two reported 12 V channels,
  PSU temperature, fan RPM, AC input voltage, input power, connection state, and firmware
- AirPods/Beats connection detection with a native animation and D92 notification banner
- Wired iPhone/iPad connection detection with a native animation and D92 notification banner
- Optional scene background matching to current album artwork and Launch at Login setting
- Font selection for text layers
- Drag photos and videos directly from Finder onto the canvas, or use **Import Media**
- Replace media, reveal it in Finder, and see a clear warning when a source file is missing
- **Go Live** uses an adjustable 1–60 FPS ceiling with automatic content-aware rates: full rate for video, 10 FPS for music, 2 FPS for live dashboards, and 1 FPS for static layouts
- The packaged app includes its matching `ssp` helper and starts it automatically when needed
- Live rendering pauses during a pointer transform and immediately sends the final frame on release, keeping the editor responsive
- Image assets are decoded once and cached, and unchanged widget content is isolated from position-only canvas updates for smooth complex-scene dragging
- Batched monitor publications, direct CGImage-to-JPEG output, timer coalescing, and on-demand capture loops reduce CPU, memory churn, and background wakeups

Codex usage connects to the Codex CLI's local app-server and listens for
`account/rateLimits/updated`. Approval alerts are shown for sessions routed through that bridge;
other Codex windows continue to present approvals in their own interface.

## Run

This package requires macOS 14 or newer and the Swift toolchain:

```bash
cd outputs/SubScreenStudio
swift run
```

If the newest Command Line Tools installation has several macOS SDKs and reports a compiler/SDK mismatch, select the matching installed SDK explicitly. The project was verified here with:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --disable-sandbox
```

When running from source, build and start `ssp` separately:

```bash
brew install nomunomu0504/tap/ssp
ssp serve
```

The double-clickable app built by `build-app.sh` includes `ssp`, so no separate setup is needed.

## Live output behavior

The live bridge adapts its render cadence to the visible widgets. Local and resolved YouTube video frames are sampled directly from AVPlayer for the hardware compositor; non-video scenes avoid wasteful full-resolution redraws while keeping clocks, metrics, music progress, and lyrics current.

Version 0.1.1 replaces SwiftUI's AVKit video wrapper, which could be repeatedly created by live off-screen rendering and cause an unexpected quit. Media is now validated before playback and the live renderer never instantiates a video player.

## Widget connections

Local widgets work without accounts. Apple Music and YouTube Music are detected through macOS
automation and may show a one-time permission prompt. Connected-service widgets start in manual
mode so a layout is usable immediately; their title, detail, and value can be edited in the
inspector without storing API keys. Service-specific OAuth/API adapters remain separate from the
scene format so they can be added without rebuilding layouts or exposing credentials in project
files.

Local videos can be sent directly to `ssp` for full-screen, hardware-friendly playback. YouTube
uses native AVPlayer playback after a one-click Homebrew installation of `yt-dlp` and Deno; this avoids
the error and bot checks YouTube applies to embedded WebKit players. The resolver accepts YouTube's
current separate video-stream formats instead of requiring a legacy combined MP4. Editor playback prefers
an H.264 HLS stream, which AVPlayer supports natively, and reports stream failures directly in the widget. YouTube sent to the D92 is
temporarily downloaded and uploaded as video, so sub-screen-player does not need Headless Chrome. Web widgets can still hand
their URL to `ssp` web mode.

## Build a double-clickable app

```bash
./build-app.sh
```

The result is written to `dist/SubScreen Studio.app`. It is ad-hoc signed for local use, but it is not Developer ID signed or notarized for public distribution.

## Open-source acknowledgement

The USB transport and display protocol implementation are provided by
[sub-screen-player](https://github.com/nomunomu0504/sub-screen-player), licensed under MIT or
Apache-2.0. Music-player interoperability and lyric-provider behavior were informed by
[Pear Desktop](https://github.com/pear-devs/pear-desktop), licensed under MIT. No Pear Desktop
branding or artwork is included.

SubScreen Studio is distributed under the MIT License. Complete acknowledgements and retained
license text are available in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and
[`ThirdPartyLicenses`](ThirdPartyLicenses).
