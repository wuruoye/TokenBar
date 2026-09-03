<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="TokenBar app icon">
</p>

<h1 align="center">TokenBar</h1>

<p align="center">
  Codex, Claude Code, Grok Build, and Antigravity quota and token activity, at a glance in your macOS menu bar.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-2021-000000?logo=rust&logoColor=white">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2ea44f"></a>
</p>

<p align="center">
  <img src="docs/images/dashboard.png" width="460" alt="TokenBar dashboard showing Codex quota, today's token usage, weekly-reset totals, and recent activity">
</p>

TokenBar is a native, standalone macOS menu bar app for Codex, Claude Code, Grok Build, and Antigravity. It combines each platform's quota windows with local token accounting, costs, session history, user turns, and main/subagent request details. It does not require CodexBar or Tokscale to build or run.

> TokenBar is an independent project and is not affiliated with or endorsed by OpenAI, Anthropic, xAI, or Google.

## Highlights

- See one compact menu bar item with separate Codex, Claude, Grok, and Antigravity `T/W` sections.
- Click a provider section to open TokenBar directly on that platform's tab.
- Switch between the **Codex**, **Claude**, **Grok**, and **Antigravity** tabs; each tab uses the same TokenBar sections while optional quota rows collapse when that provider does not return them. Antigravity publishes no local quota window, so its tab drops the quota card entirely.
- Hide or restore the Claude, Grok, and Antigravity sections and tabs immediately from Settings, without restarting TokenBar.
- Track every provider's quota window independently without mixing percentages or reset cycles.
- Track weekly and available 5-hour quota windows, their reset times, and Codex extra reset credits. A row stays hidden when its provider does not return that window.
- Optionally celebrate confirmed 5-hour or weekly resets with click-through, full-screen confetti launched from that provider's menu bar section.
- Compare weekly usage with a linear seven-day pace calculated from the last weekly reset, or switch to a five-workday pace that pauses on weekends.
- Record each day's observed weekly-quota increase alongside Today and the selected Activity date, using the same UTC or local statistics timezone as token totals.
- Review today and since-weekly-reset totals for input, output, cache, reasoning, estimated cost, sessions, and turns; Today also shows the estimated cost of each token category.
- Explore 7-day and 30-day activity, then hover a day to inspect usage by model.
- Optionally track Codex Memory extraction (Phase 1) and consolidation (Phase 2) tokens by input, cached input, cache write, output, and reasoning output on the **Codex** tab only.
- Browse today's recent sessions in the main menu, or select any date in Activity Detail to load that day's sessions from this Mac's local logs. Provider-generated titles, session opening, and turn/request drill-down remain available for historical dates.
- Drill down from a session to each root-prompt turn, then to the main and subagent requests that contributed to it.
- Compare weighted average generation throughput from local output, reasoning-token, and active model-request duration data at the day, session, turn, and physical-request levels.
- See `FAST` or `MIXED` badges on sessions, turns, and physical requests that used Codex Fast mode.
- Hover a physical request to load its full prompt and output, or click it to copy a stable Tokscale-compatible locator.
- Optionally combine privacy-redacted activity snapshots from Windows, Linux, and other Macs through a self-hosted HTTPS sync service; remote sessions are labeled by device and stay read-only.
- Optionally launch TokenBar automatically when you sign in to macOS, with approval handled through the system Login Items settings.
- Choose a theme color, recent-session limit, background refresh interval, and whether full request content appears on hover.

## Screenshots

<p align="center">
  <strong>Turn and agent drill-down</strong><br><br>
  <img src="docs/images/turn-agent-drilldown.png" width="680" alt="A TokenBar turn expanded into main and subagent requests">
</p>

_The screenshots use generated demo data and contain no real account or session content._

## Requirements

