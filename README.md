# l10n-agent

> Warning: this is an early-stage build. It may rewrite localization files in ways you do not expect. Use it at your own risk, review diffs carefully, and test on a throwaway branch first.

`l10n-agent` is a local-first CLI for iOS and Android localization workflows. It keeps a canonical JSON source of truth under `l10n/`, syncs native platform files, translates missing strings through a local Codex CLI session, preserves reviewed edits, enforces key style rules, and helps clean up duplicate or conflicted localization state without introducing a hosted backend.

Release history for the implemented CLI is tracked in `CHANGELOG.md`. `PRD.md` remains in the repo as historical planning context, but `README.md` and `AGENTS.md` are the authoritative docs for the current implementation.

## What this project is for

`l10n-agent` is aimed at solo developers and small teams shipping native iOS and Android apps who want:

- one canonical source of truth in git
- deterministic CI checks
- native platform files committed in the repo
- local AI-assisted translation without standing up a backend
- safe handling of reviewed translations, stale copy, duplicate keys, and merge conflicts

The intended workflow is:

1. You own source copy in `l10n/source.<locale>.json`.
2. `l10n-agent` owns derived translations and native localization files.
3. Your app code references localization keys, not final human text literals.

## Scope and boundaries

The current build supports:

- native iOS `.xcstrings` and `Localizable.strings`
- native Android `strings.xml`
- local Codex CLI as the only provider-backed path
- deterministic local files committed to git

The current build does not include:

- hosted services or remote state
- OTA/runtime translation delivery
- human-translator web workflows
- non-mobile targets such as web, React Native, or Flutter
- plural resource authoring support

Plural ICU syntax is not supported. If source text contains plural syntax, the tool will fail loudly rather than guess.

## Key ideas

- The canonical source file is authoritative: `l10n/source.<source_locale>.json`
- Each target locale has its own file: `l10n/translations.<locale>.json`
- Native platform files are derived outputs that stay committed so apps build normally
- Persisted JSON is stable-sorted for predictable diffs and lower merge-conflict churn
- Reviewed translations are never silently overwritten
- Removed locales are archived under `l10n/.archive/`, not hard-deleted

## Command surface

- `init`
  Scaffold `l10n/`, detect native localization files, preflight Codex, and optionally import existing strings.
- `sync [--dry-run] [--strict] [--locale <locale>] [--continue]`
  Reconcile source, translations, cache, history, and native platform files. Reviewed stale entries are preserved and warned on. Removed locales are archived.
- `lint [--glossary] [--fix]`
  Validate key naming rules and, with `--glossary`, verify persisted translations preserve configured glossary terms. `--fix` uses the local Codex CLI to propose safe destination keys, applies the rename across managed localization files, and rewrites exact key-string references in supported repo code/config text files.
- `status [--locale <locale>]`
  Show whether a sync is currently running or was interrupted, how many translations are complete, and how much work remains per locale.
- `check [--fast]`
  Deterministic CI gate for lint failures, missing translations, stale entries, orphaned keys, and platform drift.
- `doctor`
  Report locale coverage, reviewed vs. machine-translated counts, platform status, cache/history state, and next-sync request estimates when Codex is available.
- `dedupe`
  Report exact duplicate source copy deterministically and semantic duplicate candidates through the provider. It never auto-merges keys.
- `rename <from> <to>`
  Rename a canonical key across source, translations, history, and native platform files in one pass.
- `rollback --to <history-id>`
  Restore managed localization files to the snapshot taken before a history entry.
- `import --from <xcstrings|android>` (`xcstrings` covers iOS `.xcstrings` and `Localizable.strings`)
  Import source and reviewed translations from native platform files.
- `repair [--dry-run]`
  Re-canonicalize managed JSON files and auto-merge simple disjoint-key git conflict markers.

## Requirements

- Node.js 20+
- Git
- Codex CLI installed and authenticated with `codex login` for `sync`, `dedupe`, and `lint --fix`

Deterministic commands such as `lint`, `check`, `repair`, `rollback`, and `import` do not require live provider calls. The exception is `lint --fix`, which uses the local Codex CLI to propose destination keys before applying the rename.

## Install

