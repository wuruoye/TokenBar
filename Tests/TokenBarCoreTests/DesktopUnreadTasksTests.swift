import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import TokenBarCore

struct DesktopUnreadTasksTests {
    @Test("Codex counts visible unread threads for the signed-in account")
    func codexUnreadThreads() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let claims = Data(#"{"https://api.openai.com/auth":{"chatgpt_user_id":"user-1"}}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        try Data(#"{"auth_mode":"chatgpt","tokens":{"id_token":"e30.\#(claims).sig","account_id":"account-1"}}"#.utf8)
            .write(to: codexHome.appendingPathComponent("auth.json"))
        let signedIn = SHA256.hash(data: Data(#"["chatgpt","account-1","user-1"]"#.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try Data("""
            {"electron-thread-read-state-v1":{"version":1,"unreadByIdentity":{
              "\(signedIn)":{"local:host":["root","subagent","archived","missing"]},
              "other-identity":{"local:host":["other-account"]}
            }}}
            """.utf8).write(to: codexHome.appendingPathComponent(".codex-global-state.json"))

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        try #require(sqlite3_open(codexHome.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK)
        try #require(sqlite3_exec(database, """
            CREATE TABLE threads (id TEXT PRIMARY KEY, source TEXT, archived INTEGER);
            INSERT INTO threads VALUES
              ('root', 'vscode', 0),
              ('subagent', '{"subagent":{"thread_spawn":{}}}', 0),
              ('archived', 'cli', 1),
              ('other-account', 'vscode', 0);
            """, nil, nil, nil) == SQLITE_OK)

        let reader = DesktopUnreadTaskReader(
            codexHome: codexHome,
            claudeSupportDirectory: root.appendingPathComponent("claude", isDirectory: true))
        #expect(reader.codexUnreadCount() == 1)
    }

    @Test("Claude reads the newest unread store entry")
    func claudeUnreadStore() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("claude", isDirectory: true)
        let storage = support.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let reader = DesktopUnreadTaskReader(
            codexHome: root.appendingPathComponent("codex", isDirectory: true),
            claudeSupportDirectory: support)
        let key = Array("_https://claude.ai".utf8) + [0, 1] + Array("epitaxy-unread-v1".utf8)

        try Data(LevelDBFixture.table(
            key: key,
            sequence: 5,
            value: [1] + Array(#"{"state":{"unreadIds":["local_a","local_b"],"explicitUnreadIds":["local_c"]},"version":0}"#.utf8)))
            .write(to: storage.appendingPathComponent("000005.ldb"))
        #expect(reader.claudeUnreadStore() == ["local_a", "local_b", "local_c"])

        try Data(LevelDBFixture.log(
            key: key,
            sequence: 9,
            value: [1] + Array(#"{"state":{"unreadIds":[],"explicitUnreadIds":["local_d"]},"version":0}"#.utf8)))
            .write(to: storage.appendingPathComponent("000006.log"))
        #expect(reader.claudeUnreadStore() == ["local_d"])
    }

    @Test("Claude session events change the count before the store commits")
    func claudeSessionEvents() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func session(
            turns: Int,
            shownAfter shown: TimeInterval,
            modifiedAfter modified: TimeInterval = 0,
            archived: Bool = false) -> ClaudeSessionSnapshot
        {
            ClaudeSessionSnapshot(
                completedTurns: turns,
                lastFocusedAt: Int64((start.timeIntervalSince1970 + shown) * 1000),
                isArchived: archived,
                modifiedAt: start.addingTimeInterval(modified))
        }
        var sessions = [
            "a": session(turns: 1, shownAfter: 0),
            "b": session(turns: 1, shownAfter: 1),
            "c": session(turns: 1, shownAfter: 2),
            "archived": session(turns: 1, shownAfter: 0, archived: true),
        ]
        var tracker = ClaudeUnreadTracker()
        #expect(tracker.update(store: ["a", "archived"], sessions: sessions, now: start.addingTimeInterval(3)) == 1)

        // b finishes while c is shown.
        sessions["b"] = session(turns: 2, shownAfter: 1, modifiedAfter: 10)
        #expect(tracker.update(store: ["a", "archived"], sessions: sessions, now: start.addingTimeInterval(11)) == 2)

        // Showing a reads it.
        sessions["a"] = session(turns: 1, shownAfter: 20, modifiedAfter: 20)
        #expect(tracker.update(store: ["a", "archived"], sessions: sessions, now: start.addingTimeInterval(21)) == 1)

        // The store catches up.
        #expect(tracker.update(store: ["b", "archived"], sessions: sessions, now: start.addingTimeInterval(40)) == 1)

        // c finishes while a is shown, and the guess expires without a store commit.
        sessions["c"] = session(turns: 2, shownAfter: 2, modifiedAfter: 50)
        #expect(tracker.update(store: ["b", "archived"], sessions: sessions, now: start.addingTimeInterval(51)) == 2)
        #expect(tracker.update(store: ["b", "archived"], sessions: sessions, now: start.addingTimeInterval(141)) == 1)
    }

    private static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBarUnreadTasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum LevelDBFixture {
    static func table(key: [UInt8], sequence: UInt64, value: [UInt8]) -> [UInt8] {
        let internalKey = key + self.littleEndian(sequence << 8 | 1, width: 8)
        let dataBlock = self.snappyLiteral(self.block(key: internalKey, value: value))
        var file = dataBlock + [1, 0, 0, 0, 0]
        let indexOffset = file.count
        let indexBlock = self.block(
            key: internalKey,
            value: self.varint(0) + self.varint(dataBlock.count))
        file += indexBlock + [0, 0, 0, 0, 0]
        var footer = self.varint(0)
        footer += self.varint(0)
        footer += self.varint(indexOffset)
        footer += self.varint(indexBlock.count)
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        return file + footer + self.littleEndian(0xDB47_7524_8B80_FB57, width: 8)
    }

    static func log(key: [UInt8], sequence: UInt64, value: [UInt8]) -> [UInt8] {
        var batch = self.littleEndian(sequence, width: 8)
        batch += self.littleEndian(1, width: 4)
        batch += [1]
        batch += self.varint(key.count)
        batch += key
        batch += self.varint(value.count)
        batch += value
        var record: [UInt8] = [0, 0, 0, 0]
        record += self.littleEndian(UInt64(batch.count), width: 2)
        record += [1]
        return record + batch
    }

    private static func block(key: [UInt8], value: [UInt8]) -> [UInt8] {
        var bytes = self.varint(0)
        bytes += self.varint(key.count)
        bytes += self.varint(value.count)
        bytes += key
        bytes += value
        bytes += self.littleEndian(0, width: 4)
        bytes += self.littleEndian(1, width: 4)
        return bytes
    }

    private static func snappyLiteral(_ bytes: [UInt8]) -> [UInt8] {
        // Literal tag 60 stores the length minus one in the following byte.
        precondition(bytes.count <= 256)
        return self.varint(bytes.count) + [60 << 2, UInt8(bytes.count - 1)] + bytes
    }

    private static func varint(_ value: Int) -> [UInt8] {
        var remaining = UInt64(value)
        var bytes: [UInt8] = []
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        return bytes + [UInt8(remaining)]
    }

    private static func littleEndian(_ value: UInt64, width: Int) -> [UInt8] {
        (0 ..< width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }
}
