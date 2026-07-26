import Foundation

struct BuildIntegrationEvent: Equatable, Sendable {
    enum State: String, Sendable {
        case running
        case completed
        case failed
    }

    let integration: BuildIntegrationKind
    let state: State
    let fingerprint: String
    let observedAt: Date
    let summary: String?
}

struct BuildIntegrationMonitor {
    private let fileManager = FileManager.default

    func grokEvents(fromOffset offset: UInt64) -> (events: [BuildIntegrationEvent], nextOffset: UInt64) {
        let url = grokEventURL
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else {
            return ([], 0)
        }
        defer { try? handle.close() }

        let start = offset <= size ? offset : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return ([], size)
        }

        let events = data.split(separator: 0x0A).compactMap { raw -> BuildIntegrationEvent? in
            guard let root = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] else {
                return nil
            }
            let hookName = ((root["hookEventName"] as? String) ?? "").lowercased()
            let reason = ((root["reason"] as? String) ?? "").lowercased()
            guard hookName == "stop_failure" || (hookName == "stop" && reason == "end_turn") else {
                return nil
            }
            let timestamp = parseDate(root["timestamp"] as? String) ?? Date()
            let sessionID = (root["sessionId"] as? String) ?? "unknown"
            let state: BuildIntegrationEvent.State = hookName == "stop_failure" ? .failed : .completed
            let summary = (root["lastAssistantMessage"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BuildIntegrationEvent(
                integration: .grokBuild,
                state: state,
                fingerprint: "\(sessionID)|\(hookName)|\(timestamp.timeIntervalSince1970)",
                observedAt: timestamp,
                summary: summary?.isEmpty == false ? summary : nil
            )
        }
        return (events, size)
    }

    func currentGrokEventOffset() -> UInt64 {
        (try? grokEventURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
    }

    func setGrokHookEnabled(_ enabled: Bool) throws {
        if enabled {
            try installGrokHook()
        } else if fileManager.fileExists(atPath: grokHookURL.path) {
            try fileManager.removeItem(at: grokHookURL)
        }
    }

    private var resetSupportURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Reset!", isDirectory: true)
    }

    private var grokEventURL: URL {
        resetSupportURL.appendingPathComponent("grok-build-events.jsonl")
    }

    private var grokHookURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/hooks/reset-build-notifications.json")
    }

    private var grokHookScriptURL: URL {
        resetSupportURL
            .appendingPathComponent("Integrations", isDirectory: true)
            .appendingPathComponent("grok-build-hook.sh")
    }

    private func installGrokHook() throws {
        let integrationsDirectory = grokHookScriptURL.deletingLastPathComponent()
        let hooksDirectory = grokHookURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: integrationsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)

        let eventPath = shellQuoted(grokEventURL.path)
        let script = """
        #!/bin/sh
        { /bin/cat; /usr/bin/printf '\\n'; } >> \(eventPath)
        """
        try Data(script.utf8).write(to: grokHookScriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grokHookScriptURL.path)

        let handler: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": shellQuoted(grokHookScriptURL.path),
                "timeout": 5
            ]]
        ]
        let document: [String: Any] = [
            "hooks": [
                "Stop": [handler],
                "StopFailure": [handler]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: grokHookURL, options: .atomic)
    }


    private func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
