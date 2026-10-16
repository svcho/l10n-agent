# Plan: Swift rewrite (Apple-only)

Status: in progress on `feature/apple-swift-rewrite`. Design rationale: `docs/audit-and-apple-redesign.md`.

## Progress

Implementation complete (2026-10-13).

- Independent review: 3 high, 7 medium and several low findings, all fixed with regression tests (`Tests/L10nCoreTests/ReviewRegressionTests.swift`). A re-verification confirmed the fixes and found one new issue (package catalog placement), which is fixed too.
- Live smoke test with the local `translategemma` (4B) model on the fixed sample app: 72 of 73 strings translated in about 2.5 minutes. The one failure was a Polish plural, where the small model did not return per-category forms; it was reported and left untouched. Lint shows no format mismatches.
- `scripts/check.sh`: build, 71 tests (66 core and 5 MCP), and the secret scan all pass.

## Spike results (2026-10-09, Xcode 27.0, Swift 6.4)

- **S1 serialization.** `xcstringstool sync` rewrites catalogs in Xcode's format:
  - 2-space indent, `" : "` separator.
  - Object keys sorted by raw Unicode code point; no normalization (`é` sorts before `z`, `é` after it).
  - Empty object is written as `{\n\n<indent>}`.
  - No trailing newline.
  - Escapes are only `\\ \" \n \r \t` and `\u00XX` (lowercase hex) for the other control characters. `/`, DEL, U+2028 and non-ASCII are written raw.
- **S2 symbols.** `xcstringstool generate-symbols` emits symbols only for `extractionState: manual` keys.
  - Naming:
    - Split on non-alphanumerics and on digit→letter boundaries.
    - Lowercase the leading uppercase run of the first word.
    - Later words: capitalize the first letter, or the whole word if it is all caps (`URL` → `Url`).
    - A key starting with a digit or `_` gets a `_` prefix, and its first word is capitalized.
    - Swift keywords are backticked.
  - `self`, `Type` and `Protocol` are errors, and two keys mapping to the same symbol are a build error.
  - Placeholders become `_ argN: String/Int/Float/Double`.
- **S3 drift.** `xcstringstool sync` does not mark translations when the source value changes, so the tool keeps a sidecar fingerprint file.
- **S4 local LLM.** The Ollama MLX model `qwen3.8:27b-mlx` gives good batch translations and keeps `⟦n⟧` placeholder tokens (about 20s per 6-string batch). MLX models reject structured output (`format`/`response_format` → "structured output is unavailable"), so the tool parses JSON leniently, validates, and retries. Ollama also lists `:cloud` models, which `doctor` must flag as not local.

## Requested behavior

An Apple-only Swift CLI `l10n-agent` that:

1. **lint**: finds unlocalized and badly localized strings in Swift code (SwiftSyntax) and problems in `.xcstrings` catalogs. Output formats: xcode (build-phase warnings), json, sarif, text.
2. **fix**: turns findings into an edit plan (semantic manual keys + comments in the catalog, code rewritten to generated symbols or `String(localized:defaultValue:comment:)`). Preview by default, `--apply` to write.
3. **translate**: fills missing or stale translations through a local LLM (Ollama native API, OpenAI-compatible for LM Studio), batched, with placeholder masking and validation. Writes `needs_review` and never overwrites `translated`.
4. **status, doctor, init, accept**: coverage, environment, config scaffolding, re-stamping fingerprints after review.
5. **mcp**: a stdio MCP server exposing the same operations to coding agents.
6. A Claude Code skill (`skills/apple-l10n/SKILL.md`) driving the CLI.

## Acceptance criteria

- [x] Catalog load→save is byte-identical to xcstringstool output on test fixtures (unknown fields kept).
- [x] Symbol naming matches `xcstringstool generate-symbols` on a corpus of tricky keys (test runs when `xcrun` is available).
- [x] Format-specifier parity is compared by argument index and type, and reordering is allowed (the old C2 bug can't recur).
- [x] Code rules L10N001-L10N005 and catalog rules L10N101-L10N110 have fixtures with positive and negative cases. Suppressions work.
- [x] `fix --apply` on a fixture app produces code that type-checks (verified with `swiftc -typecheck` against a generated-symbols file).
- [x] `translate` with a replay transport: batching, masking, retries, `needs_review`, never touches `translated`, writes fingerprints.
- [x] Live smoke test against local Ollama translates a fixture catalog.
- [x] The MCP server answers `tools/list` and `tools/call` for lint/status over stdio.
- [x] TypeScript sources, npm config and the old fixtures are removed; README, AGENTS.md and CHANGELOG are updated.
- [x] `swift build`, `swift test` and the secret scan pass.

## Out of scope for this change

Homebrew tap, SPM build-tool plugin, plural *authoring* in code (lint suggests it; translate handles existing plural variations), Objective-C scanning, .strings/.stringsdict (use Xcode's "Migrate to String Catalog").

## Verification commands

```bash
swift build
swift test
swift run l10n-agent lint --path Fixtures/SampleApp --format text
swift run l10n-agent translate --path <tmp copy> --dry-run
```
