# AGENTS.md

## Purpose

`l10n-agent` is a local-first CLI for native iOS and Android localization workflows. It keeps a canonical JSON source of truth under `l10n/`, syncs native platform files, uses local Codex CLI for translation and semantic dedupe, and keeps deterministic repo state in git-friendly files.

This file is intended to preserve the important maintainer context that would otherwise live only in a product doc.

## Product boundaries

### In scope

- local CLI-first workflows
- canonical source file at `l10n/source.<locale>.json`
- derived per-locale translation files at `l10n/translations.<locale>.json`
- iOS `.xcstrings` and `Localizable.strings`
- Android `strings.xml`
- local Codex CLI as the only provider-backed path
- deterministic repo checks and offline tests

### Out of scope for v1

- hosted services or remote state
- OTA/runtime translation delivery
- web UI or translator portal
- enterprise collaboration features
- non-mobile platforms
- plural resource authoring and plural ICU syntax support

## Core workflow model

The intended ownership model is:

1. Humans edit canonical source in `l10n/source.<locale>.json`.
2. `sync` derives translations and native platform files from canonical state.
3. App code references localization keys rather than human-readable copy literals.
4. Humans may review and lock translations by setting `reviewed: true`.

Native files are derived outputs. They should not become the long-term source of truth after adoption.

## Supported commands

- `init`
- `sync`
- `lint`
- `status`
- `check`
- `doctor`
- `dedupe`
- `rename`
- `rollback`
- `import`
- `repair`

## Important behavioral rules

- canonical source lives under `l10n/source.<locale>.json`
- translation files live under `l10n/translations.<locale>.json`
- all persisted JSON is versioned and stable-sorted
- removed locales must be archived under `l10n/.archive/`
- history is append-only in `l10n/.history.jsonl`
- rollback depends on snapshots in `l10n/.snapshots/`
- tests must stay offline; no live Codex calls in CI
- provider-backed behavior must stay isolated to `src/providers/`
- reviewed translations must never be silently overwritten
- placeholder parity must be preserved across translations (order-sensitive for digit-named positional placeholders; count-sensitive for all names)
- semantic dedupe may propose merges but must never auto-merge keys
- cache hits require matching `config_hash` (provider-relevant config subset) in addition to `source_hash` and `locale`; changing glossary or provider settings busts affected entries
- `rollback`, `rename`, `import`, `repair`, and `lint --fix` must all acquire the sync lock before any file I/O and release it in a `finally` block
- `rollback` must additionally validate the target snapshot before creating a recovery snapshot
- `repair` must write each successfully-parsed file independently; a parse error on one file must not block rewrites on other valid files
- Codex subprocess invocations must carry an `AbortController`-backed timeout (default 5 minutes); preflight calls must time out at 15 seconds

## Provider model

`l10n-agent` uses local Codex CLI only.

Provider-backed commands:

- `sync`
- `dedupe`
- `doctor` request estimation when Codex is available

Preflight must continue to validate:

- Codex installed
- Codex logged in
- Codex version meets configured minimum

Failure codes currently matter as product behavior:

- `L10N_E0050` not installed
- `L10N_E0051` not logged in
- `L10N_E0052` version too old
- `L10N_E0053` rate limit or quota
- `L10N_E0054` subprocess failure
- `L10N_E0055` malformed provider protocol/output
- `L10N_E0056` subprocess timed out (default 5-minute wall-clock limit per invocation)
- `L10N_E0079` sync lock already held (also used for rollback, rename, import, repair, lint-fix lock contention)
- `L10N_E0086` cache schema upgrade — v1/v2 cache dropped, translations will re-run
- `L10N_E0087` glossary term not preserved in a translation
- `L10N_E0088` repair could not parse or merge a managed JSON file
- `L10N_E0090` reviewed translation skipped by sync (reviewed-stale warning)

## Data model summary

Important managed files:

- `l10n/config.yaml`
- `l10n/source.<locale>.json`
- `l10n/translations.<locale>.json`
- `l10n/.cache.json`
- `l10n/.history.jsonl`
- `l10n/.state.json`
- `l10n/.archive/`
- `l10n/.snapshots/`

Important translation entry semantics:

- `reviewed`
  Human-reviewed; `sync` must not silently replace it.
- `stale`
  Source changed after translation was produced or reviewed.
- `source_hash`
  Current source-copy fingerprint used for drift detection.

Cache entry semantics (`l10n/.cache.json` schema v3):

- `source_hash` — fingerprint of the source key text and placeholders
- `locale` — target locale code
- `config_hash` — fingerprint of the provider-relevant config subset (glossary, model, provider type, minimum version); changing any of these fields invalidates cached entries for affected keys
- `model_version` — model identifier returned by the provider at translation time
- `text` — cached translation text

## Important paths

- `src/cli/`
  command wiring and human/json output
- `src/config/`
  config schema and loader
- `src/core/store/`
  canonical JSON schemas, hashing, load, and write helpers
- `src/core/sync.ts`
  canonical reconciliation, cache/state/history, locale add/remove handling
- `src/core/dedupe.ts`
  exact and semantic duplicate reporting
- `src/core/glossary.ts`
  glossary enforcement over persisted translations
- `src/core/repair.ts`
  canonical JSON normalization and merge-artifact repair
- `src/core/rename.ts`
  transactional key renaming across managed state
- `src/core/rollback.ts`
  history-based restoration; acquires sync lock and validates target snapshot before any file I/O
- `src/providers/codex-local.ts`
  Codex preflight, structured prompts, and replay transport
- `src/adapters/ios/`
  `.xcstrings` and `Localizable.strings` adapters
- `src/adapters/android/`
  `strings.xml` adapter
- `fixtures/projects/`
  integration fixtures
- `fixtures/provider/`
  recorded provider sessions for offline tests

## Onboarding scenarios the docs must keep covering

The public docs need to stay complete enough that `PRD.md` can be removed without losing onboarding knowledge.

They must continue to explain:

- how to adopt the tool in a repo that already has iOS and/or Android localization files
- how to adopt the tool in a repo that has not localized anything yet
- how to create the first native localization containers for greenfield adoption
- how to replace hard-coded strings in app code with localizable key lookups
- how canonical dotted keys map to Android snake_case resource names by default

## Migration expectations

For partially localized or unlocalized apps, the intended migration order is:

1. create or detect native localization files
2. run `init`
3. establish canonical keys in `source.<locale>.json`
4. run `sync`
5. replace code literals with localization lookups
6. use `rename` and `dedupe` to improve key quality rather than editing many files manually

## Release readiness and docs policy

- `README.md`, `AGENTS.md`, and `CHANGELOG.md` should be sufficient project context if `PRD.md` is deleted
- public docs must describe the actual implemented command surface, not milestone placeholders
- if behavior changes, update docs and integration tests in the same change
- keep repo publish-safe: never commit credentials, `.env*`, private keys, auth dumps, or sensitive recorded model output
- pre-commit runs `npm run secrets:scan`; keep it passing

## Fast start

```bash
npm install
npm run build
npm test
npm run repo:public-check
```