Build the package in this repo:

```bash
npm install
npm run build
npm link
```

Then in any other folder, such as your iOS or Android app repo:

```bash
l10n-agent --help
l10n-agent init
```

If you want a fixed global install instead of a live link:

```bash
npm install -g /path/to/l10n-agent
```

`npm link` is usually better while you are developing this repo, because rebuilding here immediately updates what the global `l10n-agent` command uses without reinstalling.

For local development in this repo:

```bash
npm test
npm run dev -- --help
```

## Repository layout

```text
l10n/
  config.yaml
  source.en.json
  translations.de.json
  translations.es.json
  .cache.json
  .history.jsonl
  .state.json
  .archive/
  .snapshots/
```

Important file meanings:

- `l10n/config.yaml`
  Declares source locale, target locales, key style rules, platform paths, provider settings, and glossary.
- `l10n/source.<locale>.json`
  Canonical source copy written by humans.
- `l10n/translations.<locale>.json`
  Per-locale translations written by the tool and optionally reviewed by humans.
- `l10n/.cache.json`
  Translation cache keyed by source hash, locale, provider config hash, and model version. Changing the glossary or provider settings automatically invalidates affected entries.
- `l10n/.history.jsonl`
  Append-only operational history.
- `l10n/.state.json`
  Partial-run resume marker for interrupted provider-backed syncs.
- `l10n/.archive/`
  Archived translation files for removed locales.
- `l10n/.snapshots/`
  Rollback snapshots of managed localization files.

## Data model

Example canonical source file:

```json
{
  "version": 1,
  "keys": {
    "onboarding.welcome.title": {
      "text": "Welcome home, {name}",
      "description": "First-launch hero. Friendly tone.",
      "placeholders": {
        "name": {
          "type": "string",
          "example": "Jacob"
        }
      }
    }
  }
}
```

Example translation file:

```json
{
  "version": 1,
  "locale": "de",
  "entries": {
    "onboarding.welcome.title": {
      "text": "Willkommen zu Hause, {name}",
      "reviewed": false,
      "stale": false,
      "source_hash": "sha256:7f...",
      "provider": "codex-local",
      "model_version": "gpt-5-2026-03-01",
      "translated_at": "2026-04-18T12:00:00Z"
    }
  }
}
```

Meaningful entry fields:

- `reviewed: true`
  Human-reviewed translation. `sync` will not silently overwrite it.
- `stale: true`
  Source text changed after the translation was last considered current.
- `source_hash`
  Tracks whether a translation still matches the current source text.

## Provider and safety behavior

`l10n-agent` shells out to `codex` and uses the local session established by `codex login`. No API key or hosted service is required.

Provider-backed commands preflight:

- Codex installed
- authenticated session available
- installed Codex version meets the configured minimum

If preflight fails, the tool returns actionable errors:

- `L10N_E0050`
  Codex CLI is not installed.
- `L10N_E0051`
  Codex is installed but not logged in.
- `L10N_E0052`
  Codex version is below the configured minimum.

`sync` runs in the foreground, but it now writes in-flight progress to `.state.json` so another terminal can inspect status while the command is still active.

If a provider-backed `sync` fails mid-run:

- completed translation work is already persisted
- `.state.json` records the partial state
- history records partial completion
- rerunning `sync` resumes from the remaining delta
- `sync --continue` can be used as a script-safe guard that refuses to start from scratch

## Step-by-step setup

### A. Existing iOS or Android localization setup

Use this when the app already has committed iOS string files (`.xcstrings` or `Localizable.strings`), Android `strings.xml`, or both.

#### 1. Build and link the CLI

```bash
npm install
npm run build
npm link
```

#### 2. Install and log in to Codex

```bash
codex login
```

`init` will still scaffold files if Codex is missing, but `sync` and `dedupe` need a working Codex install.

#### 3. Run `init`

From the app repo root:

```bash
l10n-agent --help
l10n-agent init
```

What happens:

- platform localization files are auto-detected where possible (`.xcstrings`, `*.lproj/Localizable.strings`, and Android `strings.xml`)
- `l10n/config.yaml` is created
- `l10n/source.<locale>.json` is created
- existing platform strings are imported into canonical source and target translation files
- Codex preflight status is printed

