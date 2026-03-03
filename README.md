# indexd

Native macOS client for Audiobookshelf, built with SwiftUI and AVFoundation.

## Highlights

- Native macOS UI with library browsing and playback
- Audiobookshelf server login and token-based auth
- Keychain-backed credential storage
- Offline-first playback support
- Bidirectional progress sync with conflict resolution
- Chapter-aware scrubbing and chapter navigation
- Configurable playback shortcuts and skip intervals

## Requirements

- macOS 14+
- Xcode 16+
- Swift 6 toolchain
- Running Audiobookshelf server

## Build and Run

```bash
swift test
swift run indexd
```

For local dev auth bypass behavior used during development:

```bash
ABS_DEV_LOCAL_AUTH_STORE=1 swift run indexd
```

## Packaging

Build release binary:

```bash
swift build -c release
```

Create `.app` bundle:

```bash
./scripts/package-app.sh
```

Generated app bundle:

- `dist/indexd.app`

## Project Status

indexd is currently in beta.

## License

This project is licensed under the GNU General Public License v3.0.
See [LICENSE](./LICENSE) for details.
