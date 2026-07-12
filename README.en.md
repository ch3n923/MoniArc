# MoniArc

[简体中文](README.md)

MoniArc is a quiet native macOS status island that shows local Codex task activity and usage limits.

Built with Swift 6, SwiftUI, and AppKit, it has no third-party runtime dependencies. It does not upload task content or modify `~/.codex`.

> MoniArc is an independent open-source project and is not affiliated with, endorsed by, or sponsored by OpenAI. Codex and OpenAI are trademarks of their respective owners.

## Features

- Sits over the notch or floats at the top of the display, including on notchless Macs.
- Shows Codex five-hour and weekly limits, including multiple rate-limit buckets.
- Observes the local Codex lifecycle in read-only mode: running, waiting for input, failed, idle, or unavailable.
- Expands on hover and collapses after the pointer leaves; right-click controls placement, glow, and quit.
- Respects the macOS Reduce Motion setting.
- Stays out of the Dock and does not take focus proactively.

## Installation

MoniArc release packages are distributed exclusively through [GitHub Releases](https://github.com/ch3n923/MoniArc/releases). It is not distributed through the Mac App Store or a standalone download website.

## Requirements

- macOS 14 Sonoma or later.
- The Codex desktop app or Codex CLI installed and signed in.
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

## Creator

- Xiaohongshu: **HIGHNOON 正午**
- Xiaohongshu ID: `dxzico23`

## License

MoniArc is released under the [MIT License](LICENSE).
