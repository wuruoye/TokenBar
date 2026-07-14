import SwiftUI
import TokenBarCore

struct TokenBarSettingsView: View {
    @Bindable var settings: TokenBarSettings

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

            Section("Activity") {
                Picker("Recent sessions", selection: self.$settings.recentSessionCount) {
                    ForEach(TokenBarRecentSessionCount.allCases) { count in
                        Text("\(count.rawValue)").tag(count)
                    }
                }

                Toggle(
                    "Show full request content on hover",
                    isOn: self.$settings.showsFullRequestContentOnHover)
            }

            Section("Updates") {
                Picker("Refresh in background", selection: self.$settings.refreshInterval) {
                    ForEach(TokenBarRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    self.settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 390)
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
