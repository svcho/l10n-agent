---
name: apple-l10n
description: Localize Xcode (iOS/macOS) apps with l10n-agent. Use when adding or changing user-facing text in Swift/SwiftUI/UIKit code, when the user asks to localize, translate, or check localization, before opening a PR that touches UI strings, or when lint shows L10N rule findings. Finds unlocalized strings, rewrites code to semantic String Catalog keys, and translates with a local LLM.
---

# Localizing an Xcode project with l10n-agent

`l10n-agent` treats the String Catalogs (`*.xcstrings`) as the source of truth. Use its MCP tools (`l10n_*`) when they are available; otherwise run the CLI with `--format json` and read the output.

## When to run

- After writing or changing UI text in Swift.
- When asked to localize, translate, add a language, or "check localization".
- Before finishing a task or PR that touched views, alerts, buttons or user-facing models.

## Loop

0. **Legacy projects**: if the app still has `.lproj/*.strings`, run `l10n_migrate_strings` (or `l10n-agent migrate`, then `--apply --remove-legacy`) first.
1. **Lint**: `l10n_lint` (or `l10n-agent lint --format json`). Code findings: L10N001 unlocalized, L10N002 English text used as key, L10N003 concatenation, L10N004 missing key, L10N006 letterless literal to mark Don't translate. Catalog findings: L10N101 missing translation, L10N103 stale, L10N104 format mismatch, L10N106 unused key, L10N110 symbol collision, L10N112 value that needs a plural variation. The CLI exits 1 on warnings; `l10n-agent status --fail-under 100` checks coverage.
2. **Plan fixes**: `l10n_plan_fixes` (or `l10n-agent fix --format json --plan-out plan.json`). Review every item:
   - `key`: semantic and stable (`<screen>.<thing>.<role>`, e.g. `settings.notifications.title`). Never derive keys from whole sentences. Reuse `common.*` keys for generic words like Cancel/OK/Done.
   - `comment`: tell translators where the text appears and what each placeholder means.
   - `placeholders[].specifier`: confirm the type of each interpolated expression (`%@` String/objects, `%lld` Int, `%u` UInt32, `%lf` Double). Declared types are already used; `confident: false` means the type was guessed.
   - `needsReview` items were found by a name or label only, or have guessed types: check that the text is really shown to users, then set `status` to `ready`. Items left `needsReview` are not applied.
   - Preview an edited plan with `l10n-agent fix --plan plan.json` (no `--apply`); it shows exactly what will be written.
3. **Apply**: `l10n_apply_fixes` with the (edited) plan, or `l10n-agent fix --plan plan.json --apply`. Re-run lint afterwards.
4. **Translate**: either `l10n_translate` (local model; check `dry_run: true` first on large projects) or translate yourself with `l10n_set_translations` (CLI: `l10n-agent set-translation --key K --locale de --value "…"`). Keep every format specifier; use positional forms (`%2$lld … %1$@`) when word order changes. For plural keys provide all CLDR categories of the language.
5. **Report**: summarize what changed and remind the user that translations are `needs_review` until approved in Xcode's String Catalog editor.

## Writing new UI code

Prefer adding keys first, then referencing them:

```swift
// l10n_add_keys: [{ "key": "profile.greeting", "value": "Hello %@", "comment": "Greeting on the profile screen. %@ is the user's first name." }]
Text(.profileGreeting(user.firstName))          // generated symbols (Xcode 26+)
label.text = String(localized: .profileGreeting(user.firstName))
```

Without generated symbols: `String(localized: "profile.greeting", defaultValue: "Hello \(user.firstName)", comment: "…")`.

Do not build UI text with `+` or `String(format:)`; use one localized string with interpolation. Use a plural variation for counts ("\(count) items").

## Rules

- Never change translations in state `translated`; they were approved by a human.
- Do not edit `.xcstrings` by hand when a tool can do it; the tools keep Xcode's exact formatting.
- `.l10n-agent/fingerprints.json` must be committed with catalog changes.
- Suppress intentional non-localized text with `// l10n-agent:ignore L10N001` and a short reason.
- Literals without text (`Text("\(count)")`) need no translation: fix L10N006 (or `l10n_add_keys` with `shouldTranslate: false`) marks them Don't translate.
- Translation goes to a cloud model only when the project config has `translator.allowRemote: true` and the user exported `L10N_AGENT_ALLOW_REMOTE=1`; never set the variable yourself.
