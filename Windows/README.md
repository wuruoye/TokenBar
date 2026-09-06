# TokenBar for Windows

Windows 10/11 x64 taskbar and tray client built with Tauri 2, TypeScript and the existing Rust activity helper. Requires Microsoft Edge WebView2 Runtime. The installer can install the runtime when needed.

## Build and launch

Requirements: Node.js 22.12+ or 24+, Rust's x86_64-pc-windows-msvc toolchain, and Visual C++ Build Tools with the Windows SDK.

Run from the repository root:

~~~powershell
.\Windows\scripts\Build-TokenBar.ps1
.\Windows\scripts\Start-TokenBar.ps1
~~~

The build runs frontend and backend tests, produces the app at Windows/src-tauri/target/release/tokenbar-windows.exe, and creates a per-user installer under Windows/src-tauri/target/release/bundle/nsis. Complete build logs are written to .logs/. The -NoInstaller flag builds a runnable app without an installer. The -SkipTests flag skips tests.

For development, build the helper once with the build script, then run npm run desktop from Windows/.

## Behavior

- The primary taskbar contains native provider buttons using the clear two-line text style of taskbar monitors. Each transparent column names its platform and Today tokens (K/M/B) on the first line, with weekly quota remaining below. All visible providers are shown by default; Settings can choose one provider, another free position, or disable the taskbar display.
- Click a taskbar provider to open the matching tab beside that region. Clicking the same provider again closes the panel; clicking another provider switches tabs. The tray icon also toggles the panel. Closing the panel or clicking outside it hides it. Pin the panel to keep it visible.
- Right-click for Open, Refresh, Settings and Quit. Ctrl+R refreshes, Ctrl+, opens Settings, and Escape returns to the dashboard or hides it.
- The compact 384-DIP panel follows the macOS section order: Quota (weekly pacing, 5-hour, extra resets), Today, Since weekly reset, Activity, and Recent Sessions. Quota labels show remaining percentages. Today groups cache writes into Input and uses the same Input/Output/Cache/Reasoning breakdown. The weekly seven-segment bar shows used quota and the expected pace; the 5-hour bar shows remaining quota.
- UTC Today totals, 7/30-day activity and today's local sessions remain separate per provider. Remote sessions reflect each device's latest snapshot. Missing quota windows remain absent; failed refreshes retain the last result with an error.
- Expand sessions, turns and physical requests to inspect local details. Locators preserve each physical request's own identity.
- Session rows and request details pair each model with its recorded reasoning effort. Codex effort follows each turn's context; multiple model/effort combinations are listed together and missing values remain marked as unrecorded.
- Codex links open its desktop task; Claude opens its local-session list. Grok sessions expose copyable IDs for CLI resume.
- Data roots default to CODEX_HOME, CLAUDE_CONFIG_DIR and GROK_HOME, then the Windows user profile. Settings can specify directories and a native codex.exe. WSL requires explicitly accessible data directories and a Windows CLI for live Codex quota.
- Settings and quota cache live in %LOCALAPPDATA%/com.wuruoye.tokenbar.windows. Local snapshots, local titles and local request content remain in memory; complete request text is loaded only when requested.
- Login startup is opt-in. It starts in the tray without opening the panel.
- Closing or unexpectedly destroying the panel keeps the tray process running. A destroyed panel is rebuilt in the background; choosing Quit still exits normally. Local lifecycle logs at `%LOCALAPPDATA%/com.wuruoye.tokenbar.windows/logs/runtime.log` record launches, exit reasons, panics, refresh health, and taskbar availability without session contents or credentials. Logs rotate at 1 MiB with one backup.

