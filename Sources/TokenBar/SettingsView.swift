import SwiftUI
import TokenBarCore

struct TokenBarSettingsView: View {
    @Bindable var settings: TokenBarSettings
    let memoryTelemetry: MemoryTelemetryController?
    let testResetAnimation: () -> Void

    init(
        settings: TokenBarSettings,
        memoryTelemetry: MemoryTelemetryController? = nil,
        testResetAnimation: @escaping () -> Void = {})
    {
        self.settings = settings
        self.memoryTelemetry = memoryTelemetry
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
        .frame(width: 440, height: self.memoryTelemetry == nil ? 620 : 760)
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
