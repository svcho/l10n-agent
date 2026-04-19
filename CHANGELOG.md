# Changelog

All notable changes to `l10n-agent` are documented here.

## 0.3.0 — 2026-04-19

### Correctness fixes

**Diagnostic code collisions eliminated** — Several diagnostic codes were reused across unrelated checks, making it impossible to reliably filter or suppress a specific class of problem:

- Glossary term mismatch (`lintGlossary`) previously shared `L10N_E0072` with lint autofix "no safe destination key". Glossary violations are now `L10N_E0087`.
- Repair JSON parse and conflict-merge errors previously shared `L10N_E0073` with lint autofix "source key no longer exists". Repair errors are now `L10N_E0088`.
- The reviewed-translation stale warning emitted during `sync` previously shared `L10N_E0064` with the `check` command's stale-source-hash diagnostic. The sync warning is now `L10N_E0090`.

**Glossary word-boundary matching** — `lint --glossary` previously used a bare substring match, causing false positives when a glossary term appeared as part of a longer word (for example "App" matching inside "Apple"). Matching now uses Unicode letter lookbehind/lookahead (`(?<!\p{L})…(?!\p{L})`) so only genuine word boundaries trigger a violation.

**Locale code validation expanded** — The `LocaleCode` validator previously rejected valid BCP-47 tags with three-letter primary subtags (`fil` for Filipino, `yue` for Cantonese) and four-letter script subtags (`zh-Hans`, `zh-Hant`, `sr-Latn`). The regex now accepts the form `[a-z]{2,3}(-[A-Za-z]{4})?(-([A-Z]{2}|\d{3}))?`.

### Reliability fixes

**Sync lock now held by `rename`, `import`, `repair`, and `lint --fix`** — Previously only `sync` and `rollback` acquired the `.lock` file before writing managed localization state. Running a rename, import, repair, or lint-fix concurrently with an active sync could silently corrupt state. All write-path commands now acquire and release the sync lock around their file I/O, consistent with the behavior of `sync` and `rollback`.

**`repair` now writes per-file instead of blocking all rewrites on any parse error** — If one managed file had unparseable JSON, `repair` previously aborted every rewrite, including files that were fully valid and ready to be canonically re-sorted. The parse-error diagnostic is still emitted; only files that successfully parsed are now written, independently of errors in other files.

**Codex subprocess timeout** — `SpawnCodexExecTransport` previously had no timeout. A hung Codex process would block `sync`, `dedupe`, and `lint --fix` indefinitely. Each execution is now cancelled after five minutes (default) using `AbortController`. Preflight `codex --version` and `codex login status` calls are capped at 15 seconds. A hung or cancelled invocation emits `L10N_E0056` and is treated as a retryable provider error.

### Cache garbage collection

`sync` now prunes the cache file after each completed run:

- Entries whose `source_hash` no longer matches any key in the current source file are removed.
- For each `(source_hash, locale, config_hash)` group, only the two most-recently written model-version entries are kept.

This bounds cache growth when provider model versions change over time or when source keys are deleted.

### New diagnostic codes

- `L10N_E0056` — Codex subprocess timed out. Retrying usually resolves this; if it persists, check the network connection or upgrade Codex CLI.
- `L10N_E0087` — A translation does not preserve a configured glossary term (previously `L10N_E0072`).
- `L10N_E0088` — `repair` could not parse or merge a managed JSON file (previously `L10N_E0073`).
- `L10N_E0090` — A reviewed translation was left stale because `sync` does not overwrite human-reviewed entries (previously `L10N_E0064` in `sync`; `check` continues to use `L10N_E0064` for its own stale-source-hash diagnostic).

---

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
