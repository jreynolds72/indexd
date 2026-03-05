# indexd

Native macOS client for Audiobookshelf, built with SwiftUI and AVFoundation.

## Status

indexd is currently in beta.

- Latest release: `v0.1.0-beta.4`
- Changelog: [CHANGELOG.md](./CHANGELOG.md)

## Highlights

- Native macOS UI for Audiobookshelf with library browsing and playback
- Server login with token auth and secure credential storage
- Bidirectional progress sync with conflict resolution
- Playback controls with chapter-aware scrubbing and chapter navigation
- Configurable shortcuts and separate skip backward/forward intervals
- In-app settings window and quick playback settings menu
- Offline downloads:
  - Download to app cache or custom folder
  - Download queue/progress in toolbar popout
  - Downloaded-items browsing and cleanup actions
- Bulk item actions (multi-select) for downloads and favorites
- Book-row cover art thumbnails in library lists

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
./scripts/package-app.sh 0.1.0-beta.4 1
```

Generated artifacts:

- `dist/indexd.app`
- `dist/indexd-macos-v0.1.0-beta.4.zip` (if zipped for release)

Create release zip:

```bash
ditto -c -k --sequesterRsrc --keepParent dist/indexd.app dist/indexd-macos-v0.1.0-beta.4.zip
```

## Release Process (Beta)

```bash
git add .
git commit -m "Release v0.1.0-beta.4"
git tag v0.1.0-beta.4
git push origin main
git push origin v0.1.0-beta.4
gh release create v0.1.0-beta.4 dist/indexd-macos-v0.1.0-beta.4.zip --prerelease
```

## Contributing and Security

- Contributing guide: [CONTRIBUTING.md](./CONTRIBUTING.md)
- Security policy: [SECURITY.md](./SECURITY.md)

## License

This project is licensed under the GNU General Public License v3.0.
See [LICENSE](./LICENSE) for details.