- macOS 14 or later.
- At least one supported client:
  - [Codex CLI](https://developers.openai.com/codex/cli/) installed and authenticated. Running `codex` in Terminal should work before starting TokenBar; `CODEX_CLI_PATH` can point to a nonstandard installation.
  - Claude Code installed, used at least once, and authenticated. TokenBar reads its local projects from `~/.claude/projects` (or `CLAUDE_CONFIG_DIR`) and its existing OAuth credential for quota.
  - [Grok Build](https://x.ai/cli) installed, used at least once, and authenticated. TokenBar reads durable local sessions and the latest CLI-written quota snapshot from `~/.grok` (or `GROK_HOME`).
  - [Antigravity](https://antigravity.google/) installed and used at least once. TokenBar reads the per-conversation SQLite databases under `~/.gemini/antigravity/conversations` (or `ANTIGRAVITY_HOME`). Antigravity exposes no local quota window, so only token activity is reported.
- To build from source: Apple Swift 6.2 command-line tools and a recent stable Rust toolchain with Cargo.

TokenBar is currently distributed from source. There is no prebuilt, notarized GitHub release yet.

## Installation

Clone the repository, build the two native executables, and package the app:

```bash
git clone https://github.com/wuruoye/TokenBar.git
cd TokenBar
./Scripts/package_app.sh
open TokenBar.app
```

`package_app.sh` creates `TokenBar.app` for the current Mac architecture and ad-hoc signs it by default. It builds the Swift menu bar app and embeds the Rust activity helper in the bundle.

Repeated local builds that use Keychain-backed settings should use a stable signing identity. Put the exact identity name in the Git-ignored `.tokenbar-codesign-identity` file once; `package_app.sh` will reuse it unless `CODESIGN_IDENTITY` is set explicitly. This prevents each ad-hoc rebuild from getting a new code identity and prompting again for access to an existing Keychain item.

After upgrading from an ad-hoc build, TokenBar reads the legacy activity-sync credential once and immediately migrates it to a new Keychain item owned by the stable app identity. macOS can require one final authorization for that legacy read; later launches use only the migrated item.

```bash
printf '%s\n' 'Apple Development: Your Name (TEAMID)' > .tokenbar-codesign-identity
./Scripts/package_app.sh
```

For a Developer ID build, provide a signing identity:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./Scripts/package_app.sh
```

Signing with a Developer ID does not notarize the bundle; distribution still requires the normal Apple notarization workflow.

## Usage

1. Launch `TokenBar.app`. TokenBar appears only in the menu bar; it has no Dock icon.
2. Click a provider's `T/W` section to open its matching tab. Opening the menu refreshes local activity and any quota data older than one minute.
3. Use the platform tabs to switch providers without closing the menu. Quota, Today, Activity, and Recent Sessions all follow the selected tab.
4. Hover **Activity** and move across the daily chart; the selected date's session submenu opens directly and updates with the highlighted bar.
5. Hover **Codex Memory** for Today/30-day Phase 1 and Phase 2 details. If Codex is not configured yet, use the explicit enable button there or in Settings. Turn off **Monitor Codex Memory usage** in Settings to hide this section and stop its local receiver.
6. Click a recent or Activity Detail session to open it in the matching desktop app, resume a Grok session in Terminal, or reopen an Antigravity conversation's workspace folder in Antigravity. Hover the row to inspect its turns; a turn represents one root user prompt and aggregates all main/subagent work attributed to that prompt.
7. If a turn has multiple contributing requests, hover it to expand the main and subagent rows. Hover a request again to load its full prompt and output.
8. Use **Copy Session** or click a request row to copy its stable locator.

Useful shortcuts:

- `Command-R`: refresh without closing the open menu.
- `Command-,`: open Settings.
- `Command-Q`: quit TokenBar.

The default background refresh interval is five minutes. Opening the menu always starts a fresh update, independent of that timer.

## How counting works

TokenBar normalizes Codex, Claude Code, Grok Build, and Antigravity into the same three activity levels:

1. **Session** — a root conversation within one platform. TokenBar prefers the Codex-generated title when available and otherwise falls back to the first useful prompt.
2. **Turn** — the interval beginning with a root user prompt and ending before the next root user prompt. Main-thread and subagent requests launched for that prompt are aggregated into the turn, including subagent work that finishes later.
3. **Physical request** — the original main or subagent activity recorded in a specific client session log. These rows retain their own platform, model, token, cache, cost, duration, prompt/output detail, and copy locator.

Platform is part of every aggregation and identity key, so sessions from different clients with the same raw ID remain separate. Claude Code's repeated streaming snapshots are deduplicated by message/request identity before totals are calculated.

Token totals contain input, output, cache-read, cache-write, and reasoning buckets. Codex, Claude Code, Grok, and Antigravity report overlapping total fields; TokenBar converts them into disjoint buckets before aggregation so cache and reasoning are counted once. Claude Code reports `output_tokens_details.thinking_tokens` as a subset of its billed output, so TokenBar moves that count into the reasoning bucket after deduplicating streaming snapshots. Both buckets are billed at the output rate, leaving the estimate unchanged. A request whose reported thinking count exceeds its own output total keeps the raw output and drops the unusable breakdown. Complete Grok turn costs are provider-reported; partial or incomplete Grok costs stay unknown rather than appearing as zero-cost usage. Antigravity records a request's cached prefix, its total output, and the thinking share of that output, so TokenBar keeps the cached count in cache-read and splits the remainder into output and reasoning. Antigravity runs both Gemini and Claude models, so each request is priced from the catalog that owns its model: Anthropic's for Claude, and a bundled Google Gemini table for the rest. Gemini bills thinking tokens at the output rate, and Gemini Pro requests switch to the long-context rate above a 200K-token prompt.

First-token latency appears in seconds beside generation speed in `tok/s`. Session, day, and range rows use the arithmetic mean of the available turn samples. TokenBar prefers Codex's recorded first-token metric and otherwise uses its first durable response item, approximates Claude latency from the local request boundary to the UUIDv7 timestamp embedded in its message ID, uses Grok's first durable output chunk or completed turn, and uses the first-token timestamp Antigravity records on each generation step.

Generation speed divides generated output plus reasoning tokens by the summed active duration of the underlying model requests. Tool execution, polling, and other time between model requests stay in the displayed turn duration but are excluded from TPS. TokenBar omits a performance metric when a local transcript does not expose enough timing data to calculate it reliably.

Codex records Fast mode as the `priority` service tier (`fast` is also accepted for older logs); `default` and `standard` are treated as Standard. When every service-tier snapshot in one physical session agrees, TokenBar applies that tier to the whole session, including usage written before the first snapshot. If a session switches tier, TokenBar follows the timeline from each snapshot and leaves any prefix before the first snapshot unknown. Subagents inherit the last tier from their replayed parent context without counting the parent's earlier tier history as their own. A turn containing both Fast and Standard physical requests is marked `MIXED`.

`Cache` is the percentage of prompt tokens served from the cache:

```text
cache-read tokens / (input tokens + cache-read tokens + cache-write tokens) × 100%
```

Costs prefixed with `~` are compatibility estimates, not provider invoices. Provider-reported costs, when present in the source data, remain authoritative. TokenBar refreshes OpenAI's official Markdown pricing table at most once every 24 hours and strictly validates both its Standard and Fast schemas before use; a validated local cache and reviewed built-in rates cover offline starts and failed refreshes. When a scan finds a Codex or Claude request with tokens but no price, TokenBar bypasses the 24-hour freshness window, attempts one matching catalog refresh, and reruns the helper after a successful update. Repeated unknown-model refreshes are limited to once per hour. TokenBar reads only the non-sensitive `auth_mode` field from the active Codex home's `auth.json` to choose the Fast basis. ChatGPT subscription sessions follow Codex credit consumption—GPT-5.4 uses 2× and GPT-5.5/5.6 use 2.5×—while API Key sessions use the official Fast table. See OpenAI's [Codex Fast mode documentation](https://learn.chatgpt.com/docs/agent-configuration/speed#fast-mode) and [pricing table](https://developers.openai.com/api/docs/pricing). A model without verified Fast pricing keeps its standard estimate.

Codex reports `cached_input_tokens` and `cache_write_input_tokens` as subcategories of `input_tokens`. TokenBar separates those buckets internally so their rows add back to the provider's raw input total exactly once. In the dashboard, cache writes are included in **Input**, while **Cache** means cache reads; the internal split is retained so each category can use its own price. For GPT-5.6, cache writes use OpenAI's documented 1.25× uncached-input rate; models without a verified cache-write rate remain unpriced if a nonzero write is reported. See the [GPT-5.6 model guidance](https://developers.openai.com/api/docs/guides/latest-model#using-gpt-5-6).

Recognized OpenAI model IDs retain the estimate behind custom Codex gateways, and the unpriced research-preview `gpt-5.3-codex-spark` ID uses the public GPT-5.3-Codex rate so historical totals stay aligned with Tokscale. Unknown model families remain unpriced. For GPT-5.4, GPT-5.5, and GPT-5.6, TokenBar applies the official long-context table row to each physical model request whose raw input exceeds 272K tokens. The threshold is evaluated before turn, session, and daily aggregation. See OpenAI's [pricing table](https://developers.openai.com/api/docs/pricing).

Claude compatibility estimates use a reviewed built-in fallback plus Anthropic's official [pricing table](https://platform.claude.com/docs/en/about-claude/pricing). TokenBar checks the official Markdown catalog at most once every 24 hours, validates its document shape before caching it, strictly validates the table schema and rates before use, and keeps the previous catalog or built-in rates when the request or validation fails. Claude Code's 5-minute and 1-hour cache-write token buckets are priced separately when the transcript exposes that breakdown. Unknown model IDs still remain unpriced instead of inheriting a nearby model's rate.

Fast pricing never changes raw token/cache counts. Quota percentages come from Codex and are not multiplied again; quota and local token totals measure different things and should not be expected to map one-to-one.

### Codex Memory tokens

When **Monitor Codex Memory usage** is on, TokenBar runs a metrics-only OTLP/HTTP JSON receiver on `127.0.0.1:4318`. The receiver accepts only `POST /v1/metrics`, retains only `codex.memory.phase1.token_usage` and `codex.memory.phase2.token_usage`, and stores observations in `~/Library/Application Support/TokenBar/memory-telemetry.sqlite`. It reads histogram `sum`; histogram `count` is only the number of observations and is never treated as token usage. Turning monitoring off stops the receiver, hides Memory usage, and excludes the local Memory snapshot from multi-device sync without changing Codex's own memory setting.

The owner-only database keeps each observation plus a persisted series watermark. DELTA points are added once per unique interval. CUMULATIVE points add only the increase over the latest in-order watermark; duplicate and out-of-order exports add zero, while a new start time or resource series is counted independently. This state survives TokenBar and Codex process restarts. The Memory detail view reports how many raw observations are stored locally.

The main menu shows the 30-day Memory total, the Phase 1/Phase 2 split, and compact input/cache/output/reasoning fields. Its detail submenu adds Today/30 days selection, a daily stacked chart, complete token-type breakdowns for both phases, receiver/config status, collection timestamps, and the local observation count.

Collection is opt-in. When no existing `[otel]` section is present, **Enable Memory Metrics** appends user-level Codex settings that enable analytics, route metrics to TokenBar in JSON, and keep log, trace, and prompt export disabled. TokenBar creates a backup before changing the file. If `[otel]` already exists, TokenBar preserves it and asks you to configure its metrics exporter manually. Codex loads the exporter when its local process starts, so restart Codex or ChatGPT once after enabling. Collection starts with future Memory runs; TokenBar does not invent or backfill historical Phase 1 usage.

The UI distinguishes receiver health, the last OTLP connection from any Codex metric export, and the last recognized Phase 1 or Phase 2 export. A healthy receiver or OTLP connection alone does not mean that a qualifying asynchronous Memory run has occurred.

The memory histogram does not provide reliable pricing attribution. TokenBar therefore shows those tokens without a guessed cost. Reasoning output is exposed as its own diagnostic field but remains a subset of output, so the component rows should not be added together.

## Privacy

TokenBar is designed to keep session content local:

- The Rust helper reads Codex JSONL logs under `~/.codex/sessions` and `~/.codex/archived_sessions`, or the equivalent directory selected by `CODEX_HOME`.
- It reads Claude Code JSONL logs under `~/.claude/projects`, or the equivalent directory selected by `CLAUDE_CONFIG_DIR`.
- It reads Grok Build's `summary.json` and durable `updates.jsonl` files under `~/.grok/sessions`, or the equivalent directory selected by `GROK_HOME`.
- It opens Antigravity's conversation databases read-only under `~/.gemini/antigravity/conversations`, or the equivalent directory selected by `ANTIGRAVITY_HOME`, and reads conversation titles from `agyhub_summaries_proto.pb` in the same directory. TokenBar never writes to Antigravity's data.
- Codex-generated titles are read from `session_index.jsonl` in the same Codex home directory.
- Local activity parsing, turn attribution, and pricing never upload session content or read a Tokscale runtime cache. Pricing refreshes are unauthenticated reads of OpenAI's and Anthropic's public pricing Markdown at most once every 24 hours. Validated files are stored under `~/Library/Application Support/TokenBar/` with owner-only permissions.
- Full prompt and output text is read lazily when a request detail menu opens and is retained in memory only for the current process.
- The persistent activity cache omits titles, prompt/output previews, and source paths, including those nested under physical requests. It is stored at `~/Library/Application Support/TokenBar/activity-snapshot.json` with owner-only permissions.
- The last successful provider quota snapshots are stored at `~/Library/Application Support/TokenBar/quota-snapshots.json`, also with owner-only permissions, so a temporary provider rate limit does not blank the menu.
- Per-day weekly-quota changes are stored at `~/Library/Application Support/TokenBar/weekly-quota-usage.json` with owner-only permissions. Timestamped increases are retained for the 30-day Activity range and regroup when the statistics timezone changes. The first sample in each weekly cycle is a baseline, so usage from before that sample is not attributed to its day.
- The optional Codex Memory receiver stores token counts, timestamps, metric names, deduplication fingerprints, and a small allowlist of process identity fields. It discards the full request body and never stores prompts, traces, logs, arbitrary metric attributes, or unrelated metrics.
- TokenBar does not send its own telemetry or analytics. The Codex Memory integration receives the two selected metrics over loopback only.

Quota is the intentional network-facing part of the Codex integration. TokenBar asks the locally installed Codex app-server for Codex rate limits. Claude quota stays local: TokenBar reads Claude Desktop's recent usage sample and a sanitized Claude Code statusline snapshot at `~/Library/Application Support/TokenBar/claude-rate-limits.json`. The snapshot contains only subscriber rate-limit windows and sample time, so valid future reset times can supplement fresher Desktop percentages without storing the rest of the statusline payload. If Claude omits reset metadata, this build initially schedules the weekly reset for Sunday at 20:00 local time, persists that anchor in the quota cache, and re-anchors either window when usage falls from above 1% to at most 1%; expired inferred anchors advance by whole window durations. A later provider reset always takes precedence. TokenBar never reads Claude Code credentials from `.credentials.json` or the macOS Keychain and never calls Anthropic's OAuth usage endpoint. Grok quota is also local: TokenBar reads the latest billing snapshot already written to Grok Build's local unified log, and never reads Grok's `auth.json` or sends an authenticated Grok request. Antigravity contributes no quota at all: TokenBar only reads its local conversation databases and never contacts Google. TokenBar does not refresh, rewrite, or copy provider credentials into its own cache. The optional Codex extra-reset lookup uses the existing Codex OAuth credential. If Codex's `config.toml` explicitly sets a custom HTTPS `chatgpt_base_url`, TokenBar honors that origin and sends the same bearer credential to it; redirects remain restricted to that exact HTTPS origin.

## Settings

Open **Settings** with `Command-,` to configure:

- **Theme color:** System, Blue, Purple, Green, Orange, or Pink.
- **Show Claude Code:** add or remove the Claude `T/W` section and Claude tab immediately. Claude quota uses only local statusline and Claude Desktop samples; TokenBar never reads the Claude credential.
- **Show Grok Build:** add or remove the Grok `T/W` section and Grok tab immediately. When hidden, TokenBar skips Grok quota-log refreshes.
- **Show Antigravity:** add or remove the Antigravity `T/W` section and Antigravity tab immediately.
- **Use weekdays only for weekly pace:** split weekly pace into five workdays and pause expected usage on Saturday and Sunday.
- **Statistics timezone:** UTC to match the Codex usage dashboard, or local time.
- **Recent sessions:** show 5 or 10 sessions before the **Show More** control.
- **Full request content:** enable or disable the last hover level for prompts and outputs.
- **Codex Memory:** start or stop TokenBar's Memory monitor, inspect the loopback receiver and Codex configuration state, and explicitly enable metrics when no custom `[otel]` configuration exists.
- **Multi-device sync:** configure the optional HTTPS endpoint, Keychain-backed device access token, and this Mac's stable device identity. Headless Windows/Linux components and the self-hosted service are documented in [`Sync/README.md`](Sync/README.md).
- **Background refresh:** 1, 5, 10, or 15 minutes.
- **Reset celebrations:** play confetti for 5-hour resets, weekly resets, both, or neither, with a test button for previewing the animation immediately.

## Development

No sibling repository checkout is required. The Swift package contains the menu bar UI and independent provider quota clients; `Helper` contains the Codex, Claude, Grok, and Antigravity adapters plus the shared Rust activity aggregator.

### Build and run

For a development run, build the helper first so the Swift app can discover it:

```bash
cargo build --manifest-path Helper/Cargo.toml
swift run TokenBar
```

Build both projects without launching the app:

```bash
swift build
cargo build --locked --manifest-path Helper/Cargo.toml
```

### Test

The test suites use fixtures and do not require live provider accounts:

```bash
swift test
cargo test --locked --manifest-path Helper/Cargo.toml
```

When `Helper/Cargo.lock` changes, refresh the bundled Rust license catalog:

```bash
cargo install cargo-about --locked --features cli
./Scripts/generate_licenses.sh
```

### Package

```bash
./Scripts/package_app.sh
```

The packaging script supports these optional environment variables:

| Variable | Purpose |
| --- | --- |
| `CODESIGN_IDENTITY` | Signing identity; overrides `.tokenbar-codesign-identity` and otherwise defaults to ad-hoc signing (`-`). |
| `TOKENBAR_APP_PATH` | Output path for the app bundle. |
| `TOKENBAR_BUNDLE_IDENTIFIER` | Override `CFBundleIdentifier` while packaging. |
| `TOKENBAR_BUNDLE_DISPLAY_NAME` | Override the displayed bundle name. |
| `TOKENBAR_RUST_TARGET_DIR` | Override the Cargo target directory used by the packaging script. |
| `TOKENBAR_HELPER_PATH` | Point development builds at an explicit helper executable. |

### Create a release

`Scripts/release_app.sh` builds the Swift app and Rust helper for both Apple silicon and Intel, merges each executable into a Universal 2 app, signs the complete bundle with an Apple [Developer ID Application certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and hardened runtime, submits it to Apple's [notary service](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), staples the ticket, removes AppleDouble/resource-fork metadata, validates the result with Gatekeeper, and creates a `ditto --norsrc` zip plus SHA-256 checksum.

Store notarization credentials in the macOS Keychain once:

```bash
xcrun notarytool store-credentials tokenbar-notary
```

Then create a formal release:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE="tokenbar-notary" \
  ./Scripts/release_app.sh
```

The script also accepts an App Store Connect API key file outside the repository; run `./Scripts/release_app.sh --help` for the exact contract. Apple-ID passwords must first be stored in a `notarytool` Keychain profile and are never accepted as build environment variables. The script removes all notarization variables from the build environment before invoking Swift or Cargo. A formal release fails unless a Developer ID Application identity and exactly one notarization authentication mode are configured.

For a local Universal 2 build without Apple submission:

```bash
BUILD_ONLY=1 ./Scripts/release_app.sh
```

Build-only output is ad-hoc signed and not notarized. It is useful for architecture and packaging checks, but is not a distributable release; Gatekeeper may require **Right-click → Open** on another Mac. Release artifacts are written under `dist/TokenBar-<version>/` (or `dist/TokenBar-<version>-build-only/`) unless `TOKENBAR_RELEASE_DIR` is set.

The release host needs both Rust macOS targets. Install a missing target with `rustup target add x86_64-apple-darwin` or `rustup target add aarch64-apple-darwin`.

After the formal script passes notarization and Gatekeeper validation, publish the zip and checksum as [GitHub Release](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) assets:

```bash
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
gh release create "v$VERSION" \
  "dist/TokenBar-$VERSION/TokenBar-$VERSION-macos-universal.zip" \
  "dist/TokenBar-$VERSION/TokenBar-$VERSION-macos-universal.zip.sha256" \
  --target main \
  --title "TokenBar $VERSION" \
  --generate-notes
```

TokenBar does not embed Sparkle yet, so GitHub Releases are the update channel for the initial version. Adding in-app updates later requires signing the embedded Sparkle framework and nested services, publishing an EdDSA-signed appcast, and validating upgrades from the previous public build.

## Project structure

```text
Sources/TokenBar/             AppKit/SwiftUI menu bar UI
Sources/TokenBarCore/         Models, quota client, caching, and presentation logic
Helper/                       Codex/Claude/Grok/Antigravity parsers and shared activity aggregator
Sync/                         Windows/Linux headless clients, Linux service, and protocol
Tests/TokenBarCoreTests/      Swift behavior and fixture tests
Resources/                    Bundle metadata and app icon assets
Scripts/package_app.sh        Build, embed, sign, and verify TokenBar.app
Scripts/release_app.sh        Build, notarize, and archive a Universal 2 release
Scripts/build_icon.sh         Regenerate AppIcon.icns from the 1024 px source
Scripts/generate_licenses.sh  Refresh the bundled Rust dependency licenses
```

Each platform's quota and the shared activity source maintain independent state. One provider's authentication failure does not erase another provider's last valid quota snapshot, and a quota failure does not hide local activity.

## Troubleshooting

### Quota is unavailable

Run `codex` in Terminal and confirm that it is installed and authenticated. TokenBar checks common package-manager locations and the login-shell path; set `CODEX_CLI_PATH` when using another location. TokenBar does not implement a separate login flow.

### The 5-hour quota row is missing

This is intentional when Codex returns no 5-hour window. Weekly quota can still remain available.

### No local activity appears

Confirm that the client has created JSONL files under `~/.codex/sessions`, `~/.codex/archived_sessions`, `~/.claude/projects`, or `~/.grok/sessions`, or conversation databases under `~/.gemini/antigravity/conversations`. If you use a custom home, launch TokenBar with the matching `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `GROK_HOME`, or `ANTIGRAVITY_HOME` environment.

### An extra reset count is missing

Extra resets are best-effort and require current OAuth credentials in the Codex home. A failure here does not hide the regular quota windows.

### A cost is absent

TokenBar leaves requests unpriced when neither the log nor its internal pricing data has a trustworthy rate for the model. The bundled Google Gemini rates are the paid-tier text prices Google lists as current through 2026-12-31; Google has scheduled increases for 2027-01-01, so that table needs a review then.

### A development build cannot find the helper

Run `cargo build --manifest-path Helper/Cargo.toml` before `swift run TokenBar`, or set `TOKENBAR_HELPER_PATH` to the helper executable.

### Another Mac says TokenBar cannot be opened

`Scripts/package_app.sh` creates a host-architecture, ad-hoc-signed development app. It is not intended for direct distribution. Use the Developer ID and notarization release flow above to produce a Universal 2 zip that opens normally on supported Apple silicon and Intel Macs. A build-only package can be opened manually with **Right-click → Open**, but it remains unnotarized and should not be published as a release.

## Acknowledgements

- [CodexBar](https://github.com/steipete/CodexBar) inspired TokenBar's focused native menu bar experience; its quota protocol and reset-celebration behavior informed TokenBar's standalone integration.
- [Tokscale](https://github.com/junhoyeo/tokscale) established many of the local Codex and Claude Code accounting, parsing, quota, and compatibility semantics used by TokenBar. Adapted portions are used under the MIT License; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- [Grok Build](https://github.com/xai-org/grok-build) publishes the durable session-update and usage contracts used by TokenBar's independent Grok adapter. The reference implementation is available under Apache-2.0.

TokenBar is a standalone implementation: none of these projects is a build-time or runtime dependency. Adapted MIT-licensed portions are retained in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Contributing

Issues and focused pull requests are welcome. Please keep changes scoped and include tests for parsing, accounting, quota normalization, caching, or menu presentation behavior when applicable.

Before opening a pull request, run:

```bash
swift test
cargo test --locked --manifest-path Helper/Cargo.toml
```

For visual changes, include a screenshot made with demo data.

## License

TokenBar is available under the [MIT License](LICENSE). Third-party attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
