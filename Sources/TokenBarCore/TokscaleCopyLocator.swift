public extension SessionSummary {
    var tokscaleCopyText: String {
        if let server = self.synchronizedDeviceID,
           let sessionID = self.synchronizedOriginalSessionID
        {
            return "provider=\(self.platformID.rawValue) server=\(server) session_id=\(sessionID)"
        }
        return "provider=\(self.platformID.rawValue) session_id=\(self.id)"
    }
}

public extension RequestSummary {
    var tokscaleCopyText: String {
        "platform=\(self.platformID.rawValue) session_id=\(self.physicalSessionId)"
            + " request_range=\(self.startedAtMs)..\(self.endedAtMs)"
    }
}
