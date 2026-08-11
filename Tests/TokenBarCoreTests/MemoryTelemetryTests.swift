import Foundation
import Testing
@testable import TokenBarCore

@Suite("Codex memory telemetry")
struct MemoryTelemetryTests {
    @Test("decodes the helper memory usage contract")
    func decodesMemoryUsageContract() throws {
        let data = Data("""
        {
          "collectedFromMs": 1800000000000,
          "lastReceivedAtMs": 1800000001000,
          "lastMemoryReceivedAtMs": 1800000002000,
          "observationCount": 12,
          "today": {
            "phase1": {"total": 100, "input": 80, "cachedInput": 30, "cacheWriteInput": 2, "output": 20, "reasoningOutput": 5},
            "phase2": {"total": 50, "input": 40, "cachedInput": 10, "cacheWriteInput": 1, "output": 10, "reasoningOutput": 2}
          },
          "rangeTotals": {
            "phase1": {"total": 100, "input": 80, "cachedInput": 30, "cacheWriteInput": 2, "output": 20, "reasoningOutput": 5},
            "phase2": {"total": 50, "input": 40, "cachedInput": 10, "cacheWriteInput": 1, "output": 10, "reasoningOutput": 2}
          },
          "days": []
        }
        """.utf8)

        let usage = try JSONDecoder().decode(MemoryUsageSnapshot.self, from: data)

        #expect(usage.today.total == 150)
        #expect(usage.today.combined.cachedInput == 40)
        #expect(usage.today.phase1.cacheWriteInput == 2)
        #expect(usage.observationCount == 12)
        #expect(usage.lastMemoryReceivedAtMs == 1_800_000_002_000)
        #expect(usage.lastMemoryReceivedAt?.timeIntervalSince1970 == 1_800_000_002)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "lastMemoryReceivedAtMs")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyUsage = try JSONDecoder().decode(MemoryUsageSnapshot.self, from: legacyData)
        #expect(legacyUsage.lastMemoryReceivedAt == nil)
    }

    @Test("detects TokenBar, missing, disabled, and custom OTEL configurations")
    func detectsConfigurationStates() {
        #expect(CodexMemoryConfigurationService.inspect(content: "model = \"gpt-test\"\n") == .notConfigured)
        #expect(CodexMemoryConfigurationService.inspect(content: Self.tokenBarConfig(analytics: false)) == .needsAnalytics)
        #expect(CodexMemoryConfigurationService.inspect(content: Self.tokenBarConfig(analytics: true)) == .configured)
        #expect(CodexMemoryConfigurationService.inspect(content: """
        [otel]
        exporter = "none"
        trace_exporter = "none"
        metrics_exporter = { otlp-http = { endpoint = "https://collector.example/v1/metrics", protocol = "json" } }
        """) == .customOpenTelemetry)
    }

    @Test("one-click setup appends private metrics-only configuration and keeps a backup")
    func installsConfigurationAndBackup() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = "model = \"gpt-test\"\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        let service = CodexMemoryConfigurationService(configurationURL: configURL)

        try service.install()

        let updated = try String(contentsOf: configURL, encoding: .utf8)
        #expect(updated.contains("[analytics]\nenabled = true"))
        #expect(updated.contains("exporter = \"none\""))
        #expect(updated.contains("trace_exporter = \"none\""))
        #expect(updated.contains("log_user_prompt = false"))
        #expect(updated.contains(CodexMemoryConfigurationService.endpoint))
        #expect(updated.contains("protocol = \"json\""))
        #expect(service.inspect() == .configured)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("config.toml.tokenbar-backup-") }
        #expect(backups.count == 1)
        #expect(try String(
            contentsOf: directory.appendingPathComponent(backups[0]),
            encoding: .utf8) == original)
    }

    @Test("setup only enables analytics when the TokenBar OTEL block already exists")
    func enablesAnalyticsWithoutReplacingOtel() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = Self.tokenBarConfig(analytics: false)
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        let service = CodexMemoryConfigurationService(configurationURL: configURL)

        try service.install()

        let updated = try String(contentsOf: configURL, encoding: .utf8)
        #expect(updated.contains("enabled = true # explicit preference"))
        #expect(updated.components(separatedBy: "[otel]").count == 2)
        #expect(service.inspect() == .configured)
    }

    @Test("setup refuses to overwrite an existing custom OTEL section")
    func preservesCustomOtel() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = """
        [otel]
        exporter = { otlp-http = { endpoint = "https://logs.example/v1/logs", protocol = "json" } }
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        let service = CodexMemoryConfigurationService(configurationURL: configURL)

        #expect(throws: CodexMemoryConfigurationError.self) {
            try service.install()
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == original)
    }

    @Test("nested OTEL tables are treated as custom and never redefined")
    func preservesNestedOtelTables() throws {
        let content = """
        [otel.exporter."otlp-http"]
        endpoint = "https://logs.example/v1/logs"
        protocol = "json"
        """

        #expect(CodexMemoryConfigurationService.inspect(content: content) == .customOpenTelemetry)
    }

    private static func tokenBarConfig(analytics: Bool) -> String {
        """
        [analytics]
        enabled = \(analytics) # explicit preference

        [otel]
        exporter = "none"
        trace_exporter = "none"
        metrics_exporter = { otlp-http = { endpoint = "\(CodexMemoryConfigurationService.endpoint)", protocol = "json" } }
        """
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBarMemoryTelemetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
