# l10n-agent

`l10n-agent` is a local-first CLI for managing a canonical localization store for iOS and Android projects.

Current status: Milestone 2 is implemented. The repo now includes the deterministic M1 foundation plus an iOS `.xcstrings` adapter with placeholder-aware read/write support, plural rejection, and deterministic health checks against the canonical store. Android write support and provider-backed sync remain for later milestones.

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
