import Foundation

/// The last prompt the user sent in a task and the reply that finished it.
struct DesktopUnreadTurn: Equatable, Sendable {
    var prompt: String?
    var reply: String?
    /// How long the turn ran, from its prompt to its final reply.
    var duration: TimeInterval?
}

/// Where the latest turn of a Claude session stands.
enum ClaudeTurnState: Equatable, Sendable {
    case running
    /// The turn is paused on a question or a plan the user has to answer.
    case waitingForUser
    case ended
}

/// Reads the last turn of a Codex or Claude task from the end of its transcript.
/// Unread tasks have finished, so each transcript is read once per size and
/// modification date. Confined to the unread watcher's queue.
final class DesktopUnreadTurnReader {
    private enum Entry {
        case prompt(String, at: Date?)
        /// Codex reports a turn's duration with its final reply.
        case reply(String, at: Date?, duration: TimeInterval?)
    }

    private struct CachedTurn {
        let size: UInt64
        let modifiedAt: Date
        let turn: DesktopUnreadTurn
    }

    private struct CachedTurnState {
        let size: UInt64
        let modifiedAt: Date
        let state: ClaudeTurnState
    }

    /// Long turns can write megabytes of tool output after their prompt.
    private static let maximumScannedBytes: UInt64 = 32 << 20
    /// The line sought is usually near the end, so the first chunk is small
    /// and each next one doubles up to the largest.
    private static let firstChunkSize: UInt64 = 16 << 10
    private static let chunkSize: UInt64 = 256 << 10
    private static let maximumTextLength = 280
    /// Claude tools that pause the turn until the user answers.
    private static let claudeUserInputTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    private var cache: [String: CachedTurn] = [:]
    private var turnStates: [String: CachedTurnState] = [:]
    private var claudeTranscripts: [String: URL] = [:]

