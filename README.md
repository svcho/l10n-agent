# l10n-agent

`l10n-agent` is a local-first CLI for managing a canonical localization store for iOS and Android projects.

Current status: Milestone 1 foundation is in progress. This repo currently implements deterministic config loading, canonical JSON store validation, key linting, repo health checks, and a `doctor` report. Provider-backed translation and platform adapters are still pending.

## Development

```bash
npm install
npm run build
npm test
```

## Repo safety

This repo is configured for public publication:

- tracked files are scanned with `secretlint`
- `npm run repo:public-check` runs the secret scan and shows the publish payload via `npm pack --dry-run`
- the published package is allowlisted to `dist/` and `README.md`
