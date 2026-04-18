# Changelog

All notable changes to `l10n-agent` are documented here.

## 0.2.0 — 2026-04-18

### Correctness fixes

**Cache invalidation now includes provider config** — Previously the translation cache was keyed only on `source_hash + locale + model_version`, so changing the glossary or provider settings in `l10n/config.yaml` could silently serve stale cached translations. Cache entries now include a `config_hash` derived from the provider-relevant config subset (`type`, `model`, `codex_min_version`, `glossary`). Entries from cache files written by v0.1.0 (schema v2) are automatically discarded on first load and a diagnostic (`L10N_E0086`) is emitted. The next `sync` will re-translate from the provider and rebuild the cache in the new v3 format.

**Placeholder validation is now order- and count-sensitive** — The previous check sorted placeholder names before comparing, which meant a translation that swapped positional placeholders (`{0} loves {1}` → `{1} loves {0}`) would pass validation. Validation now:
- enforces that the total placeholder count matches between source and translation
- enforces multiset equality so repeated placeholders (`{name} and {name}`) cannot be collapsed to a single occurrence (`{name}`) without detection
- enforces that digit-named positional placeholders (`{0}`, `{1}`, …) appear in the same order in the translation
- allows named ICU placeholders (`{count}`, `{user}`, …) to be freely reordered, which is necessary for grammatical correctness across languages

**Rollback pre-flight safety** — `rollback --to <id>` now:
- acquires the sync lock before touching any files, preventing a race with a concurrent `sync`
- validates the target snapshot exists and has a sound structure *before* creating a recovery snapshot, so a missing or malformed target no longer leaves a useless file in `l10n/.snapshots/`
- rejects snapshot files that contain paths escaping the project root (path traversal guard)

### Schema changes

- `l10n/.cache.json` schema bumped from v2 to v3. The new `config_hash` field on each entry is required. v1 and v2 cache files are silently dropped with a `L10N_E0086` warning.

### New diagnostic code

- `L10N_E0086` — emitted when an existing cache file uses a schema version older than v3. All cached translations are dropped and will be re-fetched on the next `sync`.

---

## 0.1.0 — 2026-04-18

Initial release.

### Commands

- `init` — scaffold `l10n/`, detect native localization files, and optionally import existing strings
- `sync` — reconcile source, translations, cache, history, and native platform files
- `lint` — validate key naming rules; `--fix` proposes and applies renames via Codex CLI
- `status` — show running or interrupted sync state and per-locale progress
- `check` — deterministic CI gate for lint failures, missing/stale translations, and platform drift
- `doctor` — report locale coverage, reviewed vs. machine-translated counts, and provider health
- `dedupe` — report exact and semantic duplicate source copy
- `rename` — rename a canonical key across all managed files in one transactional pass
- `rollback` — restore managed localization files to a prior history snapshot
- `import` — ingest source and reviewed translations from native iOS or Android platform files
- `repair` — re-canonicalize managed JSON and auto-merge simple disjoint-key git conflict markers

### Supported platforms

- iOS `.xcstrings` and `Localizable.strings`
- Android `strings.xml`

### Provider

- local Codex CLI only; no hosted backend required
