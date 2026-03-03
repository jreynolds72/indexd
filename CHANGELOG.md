# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning while in beta.

## [Unreleased]

## [0.1.0-beta.3] - 2026-03-03

### Added
- Offline download workflow for audiobooks:
  - Download to app cache from item details, context menus, and bulk multi-select actions.
  - Download to user-selected folder via Finder picker.
  - Downloaded browse section and quick navigation into downloaded items.
  - Download removal actions for single and multi-select.
- Download status surfaces across the app:
  - Toolbar download icon with circular progress ring.
  - Download popout with per-item status, active linear progress bars, queue state, and click-through to item details.
  - Download cache shortcut in Finder from toolbar/item menus.
- Multi-select item operations in the books list and bulk actions from header menu/context menu.
- Cover-art thumbnails in book rows in the main item list.

### Changed
- Download filenames now use user-friendly book-title based naming in app cache.
- Download popout switched from paged results to continuous scrolling to avoid premature page splitting.
- Download popout can be resized by drag handle and supports larger content areas.
- Download toolbar icon rendering updated for improved visibility and clockwise progress from top.

### Fixed
- Download failures on some Audiobookshelf servers by falling back to `audioFile.id` when `audioFile.ino` is missing.
- Download test transport updated for progress callback compatibility with the production transport protocol.

## [0.1.0-beta.2] - 2026-03-03

### Added
- Project documentation and governance files:
  - `README.md`
  - `LICENSE` (GPL-3.0)
  - `CONTRIBUTING.md`
  - `SECURITY.md`
  - GitHub issue/PR templates
- Login dialog now uses separate server fields:
  - Protocol selector (`http` / `https`)
  - Host/IP field
  - Port field (pre-filled with default `13378`)
- Login supports Return/Enter submission from form fields.
- Added explicit settings-open diagnostics via `OSLog` category `settings`.
- Book detail panel enhancements:
  - Narrator and series lines under author
  - Clickable author/narrator/series links for browse navigation
  - Richer metadata rows (publisher, publish year, language, genres, tags, collections)
  - Blurb section above metadata
  - Co-author display (all authors)
  - HTML blurb rendering with plain-text fallback

### Changed
- In-app settings opening now uses a dedicated SwiftUI window scene (`indexd-settings-window`) instead of fragile AppKit selector dispatch.
- Server configuration parsing/composition now builds URLs from structured fields and remains backward-compatible with previously saved server URLs.
- Internal app naming and identifiers were rebranded from `ABSClientMac` to `indexd` for product consistency.

### Fixed
- Fixed in-app **Open Settings** / **Configure Shortcuts in Settings** actions that previously no-op’d, became unresponsive, or crashed with an unrecognized selector.
- Fixed release sanitization regression where packaged builds could prefill a previously-used server URL.
- Fixed detail panel chapter count so it reflects active loaded chapters (session/metadata), not only embedded item chapter arrays.
- Fixed raw HTML tags showing in blurbs by parsing/stripping formatting before display.
- Fixed single-author-only rendering in detail panel for co-authored books.

### Commits Since 0.1.0-beta.1
- `9184bc7` Add README and GPL-3.0 license
- `9a5d00a` Add contributing, security, and issue templates
- `e2bad8f` Fix in-app settings opening and improve server login form
- Unreleased working changes in this release:
  - Detail panel metadata and navigation improvements
  - Blurb HTML rendering cleanup
  - Co-author display support
  - Chapter count consistency fix
