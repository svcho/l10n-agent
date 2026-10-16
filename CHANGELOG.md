# Changelog

All notable changes to `l10n-agent` are documented here.

## 0.5.0 — 2026-10-16

Follow-up to the pangi rerun (R1–R11 in `docs/plan-trial-fixes.md`).

- `l10n-agent keys remove` / `keys rename` (MCP `l10n_remove_keys`, `l10n_rename_key`): remove unused keys, or rename keys with their translations, review states, source text and fingerprints. Renames of keys that code uses need `--update-code`, which rewrites only localization lookups; keys also used as plain or built strings are refused. Remove refuses extracted and `InfoPlist`/`AppShortcuts` keys without `--force`, and MCP has no force.
- New rule L10N113 (malformed-translation): JSON-wrapped or code-fenced translations; `translate` rejects such model output.
- `set-translation --replace-approved` replaces a broken approved plain value (written as `needs_review`).
- L10N106 counts references per target, so a key used only by another target's catalog is reported.
- Files that only test targets compile (pbxproj synchronized folders) are not scanned.
- `migrate` keeps more comments: group comments apply to their block, then `comment:` from code, then section comments; file titles are skipped. On pangi it now keeps nearly as many comments as a hand-written script.
- `NSError` messages need review before fixing, and use the catalog's `error.` scope; long phrases keep their last word in key names.
- `status` lists keys without text and *Don't translate* keys as not counted, and `--fail-under` prints the failing catalogs.
- MCP tools refuse arguments they do not declare.
- `--version` reports 0.5.0.

## 0.4.0 — 2026-10-09

Rewrite in Swift, Apple platforms only. The String Catalog (`.xcstrings`) is now the source of truth; the TypeScript CLI, the `l10n/` JSON store and Android support are removed. See `docs/audit-and-apple-redesign.md` for the reasons (lossy round trips, placeholder argument numbering, `sync --locale` deleting other locales, among others).

### New

- `lint`: SwiftSyntax scanner for unlocalized UI text (L10N001), English-text keys (L10N002), concatenation and `String(format:)` (L10N003), missing keys (L10N004), plural candidates (L10N005) and letterless extracted literals (L10N006), plus catalog rules L10N100-L10N112. Output as text, Xcode build-phase diagnostics, JSON or SARIF. Inline `// l10n-agent:ignore` suppressions.
- `fix`: plans and applies code + catalog fixes with semantic keys and translator comments. Uses Xcode 26 generated symbols (`Text(.key)`, table namespaces) or `String(localized:defaultValue:comment:)`. Migrates existing translations from English-text keys. Plans can be saved, edited and re-applied; apply refuses when files changed. `--llm-keys` asks the local model for key names.
- `translate`: batched translation through Ollama or OpenAI-compatible local servers, with placeholder masking, positional reordering, CLDR plural categories, substitutions, glossary enforcement, retries with feedback, and `needs_review` output. Remote endpoints and cloud models are refused unless explicitly allowed.
- `status`, `doctor`, `init`, `accept`, `rules`.
- `mcp`: stdio MCP server with lint, status, plan/apply fixes, translate, set translations, add keys and accept tools.
- Claude Code skill in `skills/apple-l10n`.
- Catalog serialization verified byte-for-byte against `xcstringstool`; symbol naming verified against `xcstringstool generate-symbols`; fixed code type-checked against generated symbols in the test suite.

### Hardening from the independent review and live model runs

- Approved translations are never overwritten, not even single plural categories. Structural mismatches are reported as *approved skipped*.
- Fixes never drop surrounding code (ternaries, `??`, `bundle:` arguments). They keep `comment:` arguments, and add `bundle: .module` inside Swift packages.
- `fix --apply` treats plans as untrusted: it re-scans sources, restricts catalogs to the project, and touches catalogs only for applied edits.
- Paths are confined to the project root through symlinks. Provided translations must target configured locales. Remote translators need an environment opt-in.
- Full CLDR plural-category table plus a `pluralCategories` override; unknown languages are reported instead of assumed to be `one/other`. Device variations count toward completeness. L10N004 and named-table fixes are scoped to the file's own target, and new tables keep their name. Glossary checks cover every variation. Unknown plural rules are reported even when an `other` form exists. Glossary validation during translation compares each plural form with its own source form. `translate --catalog` keeps the project-wide locale set. Provided translations must name the catalog when a key is ambiguous. English-text keys stay live while other code still uses them. Symbol rewrites are decided per project and target. Apply validates state before writing sources. `init` writes under a single lock. `%*d` widths count as arguments. Only debug-only `#if` branches are skipped. Sibling resource catalogs resolve through the owning Xcode project. L10N110 is limited to symbol-generating targets. Provided plural forms can fill categories next to approved ones. `% d` is recognized. The secret scan checks staged blobs. Fix-time symbol checks are per file. Plural forms are validated against their own source form. Non-JSON numbers are rejected. Typed `LocalizedStringResource` declarations get type-correct rewrites. Key lookups, fingerprints and `--key` filters are byte-exact. `init` pins `catalog:` only when unambiguous. Blank catalogs are reported. Migrations merge missing variation leaves. Approved substitution forms no longer block the root string. `init` stops on malformed catalogs before writing. Provided forms keep the staleness of approved neighbors. Fix planning tracks keys byte-exactly. The secret scan can no longer be fooled by SIGPIPE. `init` leaves `locales` unset when none are detected. Sibling catalogs in a shared project resolve per target. Malformed fingerprint stores are rejected. Symlinks leaving the project are ignored during discovery. Migrations keep source-language variations. `l10n_add_keys` requires a catalog when ambiguous. New `catalogRoutes` config for split Sources/Resources layouts. Translation groups are byte-exact. Concatenations inside calls with other arguments are not rewritten. Colocated Xcode projects no longer decide symbol generation arbitrarily. Language-specific plural/device variations count as complete. Substitution metadata is part of fingerprints and L10N104. The secret scan also reads binary files. `fix --apply`, `translate` saves and `l10n_add_keys` are transactional: catalogs (and fingerprints) are written together, before code, and any failed write rolls everything back. Non-literal `table:`/`comment:` arguments block whole-call rewrites.
- Translation requests use per-request item ids, retry one item at a time, detect shifted answers, reject plural forms that hard-code the count, and repair broken machine translations.

