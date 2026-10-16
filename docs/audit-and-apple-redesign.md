# l10n-agent: audit and Apple-only redesign

Date: 2026-10-09. Base: `main` @ `a0e5448` (0.3.1 beta).

Markers: **[R]** reproduced against `src/` with a script on a copy of `fixtures/projects/happy-path`; **[I]** inferred from reading the code.

Test baseline: `npx vitest run` gives 73 passed and 1 failed. `test/cli/sync-signals.test.ts` runs `JSON.parse` on stderr, and on Node 26 a tsx deprecation warning lands first.

---

## Part 1. Findings

### Critical: data loss or wrong text at runtime

| # | Finding | Where | |
|---|---|---|---|
| C1 | `sync --locale es` treats every other configured locale as removed. It archives `translations.de.json`, deletes `values-de/strings.xml`, strips `de` from the `.xcstrings`, and logs `remove_locale`. Cause: removed locales are compared against `selectedLocales` instead of `config.target_locales`. | `core/sync.ts:212-240, 590` | R |
| C2 | Placeholder argument numbers follow the order placeholders appear in *each locale's* text, but the app passes arguments in source order. `{user} shared {count} files` → de `{count} Dateien von {user}` renders `%1$d … %2$s`. On Android that crashes with `IllegalFormatConversionException`; on iOS it shows swapped or garbage values. Parity checking explicitly allows named reordering, and `check` compares sorted names, so nothing catches it. | `adapters/android/strings.ts:395-405`, `adapters/ios/xcstrings.ts:343-357`, `core/placeholders/parity.ts` | R |
| C3 | The `Localizable.strings` adapter never converts placeholders. It writes `"Hello {name}"` into the native file, and reads `%@` as literal text, which the Android writer then emits as `%%@`. | `adapters/ios/strings.ts:248-297` | R |
| C4 | Real Xcode catalogs are rejected. A normal entry `"value": "Hello %@"` has no `substitutions` (Xcode only writes those for plural `%#@x@` tokens), so reading it throws E0041. The writer emits non-Xcode substitutions (`formatSpecifier: "%lld"`, `"date"`) that Xcode may drop on save, which breaks the next read. | `adapters/ios/xcstrings.ts:159-168, 287-316` | R |
| C5 | The xcstrings writer deletes every entry it does not manage, including Xcode-extracted keys and plural entries. Separately, a single unmanaged plural entry makes the whole catalog unreadable. | `adapters/ios/xcstrings.ts:531-539, 236-249` | R |
| C6 | Float placeholders become integers (`%1$f` → `%1$d` / `%1$lld`), and other specifiers (`%.1f`, `%,d`, `%x`) are double-escaped to literal `%%.1f`. | `adapters/android/strings.ts:13, 184, 259-278`, `xcstrings.ts:135-178` | R |
| C7 | `init` discards a failed import report and still writes config with an empty source. The first `sync` then empties `values/strings.xml` (including `app_name`) and deletes `values-de/`. C8 means rollback cannot bring them back. | `core/init.ts:266-269` | R |
| C8 | Snapshots never include the Android per-locale files (`values-xx/strings.xml`) or `config.yaml`, so after rename, sync or init, rollback restores only part of the state. | `core/project-files.ts:101-135`, `init.ts:222-229` | R |
| C9 | History IDs have one-second resolution. Two operations in the same second share an ID, the second snapshot overwrites the first, and `rollback --to` restores the wrong state. | `core/history.ts:13-15` | R |
| C10 | `import` replaces the canonical source wholesale: descriptions, placeholder examples and canonical-only keys are lost. It marks *every* imported translation `reviewed: true`, including earlier machine output. `--from` is not validated, so `--from ios` imports Android. | `core/import.ts:53-126` | R |
| C11 | On Android, sync deletes `translatable="false"` strings and comments from the source `strings.xml`. | `adapters/android/strings.ts:474-477, 617-645` | R |

### High: broken workflows

