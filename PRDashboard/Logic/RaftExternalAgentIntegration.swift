import AppKit
import Darwin
import Foundation
import Security
import SwiftUI

struct RaftExternalAgentConfiguration: Codable, Equatable {
    var enabled = false
    var serverURL = "https://app.raft.build"
    var profileSlug = ""
    var channel = ""
    var mentionAgentID = ""
    var mentionAgentHandle = ""

    var routeIdentity: String {
        [normalizedServerURL, profileSlug, channel, mentionAgentID, mentionAgentHandle]
            .joined(separator: "|")
    }

    var normalizedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var validationMessage: String? {
        guard enabled else { return nil }
        guard let components = URLComponents(string: normalizedServerURL),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty else {
            return "Enter an HTTPS Raft server origin, without a path."
        }
        guard profileSlug.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            return "Enter the local Raft CLI profile slug."
        }
        guard channel.hasPrefix("#"), channel.count > 1,
              channel.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return "Enter a channel target such as #backport-review."
        }
        guard UUID(uuidString: mentionAgentID) != nil else {
            return "Enter the mentioned Raft Agent's UUID."
        }
        let handle = Self.normalizedHandle(mentionAgentHandle)
        guard !handle.isEmpty,
              handle.range(of: "^[\\p{L}\\p{N}_-]+$", options: .regularExpression) != nil else {
            return "Enter the Agent handle, with or without the leading @."
        }
        return nil
    }

    static func normalizedHandle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    func mentionSelector() -> String {
        "agent:\(mentionAgentID):\(Self.normalizedHandle(mentionAgentHandle))"
    }
}

enum RaftExternalAgentError: LocalizedError {
    case invalidConfiguration(String)
    case missingCLI
    case commandTimedOut
    case commandFailed(Int32, String)
    case profileServerMismatch
    case profileIsNotExternalAgent
    case profileMissingCapabilities
    case invalidProfileResponse
    case invalidSendReceipt

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .missingCLI: return "Raft CLI was not found. Install @botiverse/raft and ensure `raft` is on PATH."
        case .commandTimedOut: return "Raft CLI did not finish within 30 seconds. Check Raft connectivity and profile status."
        case .commandFailed(let status, let detail):
            return detail.isEmpty ? "Raft CLI exited with status \(status)." : "Raft CLI failed: \(detail)"
        case .profileServerMismatch: return "The selected Raft CLI profile belongs to a different server."
        case .profileIsNotExternalAgent: return "The selected profile is not an External Agent profile."
        case .profileMissingCapabilities: return "The profile needs the send and mentions capabilities. Re-authorize the External Agent credential."
        case .invalidProfileResponse: return "Raft CLI returned an invalid profile identity response."
        case .invalidSendReceipt: return "Raft CLI did not return a confirmed message receipt."
        }
    }
}

private struct RaftCommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct RaftWhoAmIResponse: Decodable {
    struct Identity: Decodable {
        struct Agent: Decodable {
            let id: String
            let name: String
            let external: Bool
        }

        let agentId: String
        let serverUrl: String
        let serverConfirmed: Bool
        let capabilities: [String]
        let agent: Agent
    }

    let ok: Bool
    let data: Identity
}

private struct RaftSendReceipt: Decodable {
    let state: String
    let messageId: String
}

private final class RaftPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let limit: Int

    init(limit: Int = 1_000_000) { self.limit = limit }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            lock.lock()
            if storage.count < limit {
                storage.append(chunk.prefix(limit - storage.count))
            }
            lock.unlock()
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
private final class RaftInputWriteStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var failureMessage: String?

    func record(_ error: Error) {
        lock.lock()
        failureMessage = error.localizedDescription
        lock.unlock()
    }

    var message: String? {
        lock.lock()
        defer { lock.unlock() }
        return failureMessage
    }
}
private struct RaftVerifiedProfile: Sendable {
    let profileSlug: String
    let serverURL: String
    let agentID: String
    let agentName: String
}

private final class RaftCLIClient {
    private let fileManager = FileManager.default