If auto-detection is wrong or incomplete, pass paths explicitly:

```bash
l10n-agent init --ios-path ios/MyApp/Localizable.xcstrings --android-path android/app/src/main/res/values/strings.xml

# or with legacy iOS strings files
l10n-agent init --ios-path MyApp/en.lproj/Localizable.strings
```

#### 4. Review the generated config

Check:

- `source_locale`
- `target_locales`
- `platforms.ios.path`
- `platforms.android.path`
- `keys.case`
- `keys.max_depth`
- `keys.scopes`
- `provider.model` if you want to pin Codex to a specific model for provider-backed commands
- `provider.glossary`

Optional provider model pin:

```yaml
provider:
  type: codex-local
  codex_min_version: 0.30.0
  model: gpt-5.1
  glossary: {}
```

When `provider.model` is set, `sync`, `dedupe`, and `lint --fix` pass that model to the local Codex CLI. If you omit it, Codex uses its default model selection.

#### 5. Inspect current health

```bash
l10n-agent doctor
l10n-agent check
```

Use `doctor` to understand existing coverage and `check` to find drift or missing entries.

#### 6. Preview the first reconciliation

```bash
l10n-agent sync --dry-run
```

This shows:

- missing translations
- stale translations
- removed entries
- cache hits (skipped provider calls)
- estimated provider requests
- reviewed-stale skips

#### 7. Apply the first sync

```bash
l10n-agent sync
```

This will:

- fill in missing target-locale entries
- rewrite native platform files from canonical JSON
- preserve reviewed translations
- persist cache and history

#### 8. Add a new locale and translate it

Add the locale to `l10n/config.yaml`:

```yaml
target_locales:
  - de
  - es
  - fr
```

Preview the work:

```bash
l10n-agent sync --dry-run
```

Run translation and write the derived files:

```bash
l10n-agent sync
```

This creates `l10n/translations.fr.json` if it does not already exist, translates all existing source keys for `fr`, updates iOS localization files, and updates Android string resources.

Verify the result:

```bash
l10n-agent doctor
l10n-agent check
```

If you want to translate only one locale during a run:

```bash
l10n-agent sync --locale fr
```

#### 9. Add a new key and translate it

Add the key to `l10n/source.en.json`:

```json
"settings.notifications.title": {
  "text": "Notifications",
  "description": "Settings row title.",
  "placeholders": {}
}
```

Then run:

```bash
l10n-agent sync --dry-run
l10n-agent sync
```

#### 10. Start normal maintenance

For copy changes:

1. Edit `l10n/source.<locale>.json`
2. Run `l10n-agent sync --dry-run`
3. Run `l10n-agent sync`
4. Run `l10n-agent check`

### B. Project with no localization setup yet

Use this when the app still contains hard-coded UI strings and no real native localization structure.

The goal is to:

1. create native localization containers
2. establish canonical keys
3. replace hard-coded app strings with key-based lookups
4. let `l10n-agent` manage the localized content from then on

#### 1. Create minimal native localization containers

You need at least one managed platform file so `init` has a target.

For iOS:

- create an iOS localization container:
  - `.xcstrings` catalog such as `ios/MyApp/Localizable.xcstrings`, or
  - `Localizable.strings` at `MyApp/en.lproj/Localizable.strings`

For Android:

- create `android/app/src/main/res/values/strings.xml`
  It can start nearly empty:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
