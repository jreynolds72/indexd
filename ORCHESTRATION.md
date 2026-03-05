# Orchestration Notes

This file is for coordinating parallel branches against `main`.

## Current integration strategy

1. Land feature work through a dedicated `codex/*` branch.
2. Open PR to `main`.
3. Merge PR.
4. All parallel branches rebase (or merge) onto updated `main`.

## Recommended teammate reconciliation flow

```bash
git fetch origin
git checkout <your-branch>
git rebase origin/main
```

If conflicts occur:

```bash
git status
# resolve files
git add <resolved-files>
git rebase --continue
```

If rebase is not preferred:

```bash
git fetch origin
git checkout <your-branch>
git merge origin/main
```

## Notes

- Prefer small PRs per issue to reduce conflict surface.
- Avoid direct commits to `main` from local development.
- When multiple threads touch the same SwiftUI view/model files, rebase early and often.