    func verifyProfile(_ configuration: RaftExternalAgentConfiguration) async throws -> RaftVerifiedProfile {
        try validate(configuration)
        let result = try await run(
            arguments: ["--profile", configuration.profileSlug, "auth", "whoami"],
            standardInput: nil
        )
        guard result.status == 0 else { throw commandError(result) }
        guard let data = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(RaftWhoAmIResponse.self, from: data),
              response.ok, response.data.serverConfirmed else {
            throw RaftExternalAgentError.invalidProfileResponse
        }
        guard Self.sameOrigin(response.data.serverUrl, configuration.normalizedServerURL) else {
            throw RaftExternalAgentError.profileServerMismatch
        }
        guard response.data.agent.external else { throw RaftExternalAgentError.profileIsNotExternalAgent }
        guard response.data.capabilities.contains("send"), response.data.capabilities.contains("mentions") else {
            throw RaftExternalAgentError.profileMissingCapabilities
        }
        return RaftVerifiedProfile(
            profileSlug: configuration.profileSlug,
            serverURL: configuration.normalizedServerURL,
            agentID: response.data.agentId,
            agentName: response.data.agent.name
        )
    }

    func send(
        _ pr: PullRequest,
        configuration: RaftExternalAgentConfiguration,
        verifiedProfile: RaftVerifiedProfile
    ) async throws -> (messageID: String, partial: Bool) {
        guard verifiedProfile.profileSlug == configuration.profileSlug,
              Self.sameOrigin(verifiedProfile.serverURL, configuration.normalizedServerURL) else {
            throw RaftExternalAgentError.profileServerMismatch
        }
        let currentProfile = try await verifyProfile(configuration)
        guard currentProfile.agentID == verifiedProfile.agentID else {
            throw RaftExternalAgentError.profileServerMismatch
        }
        let handle = RaftExternalAgentConfiguration.normalizedHandle(configuration.mentionAgentHandle)
        let repository = pr.repoFullName
        let url = "https://github.com/\(repository)/pull/\(pr.number)"
        let content = "@\(handle) Please review this backport PR.\n\(repository)#\(pr.number): \(pr.title)\n\(url)\n"
        let result = try await run(
            arguments: [
                "--profile", configuration.profileSlug,
                "message", "send",
                "--target", configuration.channel,
                "--target-confirmed",
                "--mention", configuration.mentionSelector(),
                "--json"
            ],
            standardInput: Data(content.utf8)
        )
        guard result.status == 0 else { throw commandError(result) }
        guard let data = result.stdout.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(RaftSendReceipt.self, from: data),
              !receipt.messageId.isEmpty,
              receipt.state == "sent" || receipt.state == "partial" else {
            throw RaftExternalAgentError.invalidSendReceipt
        }
        return (receipt.messageId, receipt.state == "partial")
    }

    private func validate(_ configuration: RaftExternalAgentConfiguration) throws {
        if let message = configuration.validationMessage {
            throw RaftExternalAgentError.invalidConfiguration(message)
        }
    }

    private func run(arguments: [String], standardInput: Data?) async throws -> RaftCommandResult {
        guard let executable = resolveExecutable() else { throw RaftExternalAgentError.missingCLI }
        return try await Task.detached(priority: .userInitiated) {
            try Self.runSynchronously(executable: executable, arguments: arguments, standardInput: standardInput)
        }.value
    }

    private func resolveExecutable() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var directories = [
            "\(home)/.local/bin",
            "\(home)/.bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]
        directories.append(contentsOf: (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init))
        return directories
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("raft") }
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private static func runSynchronously(executable: URL, arguments: [String], standardInput: Data?) throws -> RaftCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathParts = ["\(home)/.local/bin", "\(home)/.bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (pathParts + (environment["PATH"] ?? "").split(separator: ":").map(String.init))
            .joined(separator: ":")
        environment.removeValue(forKey: "RAFT_PROFILE")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let inputPipe = standardInput == nil ? nil : Pipe()
        if let inputPipe {
            process.standardInput = inputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw RaftExternalAgentError.commandFailed(Int32((error as NSError).code), error.localizedDescription)
        }

        let stdoutCapture = RaftPipeCapture()
        let stderrCapture = RaftPipeCapture(limit: 8_000)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutCapture.drain(stdoutPipe.fileHandleForReading)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCapture.drain(stderrPipe.fileHandleForReading)
            readers.leave()
        }

