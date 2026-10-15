# l10n-agent

> Early-stage tool. It edits Swift files and String Catalogs. Commit first, review the diffs, and keep the catalog under version control.

`l10n-agent` is a local-first localization assistant for Xcode projects. It:

- **lints** Swift code for text that reaches the UI without being localized, and String Catalogs (`.xcstrings`) for missing, stale and broken translations
- **fixes** code automatically: adds semantic keys with translator comments to the catalog and rewrites the code to use them (Xcode 26+ generated symbols such as `Text(.settingsTitle)`, or `String(localized:defaultValue:comment:)`)
- **translates** missing strings with a **local LLM** (Ollama, LM Studio or any OpenAI-compatible server on your machine), including plural forms, and protects format specifiers
- plugs into **Xcode** (inline warnings from a build phase), **CI** (SARIF), and **coding agents** (an MCP server and a Claude Code skill)

The String Catalog is the single source of truth. There is no separate JSON store to keep in sync, and git provides history and rollback.

## Requirements

- macOS 14+ with Xcode 15+ (Xcode 26+ for generated symbols)
- Swift 6 toolchain (ships with Xcode)
- For `translate`: [Ollama](https://ollama.com) or another local OpenAI-compatible server with a model installed (for example `ollama pull qwen3`)

## Install

```bash
git clone https://github.com/svcho/l10n-agent.git
cd l10n-agent
scripts/install.sh            # builds a release binary into ~/.local/bin
```

Or run from the checkout: `swift run l10n-agent --help`.

## Quick start

From your app repository (the folder with the `.xcodeproj` or `Package.swift`):

```bash
l10n-agent init               # writes .l10n-agent.yml, detects locales and a local model
l10n-agent doctor             # checks Xcode, catalogs, locales and the translator
l10n-agent lint               # what is not localized or not translated
l10n-agent fix                # preview code + catalog fixes
l10n-agent fix --apply        # apply them
l10n-agent translate          # fill translations with your local model
l10n-agent status             # coverage per locale
```

Then open the catalog in Xcode, review the machine translations (state *Needs Review*) and mark them reviewed. Approved translations are never overwritten by the tool.

## How it works

### Source of truth and review states

The tool reads and writes `.xcstrings` files losslessly: unknown fields are kept and the output is byte-identical to what Xcode writes (verified against `xcstringstool` in the test suite). It uses Xcode's own translation states:

| State | Meaning | Tool behavior |
|---|---|---|
| *(missing)* / `new` | not translated | `translate` fills it |
| `needs_review` | machine-translated, or written by an agent | `translate` may replace it when the source changes |
| `translated` | approved by a human in Xcode | never overwritten; source changes are reported (L10N103) |

### Detecting source changes

Xcode does not flag translations of manual keys when their source text changes. `l10n-agent` keeps one small file, `.l10n-agent/fingerprints.json`, that records which source text each translation was made from. Commit it with your catalogs. Editing a key's comment does not make translations stale; editing its text does.

After reviewing a translation whose source changed, run `l10n-agent accept --key <key>` (or edit the translation in Xcode and accept).

### Keys and code style

By default, fixes use **semantic keys** (`settings.notifications.title`) with a `comment` for translators:

| Context | Generated symbols (Xcode 26+) | Literal style |
|---|---|---|
| `Text("Welcome")` | `Text(.homeWelcome)` | `Text(String(localized: "home.welcome", defaultValue: "Welcome", comment: "…"))` |
| `Button("Save") {}` | `Button(String(localized: .settingsSaveButton)) {}` | `Button(String(localized: "settings.save.button", defaultValue: "Save", comment: "…")) {}` |
| `label.text = "Hello \(name)"` | `label.text = String(localized: .profileHello(name))` | `label.text = String(localized: "profile.hello", defaultValue: "Hello \(name)", comment: "…")` |
| `Settings.xcstrings` table | `.Settings.someKey` | adds `table: "Settings"` |

`codeStyle: auto` (default) decides per file. It uses generated symbols when the Xcode project that owns the file sets `STRING_CATALOG_GENERATE_SYMBOLS = YES` (the default for projects created with Xcode 26) and no configuration sets it to `NO`. It uses literals for everything else: other projects, mixed settings and Swift package targets. Generated symbol names follow Xcode's rules exactly (checked against `xcstringstool generate-symbols`), and keys that would produce colliding or reserved symbols are rejected before Xcode fails the build.

When an English-text key such as `Text("Welcome back")` already has translations, `fix` copies them to the new semantic key, so no translation work is lost.

Interpolations become placeholders (`%@`, `%lld`). Their types are inferred from syntax only, so fixes with guessed types are marked **needsReview** and are applied only with `--include-review` (or after you, or an agent, confirm them in the plan).

`fix` never rewrites code it cannot rewrite faithfully. These sites are reported as *skipped* with a reason:

- the text is part of a larger expression inside `Text(...)`/`String(localized:)` (for example `Text(flag ? "On" : "Off")`)
- the call has arguments the rewrite would drop (`bundle:`, `locale:`, `defaultValue:`, or a `table:`/`comment:` that is not a plain string literal)
- multiline or raw literals
- `String(format:)` and literals that already contain printf specifiers

A developer's `comment:` argument becomes the catalog comment. In literal style, files inside a Swift package get `bundle: .module`.

Saved plans are treated as untrusted input. `apply` re-scans every file and takes code and interpolations from the source. Only `key`, `comment`, `placeholders[].specifier` and `status` come from the plan. Each key goes into the catalog computed for its file, and the code style must match the project's current setting.

## Commands

| Command | Purpose |
|---|---|
| `lint [--format text\|xcode\|json\|sarif] [--rules …] [--files …] [--fail-on error\|warning\|info]` | Report findings. Exit code 1 when a finding reaches `--fail-on` (default `error`). |
| `fix [--apply] [--include-review] [--llm-keys] [--plan-out plan.json] [--plan plan.json] [--ids …] [--files …]` | Preview or apply code + catalog fixes. `--llm-keys` asks the local model for better key names and comments. Plans can be saved, edited and applied later; apply refuses if a file changed in between. |
| `translate [--locale …] [--key …] [--catalog …] [--model …] [--batch-size N] [--dry-run]` | Translate missing and stale strings with the local model. |
| `status` | Coverage per catalog and locale. |
| `accept [--key …] [--locale …]` | Mark translations as matching the current source text. |
| `doctor` | Environment and configuration checks. |
| `init [--model …] [--force]` | Create `.l10n-agent.yml` and record fingerprints for existing translations. |
| `rules` | List lint rules. |
| `mcp` | Run the MCP server over stdio. |

All commands accept `--path <project root>` (default: current directory). `--format json` is available for `lint`, `fix`, `translate`, `status` and `doctor`.

## Lint rules

| ID | Name | Default | Finds |
|---|---|---|---|
| L10N001 | unlocalized-string | warning | UI text that is never localized: UIKit/AppKit properties and initializers (`label.text`, `UIAlertController(title:)`, `setTitle(_:for:)`), user-facing variables (`let errorTitle = "…"`, `var title: String { "…" }`), custom APIs from config |
| L10N002 | text-as-key | warning | Localized text that uses its English copy as key (`Text("Welcome")`, `Button("Save")`, `String(localized: "Sign out")`). Off when `semanticKeys: false`. |
| L10N003 | concatenated-string | warning | `"Hello " + name` and `String(format:)` with UI text |
| L10N004 | missing-key | error | `String(localized: "a.key")` / `Text("a.key")` with no such key in the catalog |
| L10N005 | plural-candidate | info | `"\(count) items"`: needs a plural variation |
| L10N100 | catalog-parse | error | Catalog is not valid JSON |
| L10N101 | missing-translation | warning | Key not translated for a target locale (including missing plural categories) |
| L10N102 | needs-review | info | Translation waiting for review |
| L10N103 | stale-translation | warning | Source text changed since the translation was made |
| L10N104 | format-mismatch | error | Translation's format specifiers differ from the source by argument index or type (reordering with `%2$@` is fine) |
| L10N105 | missing-comment | info | Key without a translator comment |
| L10N106 | unused-key | info | Xcode marked the key stale (no longer referenced) |
| L10N107 | key-style | warning | Manual key violates the configured key style |
| L10N108 | glossary | warning | Translation does not use the required glossary term |
| L10N109 | untranslated-copy | info | Translation identical to the source |
| L10N110 | symbol-collision | error | Keys generate the same or a reserved Swift symbol (Xcode build error) |
| L10N111 | source-language | warning | Catalog `sourceLanguage` differs from the project |

Detection uses SwiftSyntax and an allowlist of user-facing APIs, so logging (`print`, `Logger`), asset names (`Image("logo")`), URLs, `UserDefaults` keys and identifiers stay quiet. Code in `#if DEBUG`, `#Preview`, `PreviewProvider` and test files is skipped. `Text(verbatim:)` is treated as an intentional opt-out.

### Suppressing findings

```swift
label.text = "™"                       // l10n-agent:ignore
// l10n-agent:ignore L10N001
debugLabel.text = "Internal build"
// l10n-agent:disable-file L10N002      (anywhere in the file)
```

Rule severities can be changed or turned off in `.l10n-agent.yml` under `rules:`.

## Translating with a local model

```yaml
translator:
  provider: ollama            # or: openai (LM Studio, llama.cpp server, vLLM)
  baseURL: http://localhost:11434
  model: qwen3                # any installed local model
  batchSize: 20
  maxRetries: 2
  allowRemote: false
```

- Strings are sent in batches with their key and comment as context, plus your glossary.
- Format specifiers are replaced by tokens (`⟦1⟧`, `⟦@files⟧`) before sending and restored afterwards. If the model reorders arguments, positional specifiers (`%2$lld … %1$@`) are written. Answers that drop, add or retype a placeholder are rejected and retried with feedback.
- Plural keys get exactly the CLDR categories of the target language (`one/few/many/other` for Polish, `other` for Japanese, `one/two/few/many/other` for Maltese). A language missing from the built-in table is never guessed: its plural keys are reported until you list its categories under `pluralCategories`. `%#@name@` substitutions keep their `argNum` and `formatSpecifier`.
- Each request numbers its items 1…n, and retries go one item at a time. Answers that look shifted between items (different sources, identical translations) are retried individually.
- Machine translations (`needs_review`) whose placeholders are broken are retranslated. Approved translations are never touched, not even single plural categories. They are listed under *approved skipped* when their source changed or their structure differs (for example plain text where the source is now plural).
- Progress is written after each batch, so an interrupted run just continues where it stopped the next time.
- **Local only by default.** Non-localhost endpoints and Ollama `:cloud` models are refused. Remote use needs both `allowRemote: true` in the config **and** `L10N_AGENT_ALLOW_REMOTE=1` in your environment, so a cloned repository cannot send your strings elsewhere on its own. For OpenAI-compatible servers that need a key, set `L10N_AGENT_API_KEY`.
- Small models work for checking the pipeline: the test runs used `translategemma` (4B) and `qwen3.8:27b`. A 4B model may fail to return plural forms. Those keys are reported as failed and left untouched, so you can rerun with a larger model or translate them in Xcode.

## Xcode integration

Add a **Run Script** build phase to the app target to see findings inline in Xcode:

```bash
if command -v l10n-agent >/dev/null; then
  l10n-agent lint --format xcode --path "$SRCROOT" || true
fi
```

With *User Script Sandboxing* enabled (`ENABLE_USER_SCRIPT_SANDBOXING = YES`, the default for new projects) the script cannot read your sources; disable it for this target or run the lint as a pre-commit hook or CI step instead. Remove `|| true` to fail the build on errors.

For CI, upload SARIF to GitHub code scanning:

```bash
l10n-agent lint --format sarif > l10n.sarif
```

## Coding agents

### MCP server

```bash
claude mcp add --scope project l10n-agent -- l10n-agent mcp
```

or in `.mcp.json`:

```json
{ "mcpServers": { "l10n-agent": { "command": "l10n-agent", "args": ["mcp"] } } }
```

Tools: `l10n_lint`, `l10n_status`, `l10n_plan_fixes`, `l10n_apply_fixes`, `l10n_translate`, `l10n_set_translations`, `l10n_add_keys`, `l10n_accept`.

An agent can lint, plan fixes, rename keys or improve comments in the plan, and apply it. It can then run the local translator or supply its own translations. Its translations are validated for placeholder parity, accepted only for target locales, and written as `needs_review`. All paths are confined to the project root, including through symlinks.

### Claude Code skill

Copy `skills/apple-l10n` to `~/.claude/skills/` (or `.claude/skills/` in your app repo). The skill tells Claude when and how to run the lint → fix → translate loop and how to write new UI code with localized keys from the start.

## Configuration

`.l10n-agent.yml` (all keys optional; unknown keys are an error; `Package.swift` manifests are never scanned):

```yaml
sourceLanguage: en
locales: [de, ja, pl]               # default: the Xcode project's knownRegions
catalog: App/Localizable.xcstrings  # where new keys go (default: nearest Localizable.xcstrings)
catalogRoutes:                      # only for layouts the tool cannot infer (e.g. Sources/X + Resources/X)
  - { files: "Sources/Shared/**", catalog: "Resources/Shared/Localizable.xcstrings" }
codeStyle: auto                     # auto | symbols | literal
semanticKeys: true
keys:
  style: dotted.camel               # dotted.camel | dotted.lower | dotted.snake
  minDepth: 2
  maxDepth: 4
  scopes: []                        # allowed first segments
  forbiddenPrefixes: ["tmp.", "debug.", "test."]
include: []                         # globs; default everything
exclude: ["**/Tests/**"]
rules: { L10N105: off }
glossary:
  "Acme Cloud": { de: "Acme Cloud", ja: "Acme Cloud" }
pluralCategories: { xx: [one, few, other] }   # only for languages missing from the built-in CLDR table
userFacing:
  functions: [{ name: PrimaryButton, labels: ["_"] }]
  properties: [headlineCopy]
translator: { provider: ollama, model: qwen3 }
```

## Adoption guides

**App with a String Catalog already.** Run `init`, then `lint`. Existing translations are adopted as they are (fingerprints are recorded so future source edits are detected). Use `fix` to move English-text keys to semantic keys; existing translations move with them.

**App with legacy `Localizable.strings`.** In Xcode, right-click the `.strings` file and choose *Migrate to String Catalog*, then follow the steps above.

**App without localization.** Add languages under *Project > Info > Localizations*. Run `l10n-agent fix --apply`: it creates `Localizable.xcstrings` next to your sources if none exists (make sure the file is a member of your app target), adds keys and rewrites the code. Then run `translate`.

**Writing new UI code.** Add keys first (`l10n_add_keys` for agents, or in Xcode's catalog editor) and reference them through generated symbols: `Text(.onboardingWelcomeTitle)`, `String(localized: .settingsSaveButton)`. `lint` catches anything that slips through.

## Upgrading from 0.3 (TypeScript, iOS + Android)

Version 0.4 is a rewrite in Swift that targets Apple platforms only. The `l10n/` canonical JSON store, `sync`, Android `strings.xml` support, `rollback`, `repair`, `import` and Codex CLI translation are gone. If you used `.xcstrings`, your catalog already holds your translations; run `l10n-agent init` and delete the `l10n/` folder once you have checked the catalog. Translations marked `reviewed: true` in the old JSON files correspond to state `translated` in the catalog.

## Development

```bash
swift build
swift test                 # includes checks against xcstringstool and an iOS type-check when Xcode is installed
scripts/check.sh           # build, test and secret scan
git config core.hooksPath .githooks   # run the secret scan before each commit
```

Tests never call a live model; the translator is replaced by a scripted fake. Do not commit credentials, `.env*` files, private keys or recorded model output.