- **H1. No way out once a reviewed translation goes stale [R].** `source_hash` hashes the whole source key, including `description` and the placeholder `example` (the docs say text + placeholders only). A typo fix in a description makes every reviewed entry stale for good. Sync never re-stamps reviewed entries, so the only exits are clearing `reviewed` (which loses the human text) or computing a sha256 by hand. The same edit re-translates every unreviewed locale. `core/store/hash.ts:6-8`, `sync.ts:841-857`.
- **H2. One bad unreviewed translation blocks every sync [R by reading the plan logic].** An entry whose hash is current but whose placeholders fail parity raises an error before any work starts (`sync.ts:652-670, 721`). The advice says "re-run sync", but sync never retranslates an entry whose hash is current. Imported legacy strings hit this often.
- **H3. Glossary and model changes never reach existing translations [I].** `config_hash` lives only in the cache, and the cache is consulted only for missing or stale entries. Adding a glossary term changes nothing on disk, and `lint --glossary` keeps flagging entries that sync will never fix. The cache hash also includes `codex_min_version`, so a version bump busts every entry.
- **H4. The `snake_case` key transform is not reversible [R].** `settings.dark_mode` → `settings_dark_mode` → read back as `settings.dark.mode`, which causes permanent drift. `a.b_c` and `a_b.c` collide into one Android resource. `kebab-case` produces invalid Android names.
- **H5. A dead process blocks every command for 10 minutes [R].** A lock counts as stale only when the PID is dead *and* the lock is older than 10 minutes. Ctrl-C during rename, rollback, import, repair or lint --fix calls `process.exit` without releasing the lock (`cli/index.ts:190-205`, `utils/lock.ts:96-97`).
- **H6. Lock taken after state is read [I].** Every mutating command loads the snapshot before locking, against the AGENTS.md rule. Lock takeover is `rm`+`wx`, which races, and release deletes the lock without checking who owns it.
- **H7. `--strict` stops halfway [I].** The translation files and cache are already written, but native files are not regenerated, no history entry is written, `.state.json` is deleted, and the snapshot is left without a history entry (`sync.ts:947-964`).
- **H8. `repair` merge gaps [R].**
  - The merge is two-way with no base, so a key deleted on one branch comes back.
  - `.history.jsonl`, the file most likely to conflict, is never repaired, and a conflict there makes every command fail.
  - diff3 conflict markers are not supported.
- **H9. `lint --fix` rewrites code by raw substring [R].** It misses the platform form (`R.string.settings_Save`), scans lockfiles and CI YAML, and accepts renames the model proposes for keys outside the candidate set.
- **H10. Android escaping and whitespace [R].**
  - `…` and `&#8230;` are not decoded.
  - CDATA, `<b>` and `<xliff:g>` are escaped into literal markup, and `@string/x` gets a backslash.
  - `100% sure` is written as `100%%`, and `Use %%s` is read as a placeholder.
  - Android's whitespace rules are not implemented.
- **H11. `.strings` parsing [R].** The parser uses `JSON.parse`, so it rejects `\U2026`, `\'`, unquoted keys, literal newlines and UTF-16 files. `Base.lproj` resolves to `en.lproj`.

### Medium and low (abridged)

- **Unknown fields are silently dropped** on every write, because the zod schemas strip extra keys [R]. **Sorting uses `localeCompare` without a locale**, so file order churns between machines with different `LANG` settings [R].
- **`init` problems:**
  - It picks `InfoPlist.xcstrings` before `Localizable.xcstrings`.
  - An empty new catalog makes `init` half-finish, and re-running reports "already initialized".
  - It ignores `Pods`, `DerivedData` and `.build`, never detects existing locales, and imports only iOS when both platforms exist.
- **Config validation gaps:** `platforms.*.enabled` is never read, duplicate locales and unknown config keys are accepted, and `rename x constructor` collides because key checks use `in` instead of `Object.hasOwn`.
- **Removed locales with a script or region** (`zh-Hans`, `es-419`, `fil`) are never archived, because the regex only matches `xx` and `xx-YY` (`sync.ts:222`).
- **Lesser command issues:**
  - `status` reports "running" whenever *any* command holds the lock.
  - `check --fast` does nothing.
  - `doctor` counts empty entries as present.
  - Orphaned reviewed entries are archived to `.snapshots/orphaned-reviewed/` instead of `.archive/`.