        let inputWriter = DispatchGroup()
        let inputWriteStatus = RaftInputWriteStatus()
        if let standardInput, let inputPipe {
            let handle = inputPipe.fileHandleForWriting
            inputWriter.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    try? handle.close()
                    inputWriter.leave()
                }
                do {
                    try handle.write(contentsOf: standardInput)
                } catch {
                    inputWriteStatus.record(error)
                }
            }
        }

        if finished.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            inputWriter.wait()
            throw RaftExternalAgentError.commandTimedOut
        }
        inputWriter.wait()
        if let message = inputWriteStatus.message {
            throw RaftExternalAgentError.commandFailed(1, "Could not write message to Raft CLI stdin: \(message)")
        }
        readers.wait()
        return RaftCommandResult(
            status: process.terminationReason == .exit ? process.terminationStatus : 1,
            stdout: String(decoding: stdoutCapture.data, as: UTF8.self),
            stderr: String(decoding: stderrCapture.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func commandError(_ result: RaftCommandResult) -> RaftExternalAgentError {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        return .commandFailed(result.status, String(detail.prefix(600)))
    }

    private static func sameOrigin(_ first: String, _ second: String) -> Bool {
        guard let lhs = URLComponents(string: first), let rhs = URLComponents(string: second) else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
            && (lhs.path.isEmpty || lhs.path == "/")
            && (rhs.path.isEmpty || rhs.path == "/")
    }
}

@MainActor
final class RaftExternalAgentIntegration: ObservableObject {
    static let shared = RaftExternalAgentIntegration()

    @Published private(set) var configuration: RaftExternalAgentConfiguration
    @Published private(set) var status = ""
    @Published private(set) var isSending = false

    private let defaults: UserDefaults
    private let client = RaftCLIClient()
    private var ledger: [String: String]
    private static let configurationKey = "raft.externalAgent.configuration.v1"
    private static let ledgerKey = "raft.externalAgent.notifications.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: Self.configurationKey)
            .flatMap { try? JSONDecoder().decode(RaftExternalAgentConfiguration.self, from: $0) }
            ?? RaftExternalAgentConfiguration()
        ledger = defaults.dictionary(forKey: Self.ledgerKey) as? [String: String] ?? [:]
        Self.removeLegacyClockerState(defaults: defaults)
    }

    func save(_ value: RaftExternalAgentConfiguration) throws {
        if let message = value.validationMessage {
            throw RaftExternalAgentError.invalidConfiguration(message)
        }
        defaults.set(try JSONEncoder().encode(value), forKey: Self.configurationKey)
        configuration = value
        status = "Raft settings saved."
    }

    func verifyProfile() async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            let profile = try await client.verifyProfile(configuration)
            status = "Profile verified: @\(profile.agentName) on \(configuration.normalizedServerURL)."
        } catch {
            status = error.localizedDescription
        }
    }

    static func isBackport(_ pr: PullRequest) -> Bool {
        pr.state == .open && !pr.isDraft &&
            pr.title.lowercased().range(of: "^\\[backport(?:\\s|\\])", options: .regularExpression) != nil
    }

    func notify(_ pr: PullRequest) async {
        guard Self.isBackport(pr) else { return }
        guard configuration.enabled else {
            status = "Enable Raft Notifications in Settings first."
            return
        }
        guard !isSending else {
            status = "A Raft message is already being sent."
            return
        }
        let identity = "\(configuration.routeIdentity)|\(pr.repoFullName)#\(pr.number)"
        guard ledger[identity] == nil else {
            status = "Already attempted for \(pr.repoFullName) #\(pr.number). Check the channel before retrying."
            return
        }

        isSending = true
        defer { isSending = false }
        do {
            let verifiedProfile = try await client.verifyProfile(configuration)
            ledger[identity] = "attempted"
            defaults.set(ledger, forKey: Self.ledgerKey)
            let receipt = try await client.send(pr, configuration: configuration, verifiedProfile: verifiedProfile)
            ledger[identity] = receipt.partial ? "partial" : "sent"
            defaults.set(ledger, forKey: Self.ledgerKey)
            status = receipt.partial
                ? "Message \(receipt.messageID) was posted, but Raft reports unresolved mention delivery. Check the channel before retrying."
                : "Message \(receipt.messageID) sent to \(configuration.channel); Raft confirmed the send."
        } catch {
            status = "\(error.localizedDescription) If the result is uncertain, check the channel before retrying."
        }
    }

    private static func removeLegacyClockerState(defaults: UserDefaults) {
        ["clocker.configuration.v1", "clocker.notifications.v1", "clocker.verifiedRoute.v1"].forEach {
            defaults.removeObject(forKey: $0)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.xiaocang.PRDashboard.clocker",
            kSecAttrAccount as String: "trigger-key"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct RaftExternalAgentSettingsSection: View {
    @ObservedObject var integration: RaftExternalAgentIntegration
    @State private var draft = RaftExternalAgentConfiguration()
    @State private var localStatus = ""
    private typealias HelpHint = SettingsContent.HelpHint

    var body: some View {
        Section {
            HStack(spacing: 4) {
                Toggle("Enable Raft Notifications", isOn: $draft.enabled)
                    .accessibilityIdentifier("settings-raft-notifications-enabled")
                HelpHint("When enabled, a manual Notify Raft action posts the selected PR to the configured channel. ghpr-view never sends automatically after refresh.")
                Spacer()
            }
            if draft.enabled {
                settingsFields
                HStack {
                    Button("Save Raft Settings", action: save)
                        .disabled(!isDirty || validationMessage != nil)
                    Spacer()
                    Button("Verify Profile") { Task { await integration.verifyProfile() } }
                        .disabled(isDirty || validationMessage != nil || integration.isSending)
                }
            } else if isDirty {
                Button("Save Raft Settings", action: save)
                    .disabled(!isDirty)
            }
            if draft.enabled, let message = statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            HStack(spacing: 4) {
                Text("Raft External Agent")
                HelpHint(Self.helpText)
            }
        } footer: {
            if draft.enabled || isDirty {
                Text("Manual only: Notify Raft posts the PR details to the selected channel. No messages are sent automatically after refresh.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(integration.isSending)
        .onAppear { draft = integration.configuration }
    }

    static let helpText = "Requires the Raft CLI (@botiverse/raft) and a local External Agent profile with send and mentions capabilities. The profile stores its credential; ghpr-view invokes the CLI and never reads or stores the agent token. Verify Profile checks identity only and sends no message."

    private var settingsFields: some View {
        Group {
            settingField(
                "Raft Server URL",
                help: "Must exactly match the serverUrl that `raft --profile <slug> auth whoami` reports for the selected profile.",
                text: $draft.serverURL,
                prompt: "https://app.raft.build"
            )
            settingField(
                "External Agent Profile",
                help: "The local Raft CLI profile slug created by `raft agent login`. It selects the sender credential and is not the receiving Agent's UUID.",
                text: $draft.profileSlug,
                prompt: "e.g. ghpr-notify"
            )
            settingField(
                "Target Channel",
                help: "The channel to post into, such as #backport-review. The sending External Agent and the receiving Agent must both be channel members.",
                text: $draft.channel,
                prompt: "#backport-review"
            )
            settingField(
                "Mention Agent UUID",
                help: "The UUID of the Agent that should receive the mention. This is the recipient, not the sending External Agent.",
                text: $draft.mentionAgentID,
                prompt: "Recipient Agent UUID"
            )
            settingField(
                "Mention Agent Handle",
                help: "The exact handle belonging to the UUID above. Enter it with or without @; Raft uses both values to create a structured mention.",
                text: $draft.mentionAgentHandle,
                prompt: "@Cindy"
            )
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func settingField(
        _ title: String,
        help: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                HelpHint(help)
                Spacer()
            }
            TextField("", text: text, prompt: Text(prompt))
                .autocorrectionDisabled(true)
                .accessibilityLabel(title)
        }
    }

    private var isDirty: Bool { draft != integration.configuration }
    private var validationMessage: String? { draft.validationMessage }
    private var statusMessage: String? {
        if isDirty, let validationMessage { return validationMessage }
        return localStatus.isEmpty ? integration.status : localStatus
    }

    private func save() {
        do {
            try integration.save(draft)
            localStatus = ""
        } catch {
            localStatus = error.localizedDescription
        }
    }
}

