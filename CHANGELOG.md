# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning while in beta.

## [Unreleased]

### Added
- Login dialog now uses separate server fields:
  - Protocol selector (`http` / `https`)
  - Host/IP field
  - Port field
- Login supports Return/Enter submission from form fields.
- Port field is pre-filled with the default Audiobookshelf port (`13378`).
- Added explicit settings-open diagnostics via `OSLog` category `settings`.

### Changed
- In-app settings opening now uses a dedicated SwiftUI window scene (`indexd-settings-window`) instead of fragile AppKit selector dispatch.
- Server configuration parsing/composition now builds URLs from structured fields and remains backward-compatible with previously saved server URLs.

### Fixed
- Fixed in-app **Open Settings** / **Configure Shortcuts in Settings** actions that previously no-op’d, became unresponsive, or crashed with an unrecognized selector.