- **Provider problems:**
  - `model_version` is fabricated (`codex-cli-<version>` or the configured alias), not the actual model.
  - Rate-limit detection matches `429` or `quota` anywhere in stdout, including the translated text.
  - Empty translations are accepted.
  - `isSupportedIcuPlaceholderName` is unanchored and never used.
  - `{gender, select, …}` is not detected as unsupported, so its branches `{He}` are treated as placeholders.

### Simplification candidates in the current code

- Key-transform helpers, `pathExists` and the shape-error builders are each copied three times. Adapter construction is copied four times. The sync summary object is built four times.
- `hasPlaceholderParity` compares a `types` signature that is always equal once the counts match, because both sides use the same lookup. That's dead logic.
- `LegacySyncStateFileSchema` is effectively dead: legacy state always fails the hash check. `batch_index` equals `completed_translations`. `--fast` is a no-op.
- `rename` and `lint --fix` each have their own key-move implementation, and `repair` has its own history parser.

---

## Part 2. Concept issues

These explain why the bugs cluster where they do. Fixing the items in Part 1 one by one would leave the causes in place.

1. **Two sources of truth.** Canonical JSON is meant to be authoritative, but the native formats are *richer* than it: plurals, device variations, `needs_review` state, `translatable="false"`, markup, specifier precision. Every round trip through the lowest common denominator destroys data (C3-C6, C11, H10, H11). Drift checking, import and adapters exist only to manage that gap.
2. **Re-implementing git badly.** History, snapshots, rollback, archive, repair, lock and resume state add up to about 40% of the code and hold most of the critical bugs (C8, C9, H5-H8). Git already does history, rollback and merging. Snapshots are full file copies with no pruning. The shared append-only `.history.jsonl` and the committed `.cache.json` guarantee merge conflicts between branches.
3. **One agent session per string.** `sync` runs one `codex exec` per key per locale, sequentially, each a full agent session with read access to the repo. 500 keys x 5 locales means 2,500 sessions. Each string is translated without seeing its neighbours, which hurts terminology consistency. And Codex CLI is not a local LLM: the model runs in the cloud.
4. **A muddled review model.**
   - `reviewed` is the only gate, and `import` grants it wholesale.
   - `stale` is persisted although it can be derived.
   - There's no "accept" action, and no way to propose a new machine translation next to a stale reviewed one.
   - Config changes never reach existing translations.
5. **Resume machinery adds nothing.** The plan is always recomputed from what's on disk, so rerunning `sync` already resumes. `.state.json`, `--continue`, `resumed_from`, `batch_index` and the legacy schema can all go.
6. **Too much surface for the scope.** 11 commands, two platforms and three file formats for a beta, while test fixtures are tiny and never include a catalog actually saved by Xcode, which is how C4 and C5 got through.

---

## Part 3. Apple-only redesign

### Decisions (confirmed)

| Topic | Decision |
|---|---|
| Source of truth | The `.xcstrings` String Catalog itself. No canonical JSON. |
| Translation | Pluggable `Translator`. First backend: OpenAI-compatible localhost (Ollama, LM Studio, llama.cpp server). Codex and Apple Foundation Models later. |
| Language | Swift 6 + SwiftSyntax. One binary, retiring the TypeScript code. |
| Keys in code | Semantic manual keys (`onboarding.welcome.title`) with comment and source value, referenced through Xcode 26 generated String Catalog symbols (`Text(.onboardingWelcomeTitle)`). |

### What disappears

Canonical JSON, `sync` reconciliation, all adapters (Android, `.strings`, the lossy xcstrings writer), cache, `.history.jsonl`, snapshots, rollback, repair, import, archive, `.state.json`/resume, and the custom lock (replaced by a short advisory lock around catalog writes). Git provides history, rollback and merging. Xcode's own "Migrate to String Catalog" handles `.strings` migration.

### Architecture

