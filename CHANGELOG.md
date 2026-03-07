# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning while in beta.

## [Unreleased]

## [0.1.0-beta.5] - 2026-03-06

### Added
- Per-book local metadata editor from item actions, with save/cancel flow.
- Match workflows in metadata editor:
  - Quick Match and manual `Match...` search.
  - Re-Scan action and match-result preview before apply.
  - Exact-match indicator when runtime is within 1% of local duration.
- Multi-source metadata ranking support (Audible + Google Books providers).
- Audible cover-search/selection workflow for local metadata cover updates.
- Local library auto-refresh via file-system watching:
  - Monitors library folders (including subfolders) for changes.
  - Triggers automatic library updates when new or changed items are detected.
- Local library file-organization settings:
  - Template-based organization under library root (for example `Author/Series/Book`).
  - Unmatched-item fallback handling for organization workflows.

### Changed
- Local-library context actions now open the configured local library root in Finder.
- Local-library menu labeling was clarified to reduce confusion with remote download wording.
- Copy-to-local ingest now routes copied files through local-library ingest/organization paths.
- Download/copy filename generation now preserves dramatized-edition cues in output names.
- README release instructions were simplified by removing outdated notarization references.

### Fixed
- Multi-item copy to local library was hardened to avoid follow-on failures in queued operations.
- Series normalization now strips ABS-style trailing sequence suffixes (for example `Series #1`) during folder resolution to prevent duplicate per-book series directories.
- Metadata editor fixes:
  - Preserve selected item context for match/save.
  - Keep match actions visible in editor footer.
  - Present manual match sheet while editor is open.

### Commits Since 0.1.0-beta.4
- `bc65ef6` feat(metadata): finalize matching and cover workflows for beta.5
- `a813da6` feat(match): add Google Books provider and weighted multi-source ranking
- `609f663` fix(metadata): present manual match sheet from metadata editor
- `f013d1f` fix(metadata): always show match actions in editor footer
- `8c0bfe0` feat(metadata): add cancel and manual match dialog alongside quick match
- `45ef9a0` fix(metadata): preserve editor item context for quick match/save
- `fb76839` feat(local): add per-book metadata editor with quick match actions
- `34f9884` feat(local): add metadata matching workflow and reconciliation notes (#27)
- `c9b21c2` feat(local): watch local library folders and auto-refresh on changes
- `42076f9` fix(local): open selected local library root in Finder and relabel menu
- `20758df` fix(copy): make multi-copy resilient to library context changes
- `aed4e9a` feat(local): add template-based local file organization settings
- `91a046a` fix(local): normalize ABS series suffix when resolving folder template
- `f94c268` Remove notarization instructions from README

## [0.1.0-beta.4] - 2026-03-04

### Added
- Played/Unplayed state management wired to ABS native finished status:
  - Single-item and multi-select actions for Mark Played / Mark Unplayed.
  - Played status surface in rows and detail panel metadata.
- Live transport diagnostics and behavior improvements:
  - Transport probing and recommendation (WebSocket/SSE/Polling fallback).
  - Connected menu now shows active transport.
  - Background selected-item reconciliation while live transport is active.
- Settings maintenance capabilities:
  - New Maintenance tab with guided uninstall workflow.
  - Uninstall summary sheet with staged cleanup actions and optional cached-book export.
- Download UX enhancements:
  - Sequential queue recovery behavior for interrupted jobs.
  - Download popout improvements (resizable panel, scroll-first item listing, item click-through).
  - Bulk download/remove actions integrated into multi-select workflows.
- Dock icon shortcuts:
  - Library/navigation quick actions and playback controls from dock menu.

### Changed
- Search/list refresh behavior no longer flashes to unfiltered state during live update ticks.
- Selection normalization moved to avoid NSTableView reentrant delegate warnings.
- Detail metadata panel expanded with richer fields and cleaner structured rendering.
- Download actions in book detail panel simplified to compact button-style controls.

### Fixed
- Prevented local selected-item sync paths from overwriting ABS played/unplayed changes.
- Resolved repeated 15-second UI reversion issue while searching.
- Fixed now playing/widget art propagation reliability in media integration path.
- Fixed download compatibility on servers missing specific audio file identifier fields.

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