### From the first real-repo trial (pangi: iOS, watchOS, macOS, widgets, AutoFill; 692 keys)

- **Breaking:** `lint --fail-on` defaults to `warning` (was `error`): missing or stale translations and unlocalized text now fail `lint`. Use `--fail-on error` for the old behavior. Label- or name-only fixes are `needsReview`.

- **Fix correctness.** A key passed to a function the project declares with a `LocalizedStringKey`/`LocalizedStringResource` parameter is treated as a lookup and never rewritten into a `defaultValue` that would not compile. Existing keys shown as is at a known UI API are reported as raw keys.
- **Fewer false positives.** L10N001 hits on pangi went from 161 to 3, all real.
  - Queue, lock and log names (`DispatchQueue(label:)`) and dotted identifiers are ignored.
  - Properties used only in logging calls are ignored.
  - Generated files are skipped.
  - Text found only by a label or name needs review before it is fixed.
- **Better fixes.**
  - Placeholder specifiers come from declared types (`UInt32` → `%u`).
  - New keys follow the keys the type already uses, or the catalog's dominant prefix.
  - Comments name the member.
  - Previews of edited plans show exactly what apply writes.
- **Configuration.**
  - `codeStyle: auto` ignores unit and UI test bundles, and `doctor` names the configurations that turn symbols off.
  - `doctor` says when a translator is remote.
  - `init` infers the key style and depth from existing keys, notes cloud models, and takes `--allow-remote`.
  - `translate --dry-run` warns when a real run would be refused.
  - Key segments after the first may start with a digit.
  - Glossary terms may list several forms (`de: [Konto, Konten]`).
  - New `translator.instructions` for style guidance such as formality.
- **New features.**
  - `l10n-agent migrate` (and MCP `l10n_migrate_strings`) converts `.strings`/`.stringsdict` to String Catalogs. It was verified on pangi's 692 English and 692 German values with nothing lost.
  - `l10n-agent set-translation`.
  - `status --fail-under`. `lint` now fails on warnings by default.
  - L10N006 marks letterless extracted literals *Don't translate*, and `l10n_add_keys` accepts `shouldTranslate: false`.
  - L10N106 reports unused manual keys (`keys.dynamicPrefixes` for runtime keys).
  - L10N112 suggests plural variations from catalog values.
  - `NSError` `userInfo` messages are detected.

### Removed

`sync`, `check`, `dedupe`, `rename`, `rollback`, `import`, `repair`, Android `strings.xml`, `Localizable.strings`, Codex CLI provider, and the `l10n/` canonical JSON files.

## 0.3.1-beta.0 — 2026-04-25

### Correctness fixes

**Persisted translation placeholder parity** — `check`, `sync`, and `import` now validate placeholder parity for existing/imported translation JSON, not only fresh provider output. A translation whose `source_hash` matches but whose text drops, duplicates, or reorders positional placeholders now emits `L10N_E0041`.

**Android BCP-47 locale directories** — Android output now uses `values-b+...` qualifiers for locales that cannot be represented by legacy `values-xx` / `values-xx-rYY` directories, such as `zh-Hant-TW` and `es-419`.

### Reliability fixes

**SIGINT lock cleanup** — Interrupted `sync` runs now detach the active sync context before async cleanup and prevent released lock handles from being refreshed back onto disk.

**Greenfield init containers** — `init --no-import-existing` now creates empty native containers for explicit iOS and Android paths when they do not already exist.

**Repair lock boundary** — Non-dry-run `repair` now acquires the sync lock before loading and scanning managed localization files, then holds it through snapshots and rewrites.

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