The native taskbar host combines Windows accessibility bounds with native child-window enumeration. It reserves complete regions for custom tools such as TrafficMonitor even when they expose no accessibility buttons, and never overlaps or resizes them. A per-pixel alpha popup surface parented into the taskbar keeps text visible above Windows 11's DirectComposition bridge while preserving the taskbar background. Text uses regular 9-point Microsoft YaHei and full rectangular click targets. The host follows taskbar visibility and DPI changes and recreates its own surface after Explorer changes. Layout queries run on a separate MTA thread that owns no windows. If no safe gap is available, the tray remains usable and Settings reports the reason. Display readiness requires a successful composited-frame update.

## Pricing

The shared Helper automatically refreshes the public OpenRouter model-price list once a day, with one-hour retry backoff and an offline official-rate fallback. GPT-6 Astra includes short/long-context rates and the separate ChatGPT-credit/API Fast multipliers. The dashboard shows price-catalog source and update time; values are estimates using current quotes. See the repository README for cache paths and offline flags.

## Multi-device sync

Enable sync in Settings and supply the HTTPS sync-server origin, device name and device token. The Rust client reuses tokenbar-sync validation and redaction, uploads fresh local statistics using protocol v2, and queries changed remote partitions and deletions. It falls back to v1 when v2 is unavailable, retries stale upload revisions in full, and recalibrates invalid download deltas. Upload and download failures are reported independently; failed downloads retain the previous remote records.

The access token and endpoint-scoped remote cache use DPAPI CurrentUser encryption. Upload state contains hashes and revisions, without a local snapshot body. Cached remote records are sanitized and integrity-checked before use and restored after restarting the app. Credential or endpoint changes invalidate the old cache. The access token is never returned to the frontend; prompt/output text and local paths are excluded from sync traffic and the remote cache.

By default the panel and taskbar show combined usage, with a persistent selector for this device or all devices. Merging follows the macOS rules: use the latest snapshot per device, match the current statistics date and timezone, include only the local date range, preserve model/provider attribution and weighted throughput, and add weekly totals only for matching reset boundaries. It rebuilds totals from local and remote snapshots on every update, so repeated downloads do not increase counts. Remote sessions retain their device name and session identity and remain read-only. Only the unmerged local snapshot is ever uploaded.

Use one uploader identity per Windows installation. When migrating from the headless TokenBarSync scheduled task, disable that task before enabling the UI uploader so the same machine is not counted twice.

## Codex Memory

The opt-in receiver uses the existing Rust OTLP/HTTP JSON receiver on 127.0.0.1:4318 and its parent-process lifetime guard. Configure Codex's metrics exporter separately; enabling the receiver does not edit Codex configuration. The database lives next to settings. The panel reports local Phase 1/Phase 2 totals and observation count; it does not invent historical measurements or costs.

## Verification

~~~powershell
cd Windows
npm ci
npm run build
npm test
cargo test --manifest-path src-tauri/Cargo.toml --locked
~~~

The Windows client has its own packaging script; Scripts/package_app.sh builds the macOS app and requires macOS/Swift/AppKit.

The opt-in native integration test uses a debug build with the ui-test feature and a loopback WebView2 debugging port. It sends BM_CLICK to the application's real Win32 buttons and checks actual paint completion, hit testing, no overlap with existing taskbar tools, unchanged foreign-window positions/sizes, panel visibility, screen bounds, provider selection, and disable/recreate behavior. Settings are restored afterward. The test command is omitted from ordinary builds.

~~~powershell
npm run tauri -- build --debug --no-bundle --features ui-test
# Launch target/debug/tokenbar-windows.exe with WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9237
node tests/taskbar.native.mjs
~~~

After stopping the normal TokenBar instance, run `node tests/lifecycle.native.mjs` against that same `ui-test` build to verify panel destruction/recreation, resident process and tray/taskbar retention, second-launch activation, and explicit Quit. The test launches and closes its own TokenBar process and leaves settings unchanged.

Read-only native taskbar geometry diagnostics:

~~~powershell
cargo run --manifest-path src-tauri/Cargo.toml --example taskbar_layout --quiet
~~~
