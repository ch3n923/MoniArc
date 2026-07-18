# MoniArc

[简体中文](README.md)

MoniArc is a quiet native macOS status island that shows local Codex task activity and usage limits.

Built with Swift 6, SwiftUI, and AppKit, it has no third-party runtime dependencies. It does not upload task content or modify `~/.codex`.

**[Visit the MoniArc project homepage](https://ch3n923.github.io/MoniArc/)**

[![MoniArc project homepage preview](docs/moniarc-preview.png)](https://ch3n923.github.io/MoniArc/)

> MoniArc is an independent open-source project and is not affiliated with, endorsed by, or sponsored by OpenAI. Codex and OpenAI are trademarks of their respective owners.

## Features

- Sits over the notch or floats at the top of the display, including on notchless Macs.
- Shows Codex five-hour and weekly limits, including multiple rate-limit buckets.
- Observes the local Codex lifecycle in read-only mode: running, waiting for input, failed, idle, or unavailable.
- Expands on hover and collapses after the pointer leaves; right-click controls placement, glow, and quit.
- Matches glow themes to models such as Sol, Terra, and Luna; standard tasks breathe, fast tasks flow, and fast Sol tasks use a dedicated solar flare.
- High, xhigh, max, and ultra reasoning automatically request HDR; displays without EDR remain in SDR.
- Respects the macOS Reduce Motion setting.
- Stays out of the Dock and does not take focus proactively.

## Usage guide

Move the pointer over the status island to expand task and usage-limit details. It collapses automatically after the pointer leaves. Right-click the status island to access these options:

- **Overlay**: attaches the island to the top edge of the display; on a Mac with a notch, it blends into the notch area.
- **Floating**: displays the island as a separate rounded panel just below the top of the screen.
- **Glow**: selects Automatic, Breathing, or Flowing; Sol keeps its dedicated solar-flare motion for fast tasks.
- **HDR**: selects Automatic, On, or Off; Automatic requests HDR for high, xhigh, max, and ultra reasoning, while standard displays remain in SDR.
- **GitHub Repository**: opens the MoniArc repository in your default browser.
- **Quit MoniArc**: closes the app. You can also press `⌘Q`.

The label and color of the island indicate the current Codex task state:

- **Running (blue)**: at least one Codex task is currently running.
- **Waiting for User (orange)**: a task needs user input, confirmation, or another action before it can continue.
- **Error (red)**: at least one task has failed, or a terminal error has been detected.
- **Idle (gray)**: the task source is connected, but no task is running or waiting for user action.
- **Task Source Disconnected (dark gray)**: MoniArc cannot currently read local Codex task state. Check that Codex is installed and signed in.

When several tasks exist at once, MoniArc displays the overall state in this priority order: Error → Waiting for User → Running → Idle. Task Source Disconnected takes precedence whenever the task source is unavailable.

## Installation

MoniArc release packages are distributed exclusively through [GitHub Releases](https://github.com/ch3n923/MoniArc/releases). It is not distributed through the Mac App Store or a standalone download website.

## Requirements

- macOS 14 Sonoma or later.
- The Codex desktop app or Codex CLI installed and signed in.
- True HDR glow requires an EDR-capable display, such as the built-in Liquid Retina XDR display on a 14-inch or 16-inch MacBook Pro from 2021 or later.
- Release builds are universal binaries for arm64 and x86_64; availability of usage data still depends on the local Codex installation.

MoniArc checks the ChatGPT app and common CLI locations first. It accepts only absolute executables in `PATH` whose ownership and permissions are safe; directories writable by arbitrary users are skipped. To use another installation path, set it explicitly:

```sh
MONIARC_CODEX_PATH="/absolute/path/to/codex" open -a MoniArc
```

## Privacy

MoniArc reads Codex rate-limit responses and limited task metadata locally, solely to render its interface. It does not read `auth.json`, collect tokens, code, replies, or tool payloads, include telemetry, advertising, or analytics SDKs, or send data to the maintainer. Its Codex subprocess receives only required system, Codex/OpenAI, and network configuration variables; unrelated GitHub, cloud-service, and dynamic-loader credentials are not forwarded.

See [PRIVACY.md](PRIVACY.md) for details.

## Build locally

Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) are required:

If Xcode reports that the Metal Toolchain is missing, run `xcodebuild -downloadComponent MetalToolchain` first.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project MoniArc.xcodeproj \
  -scheme MoniArc \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

To run the debug harness:

```sh
xcodebuild -project MoniArc.xcodeproj \
  -scheme MoniArc \
  -configuration Debug \
  -derivedDataPath /tmp/MoniArcDerivedData \
  build CODE_SIGNING_ALLOWED=NO

open -n '/tmp/MoniArcDerivedData/Build/Products/Debug/MoniArc.app' \
  --args --harness
```

## License

MoniArc is released under the [MIT License](LICENSE).
