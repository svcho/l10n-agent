# l10n-agent — Product Requirements Document

**Status:** Draft v1
**Owner:** Jacob Suchorabski
**Last updated:** 2026-04-18

---

## 1. Summary

`l10n-agent` is a local-only, CLI-first localization tool for solo devs and small teams shipping iOS and Android apps. A single command keeps a canonical source-of-truth in sync with native platform files, translates missing strings via a pluggable AI provider, enforces a declared key-naming style, and detects duplicates across platforms. No server, no hosted backend, no runtime SDK — everything lives in the repo and runs on the dev's machine or in CI.

Codex CLI drives the judgment-heavy operations (translate, semantic dedupe) via its local server mode — piggybacking on the user's existing ChatGPT subscription, so no API key or billing setup is required. The rest is deterministic TypeScript.

---

## 2. Problem

Solo devs and small teams shipping mobile apps handle localization in one of two unsatisfying ways:

1. **By hand.** Editing `Localizable.strings` (or `.xcstrings`) and `strings.xml` directly, running DeepL or Google Translate manually, copy-pasting results. Keys drift between platforms. Stale translations linger after source copy changes. Placeholder formats break.
2. **Via SaaS** (Lokalise, Phrase, Crowdin). Priced and designed for teams with dedicated human translators. Overkill for a two-person team that just needs Spanish and German to not be embarrassing.

Concrete symptoms of the problem:

- Keys drift between platforms (`save_cta` on iOS, `cta_save_button` on Android). QA finds it.
- Adding a key means editing two files and re-running MT by hand.
- Placeholder/plural formats differ per platform; translators break them; app crashes.
- Stale translations linger after source copy changes with no signal.
- No shared convention for key naming, so the keyspace rots over time.

---

## 3. Target user

### In scope