    func codexTurn(rolloutURL: URL) -> DesktopUnreadTurn {
        let markers = ["UserMessage", "user_message", "task_complete", "AgentMessage", "agent_message"]
        return self.cachedTurn(at: rolloutURL, markers: markers) { object in
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any]
            else {
                return nil
            }
            let at = Self.timestamp(object)
            switch payload["type"] as? String {
            case "item_completed":
                guard let item = payload["item"] as? [String: Any] else { return nil }
                switch item["type"] as? String {
                case "UserMessage":
                    return Self.codexHumanText(Self.textBlocks(item["content"])).map { .prompt($0, at: at) }
                case "AgentMessage":
                    return Self.replySummary(Self.textBlocks(item["content"]))
                        .map { .reply($0, at: at, duration: nil) }
                default:
                    return nil
                }
            case "user_message":
                return Self.codexHumanText(payload["message"] as? String).map { .prompt($0, at: at) }
            case "task_complete":
                let duration = (payload["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
                return Self.replySummary(payload["last_agent_message"] as? String)
                    .map { .reply($0, at: at, duration: duration) }
            case "agent_message":
                return Self.replySummary(payload["message"] as? String)
                    .map { .reply($0, at: at, duration: nil) }
            default:
                return nil
            }
        }
    }

    func claudeTurn(
        cliSessionID: String,
        workspacePath: String?,
        projectsDirectory: URL) -> DesktopUnreadTurn
    {
        guard let transcript = self.claudeTranscriptURL(
            cliSessionID: cliSessionID,
            workspacePath: workspacePath,
            projectsDirectory: projectsDirectory)
        else {
            return DesktopUnreadTurn()
        }
        return self.cachedTurn(at: transcript, markers: ["\"type\":\"user\"", "\"type\":\"assistant\""]) { object in
            // Compacting the context writes its summary as a user entry.
            guard object["isSidechain"] as? Bool != true,
                  object["isMeta"] as? Bool != true,
                  object["isCompactSummary"] as? Bool != true,
                  let message = object["message"] as? [String: Any]
            else {
                return nil
            }
            let at = Self.timestamp(object)
            switch object["type"] as? String {
            case "user":
                let text = (message["content"] as? String) ?? Self.textBlocks(message["content"])
                return Self.claudeHumanText(text).map { .prompt($0, at: at) }
            case "assistant":
                let text = Self.textBlocks(message["content"]) ?? Self.claudeUserInput(message["content"])
                return Self.replySummary(text).map { .reply($0, at: at, duration: nil) }
            default:
                return nil
            }
        }
    }

    /// A finished Claude turn ends with an assistant message that stopped for a
    /// reason other than a tool call, or with the result of a tool that ends
    /// the turn. A call to a tool that asks the user waits for the answer.
    /// Other tool results, prompts, and a reply still streaming belong to a
    /// turn in progress. Read again only when the transcript's size or
    /// modification date changes.
    func claudeTurnState(transcript: URL, size: UInt64, modifiedAt: Date) -> ClaudeTurnState {
        if let cached = self.turnStates[transcript.path], cached.size == size, cached.modifiedAt == modifiedAt {
            return cached.state
        }
        let state = Self.claudeTurnState(transcript: transcript)
        self.turnStates[transcript.path] = CachedTurnState(size: size, modifiedAt: modifiedAt, state: state)
        return state
    }

    private static func claudeTurnState(transcript: URL) -> ClaudeTurnState {
        var state = ClaudeTurnState.ended
        Self.scanBackward(in: transcript, markers: ["\"type\":\"user\"", "\"type\":\"assistant\""].map { Data($0.utf8) }) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["isSidechain"] as? Bool != true,
                  object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any]
            else {
                return false
            }
            switch object["type"] as? String {
            case "assistant":
                switch message["stop_reason"] as? String {
                case nil:
                    state = .running
                case "tool_use":
                    state = Self.claudeUserInput(message["content"]) == nil ? .running : .waitingForUser
                default:
                    state = .ended
                }
                return true
            case "user":
                // A tool can end the turn with its result, without another reply.
                let meta = (object["mcpMeta"] as? [String: Any])?["_meta"] as? [String: Any]
                if meta?["claude/endTurn"] as? Bool == true {
                    state = .ended
                    return true
                }
                // Interruptions and local slash commands end or bypass a turn.
                if let text = (message["content"] as? String) ?? Self.textBlocks(message["content"]) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    state = trimmed.hasPrefix("[Request interrupted") || trimmed.hasPrefix("<") ? .ended : .running
                } else {
                    state = .running
                }
                return true
            default:
                return false
            }
        }
        return state
    }

    /// A Claude tool call by what it says it does, or else by the file,
    /// command, or search it works on.
    static func claudeToolActivity(_ block: [String: Any]) -> String? {
        guard let name = block["name"] as? String,
              name != "ToolSearch",
              let input = block["input"] as? [String: Any]
        else {
            return nil
        }
        if let description = (input["description"] as? String).flatMap(self.flattened) {
            return description
        }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
            return "\(name) \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        for key in ["command", "pattern", "query", "url"] {
            if let line = (input[key] as? String)?.split(separator: "\n").first.flatMap({ self.flattened(String($0)) }) {
                return "\(name) \(line)"
            }
        }
        return nil
    }

    /// Collapses whitespace so text fits the few lines a widget row has.
    static func flattened(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        guard line.count > self.maximumTextLength else { return line }
        return String(line.prefix(self.maximumTextLength - 1)) + "…"
    }

    // MARK: Turn text

    private static func timestamp(_ object: [String: Any]) -> Date? {
        (object["timestamp"] as? String).flatMap {
            try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
    }

    /// Codex labels text blocks `Text` in its own items and `text` in model
    /// messages.
    private static func textBlocks(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks
            .filter { ($0["type"] as? String)?.lowercased() == "text" }
            .compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// The questions or plan in a call to a Claude tool that asks the user.
    private static func claudeUserInput(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String,
                  self.claudeUserInputTools.contains(name)
            else {
                return nil
            }
            let input = block["input"] as? [String: Any]
            let questions = (input?["questions"] as? [[String: Any]] ?? []).compactMap { $0["question"] as? String }
            return questions.isEmpty ? input?["plan"] as? String ?? name : questions.joined(separator: "\n")
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Codex wraps attachments and selections around the request and sends
    /// replies to its own questions as XML.
    private static func codexHumanText(_ text: String?) -> String? {
        guard var text else { return nil }
        if let request = text.range(of: "## My request:") {
            text = String(text[request.upperBound...])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<"), !trimmed.hasPrefix("#") else { return nil }
        return self.flattened(trimmed)
    }

    /// Claude Code records slash commands, shell escapes, interruptions, and
    /// harness notices as user entries.
    private static func claudeHumanText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.hasPrefix("<"),
              !trimmed.hasPrefix("[Request interrupted")
        else {
            return nil
        }
        return self.flattened(trimmed)
    }

    /// Reduces a Markdown reply to its opening text: code blocks, table rules,
    /// and heading, list, quote, emphasis, and link markup are dropped.
    static func replySummary(_ markdown: String?) -> String? {
        guard let markdown else { return nil }
        var lines: [String] = []
        var length = 0
        var inCodeBlock = false
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCodeBlock.toggle()
                continue
            }
            guard !inCodeBlock, !line.isEmpty, !line.allSatisfy({ "|-:+ ".contains($0) }) else { continue }
            while let first = line.first, first == "#" || first == ">" {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let marker = line.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                line.removeSubrange(marker)
            }
            line = line.replacingOccurrences(of: "|", with: " ")
            lines.append(line)
            length += line.count
            if length > self.maximumTextLength { break }
        }
        var text = lines.joined(separator: " ")
        text = text.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression)
        for markup in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: markup, with: "")
        }
        return self.flattened(text)
    }

    // MARK: Transcripts

    /// Claude Code names each project directory after its working directory with
    /// every other character replaced by `-`, and shortens long names, so a
    /// missing guess falls back to searching every project.
    func claudeTranscriptURL(
        cliSessionID: String,
        workspacePath: String?,
        projectsDirectory: URL) -> URL?
    {
        let fileName = cliSessionID + ".jsonl"
        guard !cliSessionID.isEmpty, !cliSessionID.contains("/") else { return nil }
        if let known = self.claudeTranscripts[cliSessionID],
           FileManager.default.fileExists(atPath: known.path)
        {
            return known
        }
        var candidates: [URL] = []
        if let workspacePath {
            let projectName = String(workspacePath.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
            })
            candidates.append(projectsDirectory
                .appendingPathComponent(projectName, isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false))
        }
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        candidates += projects.map { $0.appendingPathComponent(fileName, isDirectory: false) }
        guard let transcript = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return nil
        }
        self.claudeTranscripts[cliSessionID] = transcript
        return transcript
    }

    private func cachedTurn(
        at url: URL,
        markers: [String],
        classify: ([String: Any]) -> Entry?) -> DesktopUnreadTurn
    {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return DesktopUnreadTurn()
        }
        if let cached = self.cache[url.path], cached.size == size, cached.modifiedAt == modifiedAt {
            return cached.turn
        }
        let turn = Self.lastTurn(in: url, markers: markers.map { Data($0.utf8) }) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return nil
            }
            return classify(object)
        }
        self.cache[url.path] = CachedTurn(size: size, modifiedAt: modifiedAt, turn: turn)
        return turn
    }

    /// The first reply found from the end is the one that finished the turn,
    /// and the first prompt found opened it.
    private static func lastTurn(
        in url: URL,
        markers: [Data],
        classify: (Data) -> Entry?) -> DesktopUnreadTurn
    {
        var turn = DesktopUnreadTurn()
        var repliedAt: Date?
        self.scanBackward(in: url, markers: markers) { line in
            switch classify(line) {
            case let .prompt(prompt, promptedAt):
                turn.prompt = prompt
                if turn.duration == nil, let promptedAt, let repliedAt, repliedAt > promptedAt {
                    turn.duration = repliedAt.timeIntervalSince(promptedAt)
                }
                return true
            case let .reply(reply, at, duration):
                if turn.reply == nil {
                    turn.reply = reply
                    turn.duration = duration
                    repliedAt = at
                }
                return false
            case nil:
                return false
            }
        }
        return turn
    }

    /// Visits JSONL lines from the end of the file until `visit` returns true.
    /// Lines without any marker are skipped before decoding.
    static func scanBackward(in url: URL, markers: [Data], visit: (Data) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard var end = try? handle.seekToEnd() else { return }
        var carry = Data()
        var scanned: UInt64 = 0
        var chunkSize = self.firstChunkSize
        while end > 0, scanned < self.maximumScannedBytes {
            let start = end > chunkSize ? end - chunkSize : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(end - start))
            else {
                return
            }
            var lines = (chunk + carry).split(separator: 0x0A, omittingEmptySubsequences: false)
            // The first piece may continue in the previous chunk.
            carry = start > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed()
                where !line.isEmpty && markers.contains(where: { line.range(of: $0) != nil })
            {
                if visit(Data(line)) {
                    return
                }
            }
            scanned += end - start
            end = start
            chunkSize = min(chunkSize * 2, self.chunkSize)
        }
    }
}
