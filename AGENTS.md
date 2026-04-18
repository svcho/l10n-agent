# AGENTS.md

## Fast start

```bash
npm install
npm run build
npm test
npm run repo:public-check
```

## Current scope

- M1 only: deterministic foundation
- implemented commands should stay local-only and deterministic: `lint`, `check`, `doctor`
- do not add live translation calls or platform write logic unless the task explicitly moves into later milestones

## Important paths

- `src/cli/` command entrypoints and output formatting
- `src/config/schema.ts` repo config schema and loader
- `src/core/store/` canonical JSON store schemas and loaders
- `src/core/linter/` key-style rules and reporting
- `src/providers/codex-local.ts` Codex preflight only for now
- `fixtures/projects/` integration fixtures for `check` and `doctor`

## Working rules

- canonical source lives under `l10n/source.<locale>.json`
- translation files live under `l10n/translations.<locale>.json`
- all persisted JSON is versioned and stable-sorted
- tests must stay offline; no live Codex calls in CI
- keep repo publish-safe: never commit credentials, `.env*`, private keys, or auth dumps
- pre-commit runs `npm run secrets:scan`; keep it passing
