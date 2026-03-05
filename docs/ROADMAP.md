# indexd Roadmap

This roadmap tracks planned feature work beyond bug fixes.

## Now (Beta Hardening)

- Resolve high-impact playback and UI bugs found during beta testing.
- Stabilize packaging/release process for each beta tag.

## Next (Feature Expansion)

### Local Library Support (No ABS Server Required)

Allow users to use indexd with local audiobook files/folders even when they do not have an Audiobookshelf server.

#### Goals
- Add a "Local Library" source type alongside server-backed libraries.
- Let users select one or more folders containing audiobook files.
- Build and maintain a local index of books, chapters, and playback progress.
- Keep existing playback UX consistent between server and local sources.

#### Phase 1 (MVP)
- Folder picker + local library registration.
- File scan and grouping into books (single-file and multi-file audiobooks).
- Read embedded metadata (title, author, narrator, chapters, cover art where available).
- Local playback + progress persistence.

#### Phase 2
- Library refresh/rescan controls.
- Better grouping/merge heuristics for messy file layouts.
- Import/export local library metadata cache.

#### Phase 3 (Metadata Enrichment)
- Optional metadata matching from online sources.
- Confidence scoring + user confirmation before applying matches.
- Manual metadata correction UI (title/author/series/narrator/cover).

#### Open Questions
- Which metadata providers to support first?
- How to handle provider keys/rate limits in a privacy-safe way?
- What conflict strategy to use when embedded tags differ from matched metadata?

### Uninstall Workflow (Settings) ✅ Completed

Add a guided uninstall flow in Settings for users who want to fully remove indexd and its local data.

#### Goals
- [x] Add `Settings -> Uninstall indexd…`.
- [x] Show uninstall summary + cleanup actions before execution.
- [x] List cached books with per-book selection.
- [x] Switch primary action dynamically (`Uninstall` vs `Choose Folder…`).
- [x] Export selected cached books to a user-selected folder.
- [x] Clean up app support data + preferences + keychain (best effort).
- [x] Remove installed app bundle via helper handoff and self-clean helper artifacts.

## Later

- Advanced offline/resume robustness for interrupted downloads.
- Expanded sync diagnostics and audit tools.
- Additional accessibility and keyboard-first workflows.
- Developer ID signing + notarization workflow.
