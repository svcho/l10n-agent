# AGENTS.md

## Purpose

`l10n-agent` is a local-first Swift CLI (plus MCP server and Claude Code skill) that manages localization of Xcode projects. It lints Swift code and String Catalogs, rewrites code to semantic catalog keys, and translates with a local LLM. Apple platforms only.

`README.md`, this file and `CHANGELOG.md` are the complete project context. `docs/audit-and-apple-redesign.md` records why the TypeScript version was replaced; `docs/plan-swift-rewrite.md` records the spikes behind key decisions.

## Product boundaries

In scope:

- `.xcstrings` String Catalogs as the only source of truth
- Swift / SwiftUI / UIKit / AppKit code scanning with SwiftSyntax (no type checking)
- code fixes using generated String Catalog symbols or `String(localized:defaultValue:comment:)`
- translation through local models (Ollama native API, OpenAI-compatible servers)
- CLI, MCP server (stdio) and skill front ends over one core library

Out of scope:

- Android, web, cross-platform frameworks
- `.strings` / `.stringsdict` (users migrate with Xcode's "Migrate to String Catalog")
- hosted services, remote state, OTA delivery
- Objective-C scanning
- authoring new plural variations in code (lint suggests them; translate fills existing ones)

## Layout

- `Sources/L10nCore/JSON/` order-preserving JSON parser and Xcode-identical writer
- `Sources/L10nCore/Catalog/` catalog model, format specifiers, parity, symbol naming, fingerprints
- `Sources/L10nCore/Project/` config (`.l10n-agent.yml`) and project discovery (pbxproj settings)
- `Sources/L10nCore/Scanner/` SwiftSyntax scanner and API tables
- `Sources/L10nCore/Lint/` rules, linter, reporters (text, xcode, json, sarif)
- `Sources/L10nCore/Fix/` key suggestion, fix plans, applying edits, LLM key naming
- `Sources/L10nCore/Translate/` chat-model clients, masking, plural rules, translation engine
- `Sources/L10nCore/Commands/` status, doctor, init, add-keys
- `Sources/L10nMCP/` MCP server
- `Sources/l10n-agent/` CLI (swift-argument-parser)
- `Tests/` Swift Testing suites; `Tests/L10nCoreTests/Fixtures/SampleApp` is the integration fixture
- `skills/apple-l10n/SKILL.md` Claude Code skill

## Behavioral rules (keep these true)

- Catalog writes must be byte-identical to Xcode's output for the same content. Unknown fields round-trip. Keys are compared by exact bytes, never normalized (use `ByteKey` for key sets and maps).
- Symbol names must match `xcstringstool generate-symbols`; non-`Localizable` tables are namespaced (`.Settings.key`).
- Translations in state `translated` are never overwritten or removed by any command, including single plural categories. Tool output is written as `needs_review`. Broken `needs_review` translations may be retranslated.
- Format parity compares argument index and type; reordering via positional specifiers is allowed; plural cases may omit arguments. Substitution `argNum`/`formatSpecifier` must match the source and are part of the source fingerprint.
- A language may vary a plain source string by plural/device on its own (Xcode "Vary by Plural"); complete variations count as translated and are never machine-translated.
- Fix plans are untrusted input: apply re-scans files, matches items to fresh sites, and takes only key, comment, specifier and status from the plan. The code style and target catalog are recomputed from the project. It refuses when a file changed, verifies the rewritten file still parses, and changes catalogs only for applied edits.
- Rewrites keep declared types: literals typed `LocalizedStringResource` become a resource expression; `LocalizedStringKey`-typed literals are skipped. Literal-style resources in packages use `bundle: .atURL(Bundle.module.bundleURL)`.
- Whole-call rewrites never drop code: wrapped literals and calls with extra arguments (`bundle:`, `locale:`, `defaultValue:`, non-literal `table:`/`comment:`) are skipped.
- With `codeStyle: auto`, symbol rewrites are decided per file: only files of an `.xcodeproj` that enables symbol generation in every configuration get symbols; package targets, mixed projects and files whose owner is ambiguous (several projects in the same folder) get literals.
- `apply` loads every piece of state that can fail before writing, computes all changes in memory, then commits catalogs and fingerprints before source files through a `FileTransaction` that restores every written file if any write fails. `translate` (catalogs + fingerprints per batch) and `l10n_add_keys` use the same transaction. `init` holds one lock for all its writes.
- `*` widths/precisions (`%*d`) count as integer arguments; strings with them are never reordered. The space flag (`% d`) counts only when the conversion ends the word, so prose such as "100% discount" stays text.
- L10N110 and fix-time symbol checks apply only where symbols are generated (per catalog / per rewritten file).
- Plural translations are restored and validated against their own source form (`other` only for categories the source lacks).
- The JSON parser accepts only RFC 8259 numbers; malformed or blank catalogs are reported (L10N100), never rewritten. Only nonexistent catalog paths start empty.
- `init` validates all catalogs before writing anything and writes `catalog:` only when the project has a single candidate catalog.
- A key/locale fingerprint is only re-stamped when no approved translation of it was left unreviewed.
- Migrating translations into an existing key merges only the leaves it lacks; existing leaves always win.
- Provided plural translations may fill categories next to approved ones; approved categories are ignored, never overwritten.
- Only conditions that require `DEBUG` (`DEBUG`, `DEBUG && X`, `A || B` with both requiring it) are skipped by the scanner.
- Plural categories come from the CLDR table in `PluralRules` or `pluralCategories` in the config; unknown languages are reported, never guessed.
- Catalog lookups are scoped to the file's own target (`catalogRoutes`, package target, nearest ancestor catalog, else the owning `.xcodeproj` folder ranked by shared prefix and folder names). When several catalogs remain, fixes are skipped and `l10n_add_keys` requires `catalog`; the tool never guesses. Discovered symlinks must resolve inside the project. L10N004 checks only those catalogs, and fixes for a named table use (or create) that table there instead of another target's catalog or `Localizable`.
- Glossary terms (L10N108) are checked in every variation whose source uses the term.
- Fixes whose placeholder types are guessed are `needsReview` and are not applied by default.
- Translation is local-only. Non-localhost URLs and Ollama `:cloud` models need `translator.allowRemote: true` plus `L10N_AGENT_ALLOW_REMOTE=1` in the user's environment.
- Mutating commands hold the `flock` project lock (`.l10n-agent/lock`); the kernel releases it on exit.
- `.l10n-agent/fingerprints.json` is the only extra state. Comment edits do not make translations stale. A file that does not match the schema stops the command instead of being treated as empty.
- MCP tools resolve every path inside the project root (symlinks resolved); provided translations are limited to target locales.
- Tests stay offline: no live model calls. Tests that need Xcode tools are skipped when `xcrun` is unavailable.

## Lint rule IDs

L10N001-L10N005 (code), L10N100-L10N111 (catalogs). IDs are stable; add new rules with new IDs and document them in README.

## Fast start

```bash
swift build
swift test
scripts/check.sh
```

## Release and docs policy

- Update README, this file and CHANGELOG in the same change as behavior changes.
- Keep the repo publish-safe: never commit credentials, `.env*`, private keys or recorded model output. `scripts/secret-scan.sh` (staged blobs plus working copies) runs in `scripts/check.sh` and the pre-commit hook.