```
l10n (Swift package)
├─ XCStringsKit   lossless catalog model: ordered JSON tree, unknown fields kept,
│                 serialization byte-identical to Xcode (" : ", 2-space indent, key order)
├─ ProjectKit     finds .xcodeproj/.xcworkspace/Package.swift, catalogs, knownRegions,
│                 build settings (SWIFT_EMIT_LOC_STRINGS, STRING_CATALOG_GENERATE_SYMBOLS)
├─ Scanner        SwiftSyntax visitor: string literals in user-facing positions
├─ Rules          lint rules (IDs, severities, suppressions) over code + catalog
├─ Fixer          produces an EditPlan (code edits + catalog edits) → preview → apply
├─ Translator     protocol + OpenAICompatibleTranslator (+ replay transport for tests)
└─ Frontends      `l10n` CLI · `l10n mcp` (stdio MCP server) · Xcode build phase · SKILL.md
```

All front ends call the same core. The core is deterministic and offline except for `Translator`, and optionally the key-name suggester.

### Lint rules

Code (SwiftSyntax):

| ID | Detects | Auto-fix |
|---|---|---|
| L10N001 | A user-facing literal that never gets localized: `Text(verbatim:)` with words; a `String` literal passed to `Text(_: some StringProtocol)`; UIKit `.text/.title/.placeholder/.accessibilityLabel =`; `setTitle(_:for:)`; `UIAlertController(title:message:)`; `UIAlertAction(title:)`; `NSAttributedString(string:)` | yes |
| L10N002 | A literal used as its own key (`Text("Welcome")`, `Button("Save")`, `.navigationTitle("…")`, `String(localized: "Welcome")`) when the policy is semantic keys | yes |
| L10N003 | Concatenation or interpolation that should be one format string (`"Hello " + name`), or `"\(n) items"` that needs a plural variation | partial |
| L10N004 | Key or symbol referenced in code but missing from the catalog | yes (adds key) |
| L10N005 | Accessibility labels and hints, `Picker`/`Toggle` titles, and `confirmationDialog` text missing localization | yes |

Catalog:

| ID | Detects |
|---|---|
| L10N101 | Missing translation for a locale in `knownRegions` |
| L10N102 | `state: needs_review` (machine output not yet approved) |
| L10N103 | Source value changed after the translation was made (see spike S3) |
| L10N104 | Format specifier mismatch, compared **by argument index and type**. Reordering is allowed only with positional specifiers (fixes C2 by design) |
| L10N105 | Missing comment (translator context) |
| L10N106 | Unused key (`extractionState: stale`, or no code reference) |
| L10N107 | Key style (case, depth, scopes, forbidden prefixes), carried over from today |
| L10N108 | Glossary term not preserved |
| L10N109 | Translation identical to the source (allowlist for brand names) |

Excluded automatically: `Logger`/`print`/`assert`/`fatalError`/`NSLog` arguments, `#if DEBUG`, `#Preview`, test targets, URL/identifier-shaped literals, `UserDefaults`/`Notification.Name` keys, and literals without letters. Suppress with `// l10n:ignore L10N001` or path globs in `.l10n.yml`.

Output formats:
- `--format xcode`: `File.swift:12:9: warning: … [L10N001]`, which shows inline in Xcode from a Run Script phase or an SPM build-tool plugin.
- `--format json`: for agents.
- `--format sarif`: for GitHub code scanning.
- Exit codes are non-zero on errors, configurable per rule.

### Fix pipeline

1. `l10n lint` returns findings with stable IDs.
2. `l10n fix --plan` builds an `EditPlan`. For each code finding it proposes a key and comment, validated for style, uniqueness and collisions. Key suggestions come from the local LLM in **one batched call**, or from the calling coding agent through MCP.
3. Code rewrites use SwiftSyntax, preserving trivia:
   - With generated symbols: `Text("Welcome")` → `Text(.onboardingWelcomeTitle)`, `label.text = "Save"` → `label.text = String(localized: .settingsSaveButton)`, `"Hello \(name)"` → `.greeting(name)`.
   - Without them: `String(localized: "onboarding.welcome.title", defaultValue: "Welcome", comment: "…")`.
   - The catalog gets the manual key, source value and comment.
4. `--apply` writes the plan; the default is a unified-diff preview.
5. `l10n translate [--locale de]`:
   - Strings are batched per locale (about 30 per request) with neighbouring strings and comments as context, plus the glossary.
   - Format specifiers are masked as tokens (`⟦1⟧`) before sending and restored after, and the tokens are verified.
   - Output is schema-constrained JSON (Ollama `format` / LM Studio `response_format`).
   - Results are written as `state: needs_review`.
   - Entries in state `translated` (human-approved) are never touched; drift on them is reported as L10N103.