</resources>
```

If the project supports only one platform, that is enough. If it supports both, create both upfront.

#### 2. Initialize `l10n-agent`

```bash
l10n-agent init --source-locale en --target-locale de --target-locale es --no-import-existing
```

Use `--no-import-existing` when there is nothing useful to import yet.

This creates:

- `l10n/config.yaml`
- `l10n/source.en.json`
- `l10n/translations.de.json`
- `l10n/translations.es.json`

#### 3. Define your first keys in canonical source

Example:

```json
{
  "version": 1,
  "keys": {
    "onboarding.welcome.title": {
      "text": "Welcome",
      "description": "Onboarding screen title.",
      "placeholders": {}
    },
    "settings.privacy.title": {
      "text": "Privacy",
      "description": "Settings row title.",
      "placeholders": {}
    }
  }
}
```

#### 4. Run the first sync

```bash
l10n-agent sync
```

This generates:

- target-locale translation JSON files
- iOS localization entries
- Android localization resources

#### 5. Replace hard-coded app strings with localization lookups

This is the key migration step. After a key exists in canonical source and has been synced, update the app code to reference the key instead of a human text literal.

Typical iOS pattern:

```swift
Text(String(localized: "onboarding.welcome.title"))
```

or with Foundation APIs:

```swift
NSLocalizedString("onboarding.welcome.title", comment: "")
```

Typical Android pattern with the default `snake_case` transform:

Canonical key:

```text
onboarding.welcome.title
```

Android resource key after transform:

```text
onboarding_welcome_title
```

Lookup:

```kotlin
context.getString(R.string.onboarding_welcome_title)
```

#### 6. Continue replacing hard-coded strings incrementally

For each screen or feature:

1. add canonical keys to `source.en.json`
2. run `sync`
3. replace code literals with localization lookups
4. remove obsolete hard-coded strings from code

This lets you migrate a previously unlocalized app gradually rather than all at once.

### C. Converting an app that already has localization files but still uses raw user-facing text in code

This is common in partial migrations.

Recommended order:

1. Run `init` and import existing platform strings.
2. Normalize keys in canonical source with `lint --fix` for batch-safe cleanup or `rename` when you want to control the exact destination key.
3. Run `dedupe` to identify exact or semantic duplicate strings before wiring more code to them.
4. Replace hard-coded code literals with lookups to the imported canonical keys.
5. Keep copy edits in `l10n/source.<locale>.json`, not directly in app code or native localization files.

## Working with keys

Recommended approach:

- use semantic, stable keys such as `onboarding.welcome.title`
- avoid keys that mirror current English wording
- keep the same key across platforms
- use `lint --fix` for safe batch cleanup and `rename` when you want an explicit destination key

Key style is enforced by config:

- `case`
- `max_depth`
- `scopes`
- `forbidden_prefixes`

Android usually uses `snake_case` as a platform transform while canonical keys stay dotted.

## Typical day-to-day workflow

1. Add or edit canonical source keys in `l10n/source.<locale>.json`
2. Run `l10n-agent lint`
3. If key-style violations are straightforward, run `l10n-agent lint --fix` to apply Codex-suggested renames and rewrite exact key-string references in supported repo code/config text files
4. Run `l10n-agent sync --dry-run`
5. Run `l10n-agent sync`
6. Review generated diffs
7. Run `l10n-agent check`

When changing locale configuration:

- add a locale to `target_locales` and run `sync` to generate it
- remove a locale from `target_locales` and run `sync` to archive it and strip native outputs

When handling translation quality:

- set `reviewed: true` after a human correction
- use `lint --glossary` to verify glossary preservation
- use `dedupe` before proliferating near-duplicate keys

When handling repo conflicts:

- run `repair --dry-run`
- if safe, run `repair`
- use `rollback --to <history-id>` if a managed localization operation needs to be reverted

## Development

To work on the CLI codebase:

```bash
npm install
npm run build
npm test
npm run repo:public-check
```

After `npm link`, use the installed binary directly:

```bash
l10n-agent check
l10n-agent doctor
l10n-agent dedupe
l10n-agent repair --dry-run
l10n-agent sync --dry-run
```

When working on the TypeScript source and you want to skip the build step, `npm run dev` runs the source directly via `tsx`:

```bash
npm run typecheck
npm run dev -- check
npm run dev -- sync --dry-run
```

## Testing and publish safety

- Tests stay offline. Provider-backed flows use recorded Codex fixtures rather than live requests.
- Persisted JSON is stable-sorted for predictable diffs and lower merge-conflict churn.
- `npm run repo:public-check` runs the secret scan and inspects the publish payload with `npm pack --dry-run`.
- The published package includes `dist/`, `README.md`, and `CHANGELOG.md`.

Do not commit:

- `.env*`
- API keys or auth dumps
- private keys or provisioning artifacts
- recorded provider output that contains user-specific secrets
