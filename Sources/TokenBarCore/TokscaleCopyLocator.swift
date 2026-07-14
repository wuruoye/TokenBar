public extension SessionSummary {
    var tokscaleCopyText: String {
        "platform=codex session_id=\(self.id)"
    }
}

public extension RequestSummary {
    var tokscaleCopyText: String {
        "platform=codex session_id=\(self.physicalSessionId)"
            + " request_range=\(self.startedAtMs)..\(self.endedAtMs)"
    }
}
