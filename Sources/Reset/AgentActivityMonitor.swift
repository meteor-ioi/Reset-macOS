import AppKit
import Foundation

@MainActor
struct AgentActivityMonitor {
    func activity(for provider: ProviderKind, now: Date = Date()) async -> AgentActivity {
        let desktopApp = NSWorkspace.shared.runningApplications.first { app in
            guard let identifier = app.bundleIdentifier else { return false }
            return provider.desktopBundleIdentifiers.contains(identifier)
        }

        // Modern ChatGPT is the Codex host (Classic is excluded by bundle ID),
        // but merely opening it is not the same as an active Agent turn. Session
        // records distinguish execution/waiting/completion from an opened app.
        if provider == .chatGPT, let session = CodexSessionActivityReader().latestActivity(now: now) {
            return AgentActivity(
                state: session.state,
                processID: desktopApp?.processIdentifier,
                command: session.threadName,
                observedAt: session.updatedAt
            )
        }

        let output = await command("/bin/ps", ["-axo", "pid=,command="])
        let process = output
            .split(whereSeparator: \.isNewline)
            .compactMap(parseProcess)
            .first { process in
                matchesFallbackProcess(process.command, for: provider)
            }

        if let desktopApp {
            return AgentActivity(state: .opened, processID: desktopApp.processIdentifier, command: desktopApp.localizedName, observedAt: now)
        }
        if let process {
            // A CLI process has no durable turn event available. It is useful
            // fallback evidence, but should never be mistaken for a desktop task.
            return AgentActivity(state: .running, processID: process.pid, command: process.command, observedAt: now)
        }
        return AgentActivity(state: .unavailable, processID: nil, command: nil, observedAt: now)
    }

    private func parseProcess(_ line: Substring) -> (pid: Int32, command: String)? {
        let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
        return (pid, String(parts[1]))
    }

    private func matchesFallbackProcess(_ command: String, for provider: ProviderKind) -> Bool {
        let lowercased = command.lowercased()
        if provider == .chatGPT {
            // ChatGPT Classic can carry similarly named helper processes. Only a
            // standalone Codex CLI is valid fallback evidence; desktop evidence
            // must come from the modern com.openai.codex bundle above.
            return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/.local/bin/codex"].contains {
                lowercased.contains($0)
            }
        }
        return provider.activityProcessMarkers.contains { lowercased.contains($0) }
    }

    private func command(_ executable: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }
}

private struct CodexSessionActivity {
    let state: AgentActivityState
    let updatedAt: Date
    let threadName: String?
}

private struct CodexSessionActivityReader {
    private let sessionsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    private let indexURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")
    private let maximumTailBytes = 524_288

    func latestActivity(now: Date) -> CodexSessionActivity? {
        guard let index = loadIndex().max(by: { $0.updatedAt < $1.updatedAt }),
              let file = sessionFile(id: index.id),
              let content = tail(of: file) else { return nil }

        let fileDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let activityDate = max(index.updatedAt, fileDate ?? .distantPast)
        guard now.timeIntervalSince(activityDate) < 30 * 60 else { return nil }

        let state = state(in: content)
        return CodexSessionActivity(state: state, updatedAt: activityDate, threadName: index.threadName)
    }

    private func loadIndex() -> [CodexSessionIndexRecord] {
        guard let contents = try? String(contentsOf: indexURL, encoding: .utf8) else { return [] }
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            try? JSONDecoder().decode(CodexSessionIndexRecord.self, from: Data(line.utf8))
        }
    }

    private func sessionFile(id: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: sessionsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.contains(id)
        }
    }

    private func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let readSize = min(size, UInt64(maximumTailBytes))
        try? handle.seek(toOffset: size - readSize)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func state(in content: String) -> AgentActivityState {
        var result: AgentActivityState = .opened
        for line in content.split(whereSeparator: \.isNewline) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = (root["type"] as? String ?? "").lowercased()
            let payload = root["payload"] as? [String: Any]
            let payloadType = (payload?["type"] as? String ?? "").lowercased()
            let payloadStatus = (payload?["status"] as? String ?? "").lowercased()
            let goalStatus = ((payload?["goal"] as? [String: Any])?["status"] as? String ?? "").lowercased()

            if type == "task_complete" || payloadType == "task_complete" || ["complete", "completed", "succeeded", "success"].contains(goalStatus) {
                result = .completed
            } else if ["blocked", "failed"].contains(goalStatus) || ["turn_aborted", "task_failed", "error", "failed"].contains(payloadType) {
                result = .failed
            } else if ["approval_request", "authorization_request", "confirmation_request", "needs_review", "permission_request", "requires_action", "user_input_requested", "waiting_for_approval", "waiting_for_authorization", "waiting_for_user", "waiting_for_user_input"].contains(payloadType)
                        || ["approval_required", "awaiting_user", "needs_review", "pending_approval", "requires_action", "requires_approval", "waiting_for_approval", "waiting_for_user"].contains(payloadStatus) {
                result = .waiting
            } else if type == "turn_context" || payloadType == "task_started" || payloadType == "user_message" || (type == "response_item" && ["custom_tool_call", "custom_tool_call_output", "function_call", "function_call_output", "image_generation_call", "message", "reasoning", "tool_search_call", "tool_search_output", "web_search_call"].contains(payloadType)) {
                result = .running
            }
        }
        return result
    }
}

private struct CodexSessionIndexRecord: Decodable {
    let id: String
    let threadName: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey { case id; case threadName = "thread_name"; case updatedAt = "updated_at" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadName = try container.decode(String.self, forKey: .threadName)
        let raw = try container.decode(String.self, forKey: .updatedAt)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let parsed = fractional.date(from: raw) ?? plain.date(from: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .updatedAt, in: container, debugDescription: "Invalid session timestamp")
        }
        updatedAt = parsed
    }
}