Review model mapped onto Xcode states: `new` = untranslated, `needs_review` = machine output or source changed, `translated` = approved by a human in Xcode's catalog editor. No separate `reviewed` flag, and no "accept" CLI is needed because approving in Xcode *is* the accept action.

### Agent integration

- **Skill** (`skills/apple-l10n/SKILL.md`): when to run (after adding UI text, before a PR), the lint → fix → translate → review loop, key-naming and comment conventions, plural guidance, and how to read the JSON output. It calls the CLI directly. It's cheap and is enough on its own for Claude Code.
- **MCP server** (`l10n mcp`, stdio, official `modelcontextprotocol/swift-sdk`). It's for other agents and editors, and for typed tool calls:
  - `l10n_lint({paths?, rules?})`: findings
  - `l10n_status()`: coverage per locale
  - `l10n_plan_fixes({finding_ids, keys?})`: an EditPlan. The agent may supply its own key names; the tool validates them.
  - `l10n_apply_plan({plan})`: diff summary
  - `l10n_add_keys([{key, value, comment}])`
  - `l10n_translate({locales?, keys?, dry_run?})`: local LLM
  - `l10n_set_translations([{key, locale, value}])`: lets the agent translate itself; always written as `needs_review`
- Principle: tools are deterministic and idempotent and return diffs. The coding agent does the judgement work (naming, ambiguous code edits); the tool guarantees correctness (specifiers, catalog format, no overwrites of approved text).

### Carried over from today

Placeholder parity (fixed to compare by index), glossary enforcement, key-style rules, "approved text is never overwritten", provider isolation, offline replay tests, and stable error codes.

### Spikes to run before building (they decide details)

- **S1. Xcode byte-identity.** Load and save three real catalogs (including plurals, device variations and substitutions); the output must be byte-identical to an Xcode 26 save. Acceptance: zero diff.
- **S2. Generated symbol naming.** How Xcode 26 names symbols for dotted keys and for keys with placeholders (static var vs function, argument labels), and which catalog format version (1.1) it requires.
- **S3. Source-change detection.** Does Xcode flip manual-key translations to `needs_review` when the source value changes? If not, keep a small sidecar `l10n.fingerprints.json` (key → locale → source hash). This is the only state file the new design would need.
- **S4. Local model quality.** 50 real strings x 3 locales across 2-3 Ollama models (for example a Qwen and a Gemma size class): specifier preservation, glossary adherence, latency.

### Phases

| Phase | Scope | Done when |
|---|---|---|
| P0 | Spikes S1-S4 | Findings written up; the S3 decision made |
| P1 | XCStringsKit + catalog rules + `--format xcode/json` | Zero-diff round trip on real catalogs; warnings visible in Xcode from a build phase |
| P2 | SwiftSyntax scanner + code rules + suppressions | Rule fixtures pass; low false-positive rate on 1-2 real apps |
| P3 | `fix` plan/apply (code + catalog) | Sample app builds after `fix --apply`; symbols resolve |
| P4 | `translate` via Ollama/LM Studio | Batched, masked specifiers, writes `needs_review`, never touches `translated` |
| P5 | SKILL.md + `l10n mcp` | Claude Code runs the lint → fix → translate loop end to end on a sample app |
| P6 | Homebrew tap, SPM build-tool plugin, docs | `brew install` + one-line build-phase setup |

### Migrating current users

A one-time `l10n migrate-from-json` exports `l10n/source.*.json` and `translations.*.json` into the catalog: `reviewed: true` → `translated`, otherwise `needs_review`, and descriptions become comments. After that, `l10n/` can be deleted.

## Sources

- WWDC25 "Explore localization with Xcode" notes (generated String Catalog symbols): https://wwdcnotes.com/documentation/wwdc25-225-codealong-explore-localization-with-xcode/
- MCP Swift SDK: https://swiftpackageregistry.com/modelcontextprotocol/swift-sdk
