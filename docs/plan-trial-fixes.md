# Plan: fixes from the pangi trial

Source: the real-repo trial on pangi (2026-10-16, report in pangi `requirements/design/l10n-agent-trial-report.md`). The user asked to fix every finding: high, medium and low, plus the missing features. Status: implemented on `feature/apple-swift-rewrite` (PR #3, not merged), including the fixes from an independent review of this change (extracted English keys, binding shadowing, migrate fingerprints/conflicts/lock/symlinks, same-named functions, logger receivers, generated-file markers, symbol-style prefixes, BOM-less UTF-16, letterless translate units, CLI helpers under test).

Result on pangi's original code (release/2026.11, no workarounds): L10N001 went from 161 to 3, all real. L10N107 went from 261 to 1. `migrate` reproduces all 692 English and 692 German values. The don't-translate fixes match the entries the trial added by hand.

## Items and acceptance criteria

Each item gets a regression test.

### Correctness

1. **Keys passed to localizing APIs are not rewritten (high).**
   - A project-wide index of functions and initializers declared in the scanned sources records parameters typed `LocalizedStringKey` or `LocalizedStringResource`. Literals passed to them are localized lookups: L10N004 applies if the key is missing, and L10N001 doesn't.
   - A literal in a heuristic position (label or name based) that is an existing key of the file's catalogs is not reported and never fixed.
   - A literal at a known UI API (`label.text =`, `UIAlertController(title:)`) that equals an existing key is reported as "shows the raw key" and is unfixable.
   - A fix never emits a `defaultValue:` equal to an existing key.
2. **Queue and logger names.** `DispatchQueue(label:)`, `OperationQueue`, `Logger(subsystem:category:)`, `NSLock` names and reverse-DNS literals are not UI text.
3. **Log-only properties.** A property or function whose every reference in the project is an argument of a logging call (`print`, `NSLog`, `os_log`, or `x.debug/info/notice/warning/error/fault/critical/trace/log(...)`) is not user-facing.
4. **Generated files and heuristic confidence.**
   - Files whose header says they are generated ("GENERATED … do not edit", `@generated`, "auto-generated") are skipped.
   - Sites found only by argument label or variable name on unknown APIs are marked heuristic. Their fixes are `needsReview`, not `ready`.
5. **Plan preview.** `fix --plan edited.json` (preview) rebuilds `sourceValue`, `replacement`, status notes and placeholder comments from the edited plan, the same way apply does.
6. **Placeholder types.**
   - Interpolated identifiers take their specifier from declared types visible in the file: function and closure parameters, typed local `let`/`var`, and typed stored properties of the enclosing type. `UInt32` is `%u`, `Int` is `%lld`, `Double` is `%lf`, `String` is `%@`, and so on.
   - When a plan changes a specifier, the generated "%@ is x." comment is updated.
7. **Key names follow the project.**
   - New keys reuse the dotted prefix shared by keys already referenced in the same type or file (e.g. `mac.settings.hotkey.*`).
   - Comments name the enclosing function or property and the API.
8. **Symbol detection ignores test bundles.** With `codeStyle: auto`, build configurations of unit and UI test targets are ignored (the pbxproj is parsed as a property list). `doctor` names the configurations that turn symbols off.
9. **`doctor` reports remote translators correctly.** It says when the model or endpoint is remote and whether config plus env allow it.
10. **`init` and dry runs.**
    - `init --model x:cloud` writes `allowRemote: false` with a note, or `true` with `--allow-remote`.
    - `translate --dry-run` warns when the real run would be refused.
11. **Key-style defaults.**
    - `init` infers `maxDepth` and style from the existing manual keys.
    - Only the first segment must start with a letter; later segments may start with a digit (`autoLock.15min`).
12. **Glossary.**
    - A term may list alternatives or forms (`de: ["Konto", "Konten"]`).
    - New `translator.instructions` (global and per locale) go into the prompt only, e.g. formality ("du"). Lint doesn't enforce them.

### Missing features

13. **Lint gate and status threshold.** `lint` defaults to `--fail-on warning`, so missing or stale translations and unlocalized text fail. `status --fail-under <percent>`.
14. **Don't-translate entries.**
    - `l10n_add_keys` accepts `shouldTranslate: false`.
    - A new rule L10N006 (non-text-literal, info) finds localized literals without letters (`Text("\(n)")`, `"%@ · %@"`), and `fix` adds them as don't-translate catalog entries without changing the code.
15. **`.strings` migration.** `l10n-agent migrate` converts `.lproj/*.strings` and `.stringsdict` into `.xcstrings` per folder and table:
    - keeps every value and the preceding comment
    - other locales become `translated`
    - plural `.stringsdict` entries become variations or substitutions
    - output is in Xcode format
    - it verifies against `PropertyListSerialization`, and `--remove-legacy` deletes the old files.
16. **Unused manual keys.** L10N106 also reports manual keys with no reference in any Swift file of the project: no literal, no generated symbol, and no interpolated prefix. A `keys.dynamicPrefixes` allowlist covers keys built at runtime.
17. **Plural hints from catalogs.** New rule L10N112 (info): a source value with a count specifier and "(s)", or a noun after `%lld`, but no plural variation.
18. **CLI for provided translations.** `l10n-agent set-translation --key K --locale de --value V [--catalog]`, or `--file translations.json`, using the MCP code path.
19. **`NSError` messages.** Values for `NSLocalizedDescriptionKey`, `NSLocalizedFailureReasonErrorKey`, `NSLocalizedRecoverySuggestionErrorKey` and `NSLocalizedFailureErrorKey` in dictionary literals are user-facing.
20. **`doctor` file count** excludes test files the scanner skips.

## Verification

- `scripts/check.sh` (build, all tests, secret scan).
- Re-run on a throwaway copy of pangi `feature/string-catalogs` without its workarounds (no generated-file exclude, no ignore comments): the false positives from the report are gone, and the 2 real findings remain.
- Independent review of the diff before pushing.
- README, AGENTS.md, CHANGELOG and SKILL.md updated in the same change.

## Rerun findings (R1–R11)

These come from the pangi rerun on 11d69b6 (pangi PR #20, merged). They are fixed in a follow-up PR stacked on PR #3. Each fix gets a regression test.

- **R1. Unused keys are counted per target.** A catalog's keys count as referenced only from Swift files whose catalog lookup includes that catalog (`Project.catalogURLs(forTable:file:)`); ambiguous files count for every candidate.
- **R2. `keys remove` and `keys rename` commands** (CLI and MCP).
  - Remove: refuses keys still referenced unless `--force`.
  - Rename: moves the entry and its fingerprints. With `--update-code`, it also rewrites exact literal and generated-symbol references in the files that see the catalog.
  - Both run under the lock as one transaction and check the key style and symbol collisions.
- **R3. Key names for error messages.**
  - `NSError` `userInfo` texts use the catalog's `error.` scope when it has one.
  - Long phrases keep their first two and last meaningful words (`modelContainerInitialized`), not a cut-off prefix.
- **R4. Version 0.5.0** (README, CHANGELOG, `--version`).
- **R5. `status` reports keys without text** ("4 without text, not counted").
- **R6. `migrate` comments** come, in order, from:
  1. the comment directly above the entry
  2. the `comment:` of `NSLocalizedString`/`String(localized:)` calls in the target's code
  3. the comment heading the entry's block
  4. the section comment the entry is under

  File titles and copyright headers are ignored.
- **R7. Test-target files from the pbxproj** (synchronized folders of unit and UI test targets) are skipped like test files.
- **R8. `status --fail-under`** prints the failing catalogs and locales after the table, on stdout.
- **R9. New rule L10N113 (malformed-translation, warning).**
  - It flags a translation that is a JSON object or array (or wrapped in code fences) when the source is not.
  - `translate` rejects such model output.
- **R10. `set-translation --replace-approved`** is an explicit, CLI-only way to replace a broken approved translation. The result is written as `needs_review`.
- **R11. `NSError` messages need review:** the scanner cannot tell whether the error is shown.

An independent review of these fixes found more issues, all fixed with tests in `RerunRegressionTests`:
- rename lost the source text of extracted keys
- symbol and literal rewrites touched non-localization code
- MCP rename-then-remove could delete used translations
- remove accepted `InfoPlist` and extracted keys
- nested test groups resolved wrongly
- unrelated catalogs were rewritten
- raw keys in `NSError` messages went unreported
- migrate header and comment precedence
- MCP accepted undeclared arguments
