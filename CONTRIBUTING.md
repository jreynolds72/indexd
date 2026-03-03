# Contributing to indexd

Thanks for contributing to indexd.

## Ground Rules

- Be respectful and constructive.
- Keep PRs focused and small when possible.
- Include tests for behavior changes when practical.
- Update docs when user-visible behavior changes.

## Development Setup

```bash
swift test
swift run indexd
```

Optional local auth behavior used during development:

```bash
ABS_DEV_LOCAL_AUTH_STORE=1 swift run indexd
```

## Pull Requests

1. Create a branch from `main`.
2. Make your changes.
3. Run tests:
   ```bash
   swift test
   ```
4. Open a PR with:
   - Clear summary of changes
   - Screenshots for UI changes
   - Notes on testing performed

## Issue Reporting

Use the issue templates for:
- Bug reports
- Feature requests

Please include reproduction steps and environment details for bugs.
