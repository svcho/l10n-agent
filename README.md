# l10n-agent

`l10n-agent` is a local-first CLI for managing a canonical localization store for iOS and Android projects.

Current status: Milestone 5 is implemented. The repo now includes the deterministic M1 foundation, iOS `.xcstrings` and Android `strings.xml` adapters, provider-backed `sync` with Codex preflight, replayable recorded fixtures, translation cache persistence, resumable partial-run state, reviewed/stale handling, placeholder-safety checks, plus M5 command flows for `init`, `import`, `rename`, `rollback`, and deterministic `dedupe`.

## Development

```bash
npm install
npm run build
npm test
npm run repo:public-check
```

## Repo safety

This repo is configured for public publication:

- tracked files are scanned with `secretlint`
- `npm run repo:public-check` runs the secret scan and shows the publish payload via `npm pack --dry-run`
- the published package is allowlisted to `dist/` and `README.md`
