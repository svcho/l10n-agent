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

- Catalog writes must be byte-identical to Xcode's output for the same content. Unknown fields round-trip. Keys are compared by exact bytes, never normalized.
- Symbol names must match `xcstringstool generate-symbols`; non-`Localizable` tables are namespaced (`.Settings.key`).
- Translations in state `translated` are never overwritten or removed by any command, including single plural categories. Tool output is written as `needs_review`. Broken `needs_review` translations may be retranslated.
- Format parity compares argument index and type; reordering via positional specifiers is allowed; plural cases may omit arguments.
- Fix plans are untrusted input: apply re-scans files, matches items to fresh sites, and takes only key, comment, specifier and status from the plan. The code style and target catalog are recomputed from the project. It refuses when a file changed, verifies the rewritten file still parses, and changes catalogs only for applied edits.
- Whole-call rewrites never drop code: wrapped literals and calls with extra arguments (`bundle:`, `locale:`, `defaultValue:`) are skipped.
- Fixes whose placeholder types are guessed are `needsReview` and are not applied by default.
- Translation is local-only. Non-localhost URLs and Ollama `:cloud` models need `translator.allowRemote: true` plus `L10N_AGENT_ALLOW_REMOTE=1` in the user's environment.
- Mutating commands hold the `flock` project lock (`.l10n-agent/lock`); the kernel releases it on exit.
- `.l10n-agent/fingerprints.json` is the only extra state. Comment edits do not make translations stale.
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
- Keep the repo publish-safe: never commit credentials, `.env*`, private keys or recorded model output. `scripts/secret-scan.sh` runs in `scripts/check.sh`.
