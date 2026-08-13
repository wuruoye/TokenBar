import SwiftUI
import TokenBarCore

struct TokenBarSettingsView: View {
    @Bindable var settings: TokenBarSettings
    let memoryTelemetry: MemoryTelemetryController?
    let activitySync: ActivitySyncController?
    let syncNow: () -> Void
    let testResetAnimation: () -> Void

    init(
        settings: TokenBarSettings,
        memoryTelemetry: MemoryTelemetryController? = nil,
        activitySync: ActivitySyncController? = nil,
        syncNow: @escaping () -> Void = {},
        testResetAnimation: @escaping () -> Void = {})
    {
        self.settings = settings
        self.memoryTelemetry = memoryTelemetry
        self.activitySync = activitySync
        self.syncNow = syncNow
        self.testResetAnimation = testResetAnimation
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme color", selection: self.$settings.theme) {
                    ForEach(TokenBarTheme.allCases) { theme in
                        Label {
                            Text(theme.displayName)
                        } icon: {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 9, height: 9)
                        }
                        .tag(theme)
                    }
                }
            }

            Section("Platforms") {
                Toggle("Show Claude Code", isOn: self.$settings.showsClaude)
                Toggle("Show Grok Build", isOn: self.$settings.showsGrok)

                Text("Adds each provider's T/W section and dashboard tab. Changes take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activity") {
                Picker("Statistics timezone", selection: self.$settings.statisticsTimeZone) {
                    ForEach(TokenBarStatisticsTimeZone.allCases) { timeZone in
                        Text(timeZone.displayName).tag(timeZone)
                    }
                }

                Text("UTC aligns today and daily totals with the Codex usage dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Recent sessions", selection: self.$settings.recentSessionCount) {
                    ForEach(TokenBarRecentSessionCount.allCases) { count in
                        Text("\(count.rawValue)").tag(count)
                    }
                }

                Toggle(
                    "Show full request content on hover",
                    isOn: self.$settings.showsFullRequestContentOnHover)
            }

            if let activitySync = self.activitySync {
                Section("Multi-device sync") {
                    Toggle("Sync activity across devices", isOn: self.$settings.syncEnabled)

                    TextField(
                        "Server URL",
                        text: self.$settings.syncServerURL,
                        prompt: Text("https://sync.example.com"))

                    SecureField(
                        "Device access token",
                        text: Binding(
                            get: { activitySync.token },
                            set: { activitySync.token = $0 }))

                    TextField("Device name", text: self.$settings.syncDeviceName)

                    LabeledContent("Device ID") {
                        Text(self.settings.syncDeviceID)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(self.syncStatusColor(
                                self.syncDisplayPhase(activitySync.report)))
                            .frame(width: 7, height: 7)
                        Text(self.syncStatusTitle(activitySync.report))
                        Spacer()
                        Button("Sync Now") {
                            self.syncNow()
                        }
                        .disabled(
                            !self.settings.syncEnabled
                                || activitySync.report.phase == .syncing)
                    }

                    if self.settings.syncEnabled,
                       let message = activitySync.credentialMessage
                        ?? activitySync.configurationMessage
                        ?? activitySync.report.message,
                       !message.isEmpty
                    {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(
                                activitySync.report.phase == .success
                                    ? Color.secondary
                                    : Color.red)
                    }

                    Text("Uploads session names and IDs with token counts, models, and timing so synced sessions can be identified and copied. Prompt/output text, workspace details, absolute paths, and provider credentials are removed before transmission. Sync failures never replace local activity data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let memoryTelemetry = self.memoryTelemetry {
                Section("Codex Memory") {
                    LabeledContent("Receiver") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(memoryTelemetry.receiverState.isListening ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(memoryTelemetry.receiverState.title)
                        }
                    }

                    Text(memoryTelemetry.receiverState.detail ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Codex config") {
                        Text(memoryTelemetry.configurationState.title)
                    }

                    Text(memoryTelemetry.configurationState.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if memoryTelemetry.configurationState.canInstall {
                        Button(
                            memoryTelemetry.configurationState == .needsAnalytics
                                ? "Enable Codex Analytics"
                                : "Enable Memory Metrics")
                        {
                            memoryTelemetry.installConfiguration()
                        }
                    }

                    if let message = memoryTelemetry.configurationErrorMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Codex loads this setting when its local process starts. Restart Codex or ChatGPT once after enabling. Logs, traces, and prompt text stay disabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Picker("Refresh in background", selection: self.$settings.refreshInterval) {
                    ForEach(TokenBarRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
            }

            Section("Celebrations") {
                LabeledContent("Confetti when quota resets") {
                    HStack(spacing: 8) {
                        Picker("", selection: self.$settings.resetCelebration) {
                            ForEach(TokenBarResetCelebration.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .labelsHidden()

                        Button("Test Animation") {
                            self.testResetAnimation()
                        }
                    }
                }

                Text("Plays a click-through animation from the provider's menu bar section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    self.settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .frame(
            width: self.activitySync == nil ? 440 : 480,
            height: self.activitySync == nil
                ? (self.memoryTelemetry == nil ? 620 : 760)
                : 820)
    }

    private func syncStatusTitle(_ report: ActivitySyncReport) -> String {
        switch self.syncDisplayPhase(report) {
        case .disabled:
            "Disabled"
        case .ready:
            "Ready"
        case .syncing:
            "Syncing…"
        case .success:
            report.deviceCount == 1 ? "1 device synced" : "\(report.deviceCount) devices synced"
        case .partial:
            "Partial sync"
        case .failure:
            "Sync failed"
        }
    }

    private func syncDisplayPhase(_ report: ActivitySyncReport) -> ActivitySyncPhase {
        guard self.settings.syncEnabled else { return .disabled }
        return report.phase == .disabled ? .ready : report.phase
    }

    private func syncStatusColor(_ phase: ActivitySyncPhase) -> Color {
        switch phase {
        case .success: .green
        case .syncing: .blue
        case .partial, .failure: .orange
        case .disabled, .ready: .secondary
        }
    }
}

extension TokenBarTheme {
    var color: Color {
        switch self {
        case .system: .accentColor
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        }
    }
}