- Solo dev or team of 2–10 shipping iOS and/or Android apps.
- Comfortable editing a YAML config and running a CLI.
- Has Codex CLI installed and logged in via `codex login` (uses the user's existing ChatGPT subscription — no API key or billing setup required).
- Uses git.
- Can accept that new translations ship with the next app release (no OTA).

### Explicitly out of scope

- Teams with dedicated human translators who expect a CAT tool UI.
- Teams where translators and devs live in separate organizations.
- Enterprise RBAC, SSO, audit logs.
- Real-time OTA translation updates without a release.
- Non-mobile targets (web, RN, Flutter — deferred).

---

## 4. Goals and non-goals

### Goals

1. A dev can add a key to `l10n/source.en.json` and have it translated and written to iOS `.xcstrings` and Android `strings.xml` with one command.
2. The tool detects added, removed, and renamed keys; semantic duplicates across platforms; and style violations — with clear output.
3. Human-reviewed translations are never silently overwritten.
4. The same config behaves identically on every team member's machine and in CI.
5. Time-to-first-translation on a fresh repo is under five minutes.

### Non-goals

- Runtime (OTA) translation delivery.
- A web UI, hosted service, or multi-user backend.
- Human-translator workflows (review assignments, comments, TM/TB management).
- Automatic locale detection or discovery — the user declares supported locales.
- Universal format support — v1 is strictly iOS + Android.

---

## 5. User stories

### Core flows

**US-1 · Bootstrap (`init`).** As a new user, I run `l10n-agent init` in my repo and get a scaffolded `l10n/source.en.json`, `l10n/config.yaml`, `.gitignore` entries, and a brief printed next-steps summary. The wizard offers to import my existing `Localizable.strings`/`strings.xml` into `source.en.json` as the starting source. No network calls during init.

**US-2 · Add a key (`sync`).** I add `onboarding.welcome.title = "Welcome"` to `source.en.json` and run `l10n-agent sync`. The tool validates the key against my style config, translates it to every target locale, writes it into both platform files (with any configured key transform), and updates the translation cache. All new translations are flagged `reviewed: false`.

**US-3 · Update source copy.** I change `onboarding.welcome.title` from "Welcome" to "Welcome home". `sync` marks every target-language copy of that key as `stale`, re-translates ones where `reviewed: false`, and for `reviewed: true` prints a warning and skips them (opt-in `--force-restale-reviewed` overrides).

**US-4 · Delete a key.** I remove a key from `source.en.json`. `sync` removes it from every platform file and every locale, and appends a deletion record to `l10n/.history.jsonl`.

**US-5 · Rename a key.** I run `l10n-agent rename onboarding.welcome.title onboarding.hero.title`. The tool updates the source, every translation file, every platform file, the cache, and the history log in a single transactional pass. Refuses if the new name fails lint.

**US-6 · Style lint (`lint`).** I run `l10n-agent lint`. The deterministic linter enforces my declared case, segment skeleton, max depth, scope whitelist, and forbidden prefixes. Human-readable output by default, `--json` for CI, non-zero exit on failure. Zero model calls.

**US-7 · Duplicate detection (`dedupe`).** I run `l10n-agent dedupe`. Exact-duplicate source copy under different keys is flagged deterministically. Semantic near-duplicates (`cta.save` vs `button.save_item` with identical English copy) are flagged by the provider. The tool proposes a merge with a rename migration — it never auto-merges.

**US-8 · Manual translation override.** A bilingual teammate edits `translations.de.json`, fixes a translation, and sets `reviewed: true`. Future `sync` runs leave the entry untouched. If the source copy later changes, the entry is marked `stale: true` and surfaced in `doctor`, but is not overwritten.

**US-9 · CI gate (`check`).** In CI I run `l10n-agent check`. It fails the build if platform files are out of sync with the canonical source, any key fails lint, or any locale has missing translations. Fully deterministic — no model calls, no writes, no API key required.

**US-10 · Doctor (`doctor`).** `l10n-agent doctor` prints a cross-platform health report: keys per platform, missing translations per locale, reviewed vs machine-translated counts, last-sync timestamp, estimated Codex request count for the next `sync` run, and the detected Codex CLI version and login status.

### Locale management

**US-11 · Add a target locale.** I add `it` to `target_locales` in `config.yaml` and run `sync`. The tool translates every existing key into Italian, writes Italian values into the platform files, and creates `translations.it.json`. No other locales are touched.

**US-12 · Remove a target locale.** I remove `fr` from `target_locales` and run `sync`. The tool archives `translations.fr.json` to `l10n/.archive/translations.fr.<timestamp>.json`, strips French from the platform files, and records the removal in history. No data is hard-deleted — archived files stay in git.

### Safety and preview

**US-13 · Dry run.** Any mutating command accepts `--dry-run`. The tool computes and prints the full diff (keys added, removed, renamed; translations to be generated; platform-file changes; estimated Codex request count) without writing any file or invoking the provider.

**US-14 · Multi-dev merge conflicts.** Two devs each add a key on separate branches. When branches merge, the JSON files conflict on text boundaries but not on structure (keys are objects, ordering is stable). `l10n-agent repair` re-canonicalizes JSON file ordering and detects the most common conflict shapes, offering a three-way auto-merge where safe and a clear diff where not.

**US-15 · Rollback.** `l10n-agent rollback --to <history-entry-id>` reverts the source, translations, and platform files to the state before a given history entry, creating a new history entry for the rollback itself. History is append-only; rollback never deletes prior entries.

### Integrations and migration

**US-16 · Import from existing tools.** `l10n-agent import --from <lokalise|phrase|crowdin|xcstrings|android>` ingests translations from an existing source into the canonical store. For SaaS sources it accepts a local export file (no API keys for third-party SaaS in v1); for platform formats it reads the committed files.

**US-17 · Glossary enforcement.** I declare a glossary in `config.yaml` (`"Premium" → de: "Premium"`). During `sync`, the provider receives the glossary in its prompt and must preserve the term. `lint --glossary` verifies existing translations honor the glossary and flags violations. Never auto-fixes violations.

**US-18 · Placeholder safety.** Every translation pass verifies that the target text contains the same ICU placeholders as the source (same names, same count). A mismatch aborts the write for that key with a clear error; other keys in the same `sync` proceed. A `sync --strict` flag aborts the entire run on any placeholder mismatch.

### Resilience and provider failure modes

**US-19 · Codex is missing, logged out, or incompatible.** Before any command that needs the provider (`sync`, `dedupe`, `doctor` with request estimate), the tool runs a preflight check: `codex` is on `PATH`, an authenticated session exists, and the installed version is at or above the pinned minimum. Each failure returns a distinct error code with an exact remediation:

- **Not installed** (`L10N_E0050`): "Install Codex CLI — see https://github.com/openai/codex. Then run `codex login`."
- **Not logged in or session expired** (`L10N_E0051`): "Run `codex login` to sign in with your ChatGPT account."
- **Version too old** (`L10N_E0052`): "Detected Codex 0.25.1; l10n-agent v1 requires ≥ 0.30.0. Upgrade via your package manager."

All three fail fast with exit code 1. No partial run is attempted. `init` runs the same preflight so problems surface immediately, not on first `sync`.

**US-20 · Mid-operation provider failure.** During `sync`, if Codex returns a rate-limit or quota error, a network failure, or the subprocess exits unexpectedly:

- Every completed translation is already persisted — translation files are flushed after each successful batch and the cache is updated per translation.
- A partial-run marker is written to `l10n/.state.json` capturing the last-processed key, locale, and batch index.
- A history entry records the partial completion with counts (e.g. `47 of 312 translations completed`).
- The tool prints a clear message with the matching error code — `L10N_E0053` for rate limit or quota, `L10N_E0054` for subprocess crash, `L10N_E0055` for protocol parse failures — and exits with code 3 (retryable).
- Every on-disk write is atomic (write-temp then rename), so no file is ever left half-written.

**US-21 · Resume a partial operation.** `sync` is inherently resumable: it always computes the delta between source and existing translations, so re-running it after any failure picks up only the remaining work — no `continue` command required. When `.state.json` exists, the next `sync` prints a one-line banner ("Resuming partial sync from 2026-04-18T12:03:11Z — 265 translations remaining") so the user knows they're continuing and not restarting. `.state.json` is deleted on clean completion. `sync --continue` exists as a script-safety alias: it errors if no `.state.json` is present, which is useful in automated wrappers that must never silently "start from scratch."

---

## 6. Onboarding walkthrough

Target time to first translation: **under five minutes** on a repo that already has some `Localizable.strings` or `strings.xml`.

### Step 1 — install

```bash
npm i -g l10n-agent
# or, per-invocation
npx l10n-agent <command>
```

Required: Node 20+, git.

### Step 2 — install Codex CLI and log in

```bash
# Install Codex CLI (follow current OpenAI Codex install docs for your OS)
brew install openai/tap/codex

# One-time auth via your ChatGPT account
codex login
```

`l10n-agent` shells out to `codex` and uses whichever session `codex login` established — no API key, no billing setup. `init` and `check` do not require Codex; `sync`, `dedupe`, and `doctor` with request estimation do. `init` runs a Codex preflight so any install or auth problems are surfaced up front, not on first `sync`.

### Step 3 — run init

```bash
cd my-mobile-app
l10n-agent init
```

Interactive wizard (all choices editable later in `config.yaml`):

```
? Source locale (the one you write in) › en
? Target locales (comma-separated) › de,es,fr
? Import existing strings? › (Y/n)
   ? iOS path › ./ios/MyApp/Localizable.xcstrings  [detected]
   ? Android path › ./android/app/src/main/res  [detected]
? Key style convention › dotted.lower
? Key-style max depth › 4

Creating l10n/config.yaml
Creating l10n/source.en.json (312 keys imported)
Creating l10n/translations.de.json (245 keys imported, 67 missing)
Creating l10n/translations.es.json (198 keys imported, 114 missing)
Creating l10n/translations.fr.json (0 keys imported, 312 missing)
Updating .gitignore (no entries needed)

Next steps:
  1. Review l10n/config.yaml and tighten your style rules if desired.
  2. Run `l10n-agent doctor` to see the current state.
  3. Run `l10n-agent sync --dry-run` to preview what the first sync will do.
  4. Run `l10n-agent sync` to generate missing translations.
```

### Step 4 — dry-run preview

```bash
l10n-agent sync --dry-run
```

Prints the plan. Example:

```
Plan for sync:
  Source    en   312 keys  (unchanged)
  Target    de   67 new translations, 0 stale, 0 removed
  Target    es   114 new translations, 0 stale, 0 removed
  Target    fr   312 new translations, 0 stale, 0 removed
  Platforms ios  493 platform-key writes
  Platforms android  493 platform-key writes

Estimated: 493 Codex requests (uses your ChatGPT subscription — no per-token billing)
           Codex CLI detected: v0.32.1, logged in as jacob@…

Run without --dry-run to apply.
```

### Step 5 — run sync

```bash
l10n-agent sync
```

Progress bar, streaming results, exits non-zero on any failure with a clear error code.

### Step 6 — wire CI

`.github/workflows/l10n.yml`:

```yaml
- run: npx l10n-agent check
```

No API key needed in CI — `check` is deterministic.

### Step 7 — optional pre-commit hook

```bash
echo 'npx l10n-agent check --fast' >> .git/hooks/pre-commit
```

---

## 7. Architecture

```
l10n-agent/                    npm package, Node 20+, TypeScript
├── src/
│   ├── cli/                   commander entrypoints, pretty output
│   ├── core/
│   │   ├── store/             JSON-backed canonical store
│   │   ├── linter/            deterministic style rules
│   │   ├── differ/            key/translation diff engine
│   │   ├── pipeline/          sync orchestration
│   │   ├── placeholders/      ICU parse/emit + parity check
│   │   └── history/           append-only jsonl writer
│   ├── adapters/
│   │   ├── ios/               .xcstrings ↔ canonical
│   │   └── android/           strings.xml ↔ canonical
│   ├── providers/
│   │   ├── base.ts            TranslationProvider interface
│   │   └── codex-local.ts    Codex CLI subprocess + server-mode client
│   ├── config/                YAML loader + zod validation
│   └── errors/                typed errors with codes
├── fixtures/                  golden files for tests
├── test/                      vitest suites
└── docs/                      user-facing docs (generated)
```

Codex CLI is invoked **only** inside `providers/codex-local.ts`, which spawns `codex` in its local server mode and speaks the Codex protocol over stdio. Core orchestration is plain TypeScript — no provider-specific concerns leak into `core/`.

---

## 8. Data model

All files live under `l10n/`, all JSON (except `config.yaml`), all committed to git.

### Files

| Path                              | Purpose                                                | Who writes         |
| --------------------------------- | ------------------------------------------------------ | ------------------ |
| `l10n/config.yaml`                | User config                                            | Human              |
| `l10n/source.<src>.json`          | Canonical source (e.g. `source.en.json`)               | Human              |
| `l10n/translations.<locale>.json` | One per target locale                                  | Tool + human edits |
| `l10n/.cache.json`                | Translation cache (hash-keyed)                         | Tool               |
| `l10n/.history.jsonl`             | Append-only audit log                                  | Tool               |
| `l10n/.archive/`                  | Archived translations (removed locales)                | Tool               |
| iOS `.xcstrings`                  | Derived, committed so the app builds                   | Tool               |
| Android `strings.xml` (per res)   | Derived, committed so the app builds                   | Tool               |

### Shape examples

**`source.en.json`**
```json
{
  "version": 1,
  "keys": {
    "onboarding.welcome.title": {
      "text": "Welcome home, {name}",
      "description": "First-launch hero. Friendly tone.",
      "placeholders": {
        "name": { "type": "string", "example": "Jacob" }
      }
    }
  }
}
```

**`translations.de.json`**
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

**`.cache.json`**
```json
{
  "version": 1,
  "entries": {
    "sha256:7f...|de|gpt-5-2026-03-01": {
      "text": "Willkommen zu Hause, {name}",
      "cached_at": "2026-04-18T12:00:00Z"
    }
  }
}
```

**`.history.jsonl`** — one JSON object per line:
```jsonl
{"id":"01HXYZ...","ts":"2026-04-18T12:00:00Z","actor":"jacob","op":"sync","summary":"312 keys added, 493 translations generated"}
{"id":"01HXZA...","ts":"2026-04-18T13:00:00Z","actor":"jacob","op":"rename","before":"onboarding.welcome.title","after":"onboarding.hero.title"}
```

---

## 9. Zod schemas

These are the v1 source-of-truth schemas. File format `version` enables forward-compatible migrations.

```ts
// src/core/store/schemas.ts
import { z } from 'zod';

export const LocaleCode = z.string().regex(/^[a-z]{2}(-[A-Z]{2})?$/);

export const Placeholder = z.object({
  type: z.enum(['string', 'number', 'date']),
  example: z.string().optional(),
});

export const SourceKey = z.object({
  text: z.string().min(1),
  description: z.string().optional(),
  placeholders: z.record(z.string(), Placeholder).default({}),
});

export const SourceFile = z.object({
  version: z.literal(1),
  keys: z.record(z.string(), SourceKey),
});

export const TranslationEntry = z.object({
  text: z.string(),
  reviewed: z.boolean().default(false),
  stale: z.boolean().default(false),
  source_hash: z.string().regex(/^sha256:[0-9a-f]{64}$/),
  provider: z.string(),
  model_version: z.string(),
  translated_at: z.string().datetime(),
});

export const TranslationFile = z.object({
  version: z.literal(1),
  locale: LocaleCode,
  entries: z.record(z.string(), TranslationEntry),
});

export const CacheFile = z.object({
  version: z.literal(1),
  entries: z.record(
    z.string(),
    z.object({ text: z.string(), cached_at: z.string().datetime() }),
  ),
});

export const HistoryEntry = z.discriminatedUnion('op', [
  z.object({
    id: z.string(),
    ts: z.string().datetime(),
    actor: z.string(),
    op: z.literal('sync'),
    summary: z.string(),
  }),
  z.object({
    id: z.string(),
    ts: z.string().datetime(),
    actor: z.string(),
    op: z.literal('rename'),
    before: z.string(),
    after: z.string(),
  }),
  z.object({
    id: z.string(),
    ts: z.string().datetime(),
    actor: z.string(),
    op: z.literal('delete'),
    key: z.string(),
  }),
  z.object({
    id: z.string(),
    ts: z.string().datetime(),
    actor: z.string(),
    op: z.literal('add_locale'),
    locale: LocaleCode,
  }),
  z.object({
    id: z.string(),
    ts: z.string().datetime(),
    actor: z.string(),
    op: z.literal('remove_locale'),
    locale: LocaleCode,
  }),
  z.object({
    id: z.string(),
    ts: z.string().datetime(),
    actor: z.string(),
    op: z.literal('rollback'),
    to: z.string(),
  }),
]);
```

### Config schema

```ts
// src/config/schema.ts
import { z } from 'zod';
import { LocaleCode } from '../core/store/schemas';

export const KeyCase = z.enum([
  'dotted.lower',
  'snake',
  'kebab',
  'screaming_snake',
]);

export const KeyTransform = z.enum([
  'identity',
  'snake_case',
  'kebab-case',
]);

export const PlatformConfig = z.object({
  enabled: z.boolean().default(true),
  path: z.string(),
  key_transform: KeyTransform.default('identity'),
});

export const ProviderConfig = z.object({
  type: z.literal('codex-local'),
  codex_min_version: z.string().default('0.30.0'),
  model: z.string().optional(),   // if omitted, Codex picks per its own config
  glossary: z
    .record(z.string(), z.record(LocaleCode, z.string()))
    .default({}),
});

export const Config = z.object({
  version: z.literal(1).default(1),
  source_locale: LocaleCode,
  target_locales: z.array(LocaleCode).min(1),
  keys: z.object({
    case: KeyCase.default('dotted.lower'),
    max_depth: z.number().int().min(1).max(10).default(4),
    scopes: z.array(z.string()).default([]),
    forbidden_prefixes: z.array(z.string()).default([]),
  }),
  platforms: z.object({
    ios: PlatformConfig.optional(),
    android: PlatformConfig.optional(),
  }),
  provider: ProviderConfig,
});

export type Config = z.infer<typeof Config>;
```

---

## 10. CLI reference

| Command                                                 | Purpose                                              | Needs Codex | Writes |
| ------------------------------------------------------- | ---------------------------------------------------- | ----------- | ------ |
| `init`                                                  | Scaffold `l10n/`, preflight Codex, import strings    | No\*        | Yes    |
| `sync [--dry-run] [--strict] [--locale l] [--continue]` | Reconcile source → translations → platforms          | Yes         | Yes    |
| `lint [--json] [--glossary]`                            | Deterministic style + glossary check                 | No          | No     |
| `check [--fast]`                                        | CI gate: lint + cross-platform drift + coverage      | No          | No     |
| `dedupe`                                                | Flag exact and semantic duplicates                   | Yes         | No     |
| `doctor`                                                | Health report + next-sync request estimate           | No\*\*      | No     |
| `rename <from> <to>`                                    | Transactional rename across all files                | No          | Yes    |
| `rollback --to <history-id>`                            | Revert to a prior history state                      | No          | Yes    |
| `import --from <source>`                                | One-time import from an external format              | No          | Yes    |
| `repair`                                                | Re-canonicalize JSON ordering; fix merge artifacts   | No          | Yes    |

\* `init` preflights Codex and prints actionable remediation if anything is missing, but still scaffolds the config files so the user can keep going.
\*\* `doctor` runs without Codex but shows `unavailable` for the request-estimate and auth lines if Codex isn't installed or logged in.

Global flags: `--verbose`, `--json`, `--no-color`, `--cwd <path>`, `--config <path>`.

---

## 11. Adapter contract

```ts
// src/adapters/base.ts
export interface CanonicalKeySet {
  keys: Map<string, {
    text: string;
    placeholders: ICUPlaceholder[];
  }>;
}

export interface Adapter {
  readonly platform: 'ios' | 'android';

  read(path: string): Promise<CanonicalKeySet>;
  write(path: string, keys: CanonicalKeySet, locale: string): Promise<void>;

  transformKey(canonicalKey: string): string;
  reverseTransformKey(platformKey: string): string;

  toPlatformPlaceholder(icu: ICUPlaceholder): string;
  fromPlatformPlaceholder(native: string): ICUPlaceholder;
}
```

Canonical placeholder form is **always ICU** (`{name}`, `{count, plural, one {...} other {...}}`). Adapters own translation to platform-native forms (`%@`, `%1$s`, `<plurals>`).

**v1 plural handling:** adapters error loudly on any source key containing `plural` syntax. Plural support is v1.1.

---

## 12. Translation provider contract

```ts
// src/providers/base.ts
export interface TranslationRequest {
  sourceText: string;
  sourceLocale: string;
  targetLocale: string;
  description?: string;
  glossary?: Record<string, Record<string, string>>;
  placeholders: ICUPlaceholder[];
}

export interface TranslationResult {
  text: string;
  modelVersion: string;
}

export interface TranslationProvider {
  readonly id: string;
  translate(input: TranslationRequest): Promise<TranslationResult>;
  estimateRequests?(inputs: TranslationRequest[]): Promise<{ requests: number; notes?: string }>;
  preflight?(): Promise<PreflightResult>;
}

export interface PreflightResult {
  ok: boolean;
  code?: string;            // L10N_E0050 / 0051 / 0052 on failure
  detectedVersion?: string;
  message?: string;         // human-readable remediation
}
```

v1 ships `CodexLocalProvider`, which spawns `codex` in local server mode and communicates over its protocol. This lets users translate using their existing ChatGPT subscription rather than paying for API tokens. The `preflight` hook exists precisely so providers with install/auth requirements (like Codex) can fail fast with actionable errors instead of crashing mid-run. Additional providers — OpenAI API for CI / unattended use, Anthropic, DeepL, local Ollama — are one file each and planned for v1.x.

---

## 13. Error UX

Every error has a **code**, a **summary**, and a **next step**. No raw stack traces to end users unless `--verbose` is set.

### Format

Default (human):
```
error  L10N_E0041  Placeholder mismatch in translation
       Key:       onboarding.welcome.title
       Locale:    de
       Source:    "Welcome home, {name}"
       Target:    "Willkommen zu Hause"
       Next:      Re-run `l10n-agent sync --key onboarding.welcome.title`
                  or edit translations.de.json and set `reviewed: true`.
```

With `--json`:
```json
{ "level": "error", "code": "L10N_E0041", "summary": "Placeholder mismatch in translation",
  "details": { "key": "onboarding.welcome.title", "locale": "de",
               "source": "Welcome home, {name}", "target": "Willkommen zu Hause" },
  "next": "Re-run `l10n-agent sync --key onboarding.welcome.title` ..." }
```

### Error categories

| Code range      | Category             | Example                                              |
| --------------- | -------------------- | ---------------------------------------------------- |
| `L10N_E0001–09` | Config               | YAML parse error, unknown key, schema validation     |
| `L10N_E0010–19` | Source file          | Malformed `source.en.json`, duplicate key            |
| `L10N_E0020–29` | Style lint           | Bad case, too deep, unknown scope, forbidden prefix  |
| `L10N_E0030–39` | Platform             | `.xcstrings` parse error, unreadable `strings.xml`   |
| `L10N_E0040–49` | Placeholders         | Mismatch, unsupported ICU feature (plural in v1)     |
| `L10N_E0050`    | Provider — preflight | Codex CLI not found on `PATH`                        |
| `L10N_E0051`    | Provider — auth      | Codex not logged in or session expired               |
| `L10N_E0052`    | Provider — version   | Installed Codex version below pinned minimum         |
| `L10N_E0053`    | Provider — quota     | Rate limit or subscription quota hit mid-run         |
| `L10N_E0054`    | Provider — crash     | Codex subprocess exited unexpectedly                 |
| `L10N_E0055`    | Provider — protocol  | Unrecognized response from Codex                     |
| `L10N_E0060–69` | Integrity            | Cache corrupt, out-of-sync detected, history gap     |
| `L10N_E0070–79` | Concurrency          | Two l10n-agent processes running in same repo        |

### Principles

- Exit codes: `0` success, `1` user-fixable error, `2` environment/provider error, `10` internal bug.
- Respect `NO_COLOR` and `FORCE_COLOR`.
- `--json` makes every line machine-parseable; never mix human and JSON output.
- Errors always name the file and key involved. No "something went wrong."
- `--verbose` adds full stack trace + full provider request/response (with API key redacted).
- Never log the API key, full prompt content, or full response in default output.

---

## 14. Test strategy

### Layers

| Layer            | Tooling         | What it proves                                               |
| ---------------- | --------------- | ------------------------------------------------------------ |
| Unit             | vitest          | Pure functions in `core/` (diff, linter, placeholders, store) |
| Adapter golden   | vitest + fixtures | `.xcstrings` and `strings.xml` round-trip are lossless     |
| Provider replay  | subprocess mock | Codex protocol exchanges recorded once, replayed in CI (no live Codex calls) |
| Integration      | vitest + tmp dir | Clean repo → `init` → `sync` → verify every artifact       |
| Property-based   | fast-check      | `iOS → ICU → iOS`, `Android → ICU → Android` are identity   |
| E2E              | shelljs in CI   | Example iOS + Android repo runs full flow against recorded provider |
| Snapshot         | vitest inline   | CLI output stability (errors, doctor report, dry-run diff)  |

### Fixtures

`fixtures/xcstrings/` contains golden `.xcstrings` files per Xcode version (16, 17, 18). Adapter tests assert round-trip against each. When a new Xcode release changes the format, we add a new fixture and update the adapter; we never mutate existing fixtures.

`fixtures/strings_xml/` contains minimal, plural-free, plural-containing (rejected), and UTF-8-heavy cases.

`fixtures/provider/` contains recorded Codex protocol request/response pairs per Codex minor version. Re-recorded manually on Codex upgrades, gated behind `pnpm test:record` with an explicit env var. Recorded fixtures let CI pass without a logged-in Codex session.

### Coverage targets

- Overall: 80% line coverage, enforced in CI.
- `core/differ/`, `core/placeholders/`, `adapters/`: 100% line coverage. Non-negotiable.
- `cli/`: smoke tests only — the CLI is thin wiring over core.

### What we do not test

- The actual quality of translations (not measurable in unit tests).
- Real Codex sessions in CI (requires interactive login and a subscription). We trust recorded protocol fixtures and revalidate manually on Codex upgrades.

---

## 15. Out of scope for v1

- Flutter adapter → v1.1
- Web / React Native adapters → v1.2+
- Full CLDR plural categories → v1.1 (v1 errors loudly on plurals)
- OpenAI API-key provider (for CI / unattended use) → v1.x — reuses the same `TranslationProvider` contract
- Anthropic, DeepL, local Ollama providers → v1.x — reuse the same `TranslationProvider` contract
- GUI or local web studio → no current plan
- User-authored adapter plugin system → v2
- Git-history-aware migrations → rely on `dedupe` and `rename`
- Cross-repo shared stores over HTTP → see §17, submodule-only in v1

---

## 16. Risks and open items

- **`.xcstrings` round-trip fragility.** Apple-managed JSON with metadata Apple can change across Xcode versions. Golden fixtures per Xcode version are the mitigation; budget real time.
- **Android plurals.** `<plurals>` requires CLDR awareness. v1 rejects; v1.1 adds it. If users' existing `strings.xml` contains `<plurals>`, `init` imports non-plural keys and reports plural keys as "skipped (pending v1.1)."
- **Token cost surprise.** `doctor` shows estimated cost; `sync --dry-run` too. Still a risk on large codebases — include a prominent cost line in the README quickstart.
- **Codex protocol stability.** Codex is actively evolving. We pin a minimum version, parse responses defensively, and re-verify on every Codex major release. If OpenAI changes the server-mode shape, a hot-fix release may be needed.
- **Codex as a hard dependency.** Users without Codex CLI cannot use v1. Acceptable given the target user; a clear preflight flow in `init` and crisp remediation errors (`L10N_E0050/0051/0052`) keep first-run friction low.
- **Subscription rate limits.** ChatGPT-subscription quotas are lower than API quotas and can bite large first-sync runs. Resumable sync (US-20, US-21) turns this from a failure mode into an inconvenience.
- **Name.** `l10n-agent` is a working title. npm namespace availability needs checking before M6.
- **Merge-conflict UX in `repair`.** JSON three-way merge is well-trodden; still worth a focused design pass in M1.

---

## 17. Deployment patterns

### Monorepo (recommended)

`l10n/` lives at repo root. iOS and Android dirs sibling to it. One config, one source, one truth.

```
my-app/
├── l10n/
├── ios/MyApp/Localizable.xcstrings
└── android/app/src/main/res/
```

### Separate iOS and Android repos

Supported via a **shared l10n repo consumed as a git submodule** in each platform repo.

```
my-app-l10n/               (dedicated repo)
└── l10n/

my-app-ios/
└── l10n/                  (submodule → my-app-l10n)
└── ios/...

my-app-android/
└── l10n/                  (submodule → my-app-l10n)
└── android/...
```

`config.yaml` in the shared repo; each platform repo runs `l10n-agent sync` from its own checkout against the submodule. Docs cover the submodule pattern; no tool feature beyond that.

### Hosted backend

Explicitly not supported in v1. If a user needs it, the answer is "this isn't the product for you yet."

---

## 18. Milestones

| Wk     | Milestone                                                                         | Exit criteria                                                |
| ------ | --------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 1–2    | M1: repo skeleton, config, JSON store, linter, `check`, `lint`, `doctor` (no cost) | `check` passes on a hand-crafted fixture repo                |
| 3      | M2: iOS adapter — read/write `.xcstrings`, placeholders, no plurals               | Round-trip golden fixtures pass for Xcode 16–18              |
| 4      | M3: Android adapter — read/write `strings.xml`, placeholders, no plurals          | Round-trip golden fixtures pass                              |
| 5      | M4: Codex-local provider (preflight, subprocess mgmt, recorded protocol), `sync`, cache, resumable progress (`.state.json`), `reviewed`/`stale`, placeholder safety | End-to-end `sync` against recorded Codex fixtures; forced rate-limit interrupt restores cleanly on re-run |
| 6      | M5: `dedupe`, `rename`, `rollback`, `import`, `init` with real import             | All core user stories pass integration tests                 |
| 6–7    | **v1 release.** `repair`, docs, example repo, npm publish                         | `npm i -g l10n-agent` + quickstart works in <5 min           |
| 8–10   | v1.1: Flutter adapter, plural support across iOS/Android/Flutter                  | Plural fixtures round-trip; Flutter parity with mobile       |

---

## 19. Success metrics

Measured informally for v1 (no telemetry).

- **Time-to-first-translation** on a fresh install with existing strings: under 5 minutes.
- **Lines of config** to get started: under 20.
- **First-sync completion** for a 500-key app into 3 target locales: finishes in one run on a ChatGPT Plus subscription; if rate-limited, resumes cleanly on a second invocation with zero manual cleanup.
- **Zero** silent overwrites of `reviewed: true` translations in the v1 bug log.

---

## 20. Glossary

- **Canonical source** — `l10n/source.<locale>.json`. Single source of truth for every key's text, description, and placeholders. All platform files derive from it.
- **Adapter** — component that reads and writes a platform-native file (`.xcstrings`, `strings.xml`) and maps between canonical keys/placeholders and platform-native forms.
- **Provider** — component that translates text. v1 has one: Codex CLI in local server mode (`codex-local`).
- **Reviewed** — a translation entry with `reviewed: true`. The tool will never overwrite it without explicit user opt-in.
- **Stale** — a translation entry whose source text has changed since it was translated. Flagged for re-translation unless reviewed.
- **ICU** — the placeholder/plural syntax used as the canonical internal form (`{name}`, `{count, plural, ...}`).
- **Codex CLI** — OpenAI's official terminal coding agent. `l10n-agent` invokes it in local server mode as the v1 translation provider, piggybacking on the user's existing ChatGPT subscription auth.
- **Codex server mode** — the subcommand (MCP server or `app-server`, depending on Codex version) that exposes Codex as a local process for programmatic consumption.
- **Preflight** — the pre-run check that verifies a provider's install, auth, and version. Runs before any command that needs translation, and again at the start of `init`.
- **Resumable sync** — the guarantee that a `sync` interrupted by rate-limit, network, or crash errors can be completed simply by running `sync` again; no cleanup, flags, or manual state fix-up required.
