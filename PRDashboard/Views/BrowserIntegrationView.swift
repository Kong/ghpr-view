import AppKit
import SwiftUI

struct BrowserIntegrationPresentation {
    var bridgeStatus: BrowserBridgeStatus
    var pairedClients: [BrowserClient]
    var unhealthySlots: [SlotHealthReport]
    var unhealthySurfaces: [SurfaceHealthReport]
    var isGitHubPageConnected: Bool
    var installUserscriptURL: URL?
    var browserTestURL: URL?
    var workbenchURL: URL?
    var agentInstallStatuses: [CodingAgentIntegrationInstallStatus]
    var agentInstallError: String?

    var officialUserscriptClient: BrowserClient? {
        pairedClients.first { $0.id == "dev.ghpr.official-userscript" && !$0.isRevoked }
    }

    var unhealthyPlacementCount: Int {
        unhealthySurfaces.count + unhealthySlots.count
    }
}

struct BrowserIntegrationActions {
    var openURL: (URL) -> Void
    var revoke: (BrowserClient) -> Void
    var installForAllAgents: () -> Void
}

struct BrowserIntegrationView: View {
    @ObservedObject var controller: ExtensionPlatformController
    @State private var agentInstallStatuses = BrowserIntegrationView.loadAgentStatuses()
    @State private var agentInstallError: String?

    var body: some View {
        BrowserIntegrationContent(
            presentation: Self.presentation(
                controller: controller,
                agentInstallStatuses: agentInstallStatuses,
                agentInstallError: agentInstallError
            ),
            actions: Self.actions(controller: controller, installForAllAgents: install)
        )
    }

    static func presentation(
        controller: ExtensionPlatformController,
        agentInstallStatuses: [CodingAgentIntegrationInstallStatus],
        agentInstallError: String?
    ) -> BrowserIntegrationPresentation {
        BrowserIntegrationPresentation(
            bridgeStatus: controller.bridgeStatus,
            pairedClients: controller.pairedClients,
            unhealthySlots: controller.unhealthySlots,
            unhealthySurfaces: controller.unhealthySurfaces,
            isGitHubPageConnected: controller.isGitHubPageConnected,
            installUserscriptURL: controller.installUserscriptURL(),
            browserTestURL: controller.server.baseURL?.appendingPathComponent("ui/browser-test"),
            workbenchURL: controller.server.baseURL?.appendingPathComponent("ui/workbench"),
            agentInstallStatuses: agentInstallStatuses,
            agentInstallError: agentInstallError
        )
    }

    static func actions(
        controller: ExtensionPlatformController,
        installForAllAgents: @escaping () -> Void
    ) -> BrowserIntegrationActions {
        BrowserIntegrationActions(
            openURL: { url in
                guard let destination = resolveBrowserURL(url, controller: controller) else { return }
                NSWorkspace.shared.open(destination)
            },
            revoke: { controller.revoke(client: $0) },
            installForAllAgents: installForAllAgents
        )
    }

    static func resolveBrowserURL(_ url: URL, controller: ExtensionPlatformController) -> URL? {
        guard let baseURL = controller.server.baseURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        let fragment = components.fragment
        components.fragment = nil
        let destination: URL?
        switch components.url {
        case baseURL.appendingPathComponent("ui/browser-test"):
            destination = controller.browserTestURL()
        case baseURL.appendingPathComponent("ui/workbench"):
            destination = controller.workbenchURL()
        default:
            return url
        }
        guard let destination,
              var resolved = URLComponents(url: destination, resolvingAgainstBaseURL: false) else {
            return nil
        }
        resolved.fragment = fragment
        return resolved.url
    }

    static func loadAgentStatuses() -> [CodingAgentIntegrationInstallStatus] {
        CodingAgentIntegrationInstaller.statuses(
            sourceMCPServerURL: CodingAgentIntegrationInstaller.bundledMCPServerURL()
        )
    }

    static func installAgents() throws -> [CodingAgentIntegrationInstallStatus] {
        guard let sourceSkillURL = Bundle.main.resourceURL?
            .appendingPathComponent("ghpr-skill-builder/SKILL.md"),
              FileManager.default.fileExists(atPath: sourceSkillURL.path),
              let sourceMCPServerURL = CodingAgentIntegrationInstaller.bundledMCPServerURL() else {
            throw NSError(
                domain: "CodingAgentIntegration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The bundled Coding Agent Integration is incomplete."]
            )
        }
        return try CodingAgentIntegrationInstaller.install(
            sourceSkillURL: sourceSkillURL,
            sourceMCPServerURL: sourceMCPServerURL,
            agents: [.claudeCode, .codex, .omp]
        )
    }

    private func install() {
        do {
            agentInstallStatuses = try Self.installAgents()
            agentInstallError = nil
        } catch {
            agentInstallError = error.localizedDescription
        }
    }
}

struct CodingAgentIntegrationSettingsView: View {
    @ObservedObject var controller: ExtensionPlatformController
    @State private var agentInstallStatuses = BrowserIntegrationView.loadAgentStatuses()
    @State private var agentInstallError: String?

    var body: some View {
        CodingAgentIntegrationContent(
            presentation: BrowserIntegrationView.presentation(
                controller: controller,
                agentInstallStatuses: agentInstallStatuses,
                agentInstallError: agentInstallError
            ),
            actions: BrowserIntegrationView.actions(controller: controller, installForAllAgents: install)
        )
    }

    private func install() {
        do {
            agentInstallStatuses = try BrowserIntegrationView.installAgents()
            agentInstallError = nil
        } catch {
            agentInstallError = error.localizedDescription
        }
    }
}

struct BrowserIntegrationContent: View {
    let presentation: BrowserIntegrationPresentation
    let actions: BrowserIntegrationActions
    @State private var showingDetails = false
    @State private var showingCodingAgentIntegration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: browserSummarySymbol)
                    .foregroundColor(browserSummaryColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(browserSummaryTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text(browserSummaryDetail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(bridgeStatusText)
                        .font(.caption2)
                        .foregroundColor(bridgeStatusColor)
                        .accessibilityIdentifier("browser-bridge-status")
                        .accessibilityValue(bridgeStatusText)
                    Text("\(activeClientCount) paired")
                        .accessibilityIdentifier("paired-client-count")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if presentation.officialUserscriptClient == nil {
                Label(
                    "Tip: Install the Tampermonkey userscript to add ghpr actions on GitHub.",
                    systemImage: "puzzlepiece.extension"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("userscript-reminder")
            }

            if presentation.unhealthyPlacementCount > 0 {
                Label(
                    "\(presentation.unhealthyPlacementCount) GitHub placement\(presentation.unhealthyPlacementCount == 1 ? "" : "s") need attention",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
                .accessibilityIdentifier("browser-slot-health-warning")
            }

            if presentation.officialUserscriptClient == nil {
                Button {
                    open(presentation.installUserscriptURL)
                } label: {
                    Label("Install Userscript in Browser", systemImage: "arrow.up.right.square")
                }
                .disabled(presentation.installUserscriptURL == nil)
                .accessibilityIdentifier("install-userscript")

                Text("Installation opens in your default browser.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            disclosureRow(
                title: "Connection details",
                identifier: "browser-integration-details-toggle",
                isExpanded: showingDetails
            ) {
                showingDetails.toggle()
            }

            if showingDetails {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow(
                        title: "Browser Bridge",
                        value: bridgeStatusText,
                        symbol: bridgeStatusSymbol,
                        color: bridgeStatusColor
                    )
                    statusRow(
                        title: "Official Userscript",
                        value: officialUserscriptText,
                        symbol: presentation.officialUserscriptClient == nil
                            ? "square.and.arrow.down"
                            : "checkmark.circle.fill",
                        color: presentation.officialUserscriptClient == nil ? .secondary : .green
                    )
                    statusRow(
                        title: "GitHub Page",
                        value: presentation.isGitHubPageConnected ? "Connected" : "Waiting for a GitHub tab",
                        symbol: presentation.isGitHubPageConnected ? "link.circle.fill" : "link.circle",
                        color: presentation.isGitHubPageConnected ? .green : .secondary
                    )
                    if !presentation.unhealthySurfaces.isEmpty || !presentation.unhealthySlots.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Surface health")
                                .font(.caption)
                                .fontWeight(.medium)
                            ForEach(presentation.unhealthySurfaces) { report in
                                Text("\(report.surface): \(report.state.rawValue.capitalized)")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                    .accessibilityIdentifier("surface-health-row-\(report.id)")
                            }
                            ForEach(presentation.unhealthySlots) { report in
                                Text("\(report.slot.rawValue): Missing")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                    .accessibilityIdentifier("slot-health-row-\(report.id)")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("surface-health-section")
                    }

                    Divider()

                    Text("Paired clients")
                        .font(.caption)
                        .fontWeight(.medium)

                    if presentation.pairedClients.isEmpty {
                        Text("No browser clients are paired.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 7) {
                            ForEach(presentation.pairedClients) { client in
                                clientRow(client)
                            }
                        }
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Button {
                            open(presentation.browserTestURL)
                        } label: {
                            Label("Open Browser Test", systemImage: "arrow.up.right.square")
                        }
                        .disabled(presentation.browserTestURL == nil)
                        .accessibilityIdentifier("open-browser-test")

                        if presentation.officialUserscriptClient != nil {
                            Button {
                                open(presentation.installUserscriptURL)
                            } label: {
                                Label("Reinstall Userscript", systemImage: "arrow.up.right.square")
                            }
                            .disabled(presentation.installUserscriptURL == nil)
                            .accessibilityIdentifier("install-userscript")
                        }
                    }
                }
                .padding(.top, 2)
            }

            Divider()

            disclosureRow(
                title: "Coding Agent Integration",
                identifier: "browser-integration-coding-agent-toggle",
                isExpanded: showingCodingAgentIntegration
            ) {
                showingCodingAgentIntegration.toggle()
            }

            if showingCodingAgentIntegration {
                CodingAgentIntegrationContent(presentation: presentation, actions: actions)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-integration-settings")
        .environment(\.openURL, OpenURLAction { url in
            actions.openURL(url)
            return .handled
        })
    }

    private func disclosureRow(
        title: LocalizedStringKey,
        identifier: String,
        isExpanded: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundColor(.secondary)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func clientRow(_ client: BrowserClient) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: client.isRevoked ? "xmark.shield" : "person.badge.shield.checkmark")
                .foregroundColor(client.isRevoked ? .secondary : .purple)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(client.name)
                        .font(.system(size: 12, weight: .medium))
                    Text("v\(client.version)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(scopeSummary(client.scopes))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if client.isRevoked {
                Text("Revoked")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Button("Revoke") {
                    actions.revoke(client)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .accessibilityIdentifier("revoke-\(client.id)")
            }
        }
        .padding(.vertical, 2)
    }

    private func statusRow(
        title: LocalizedStringKey,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .foregroundColor(color)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    private var activeClientCount: Int {
        presentation.pairedClients.lazy.filter { !$0.isRevoked }.count
    }

    private var browserSummaryTitle: String {
        switch presentation.bridgeStatus.state {
        case .failed:
            return "Needs attention"
        case .starting:
            return "Starting…"
        case .stopped:
            return "Browser integration unavailable"
        case .running:
            if presentation.officialUserscriptClient == nil {
                return "Finish browser setup"
            }
            if presentation.unhealthyPlacementCount > 0 {
                return "Needs attention"
            }
            return "Ready"
        }
    }

    private var browserSummaryDetail: String {
        switch presentation.bridgeStatus.state {
        case .failed:
            return "Open connection details to diagnose the Browser Bridge."
        case .starting:
            return "Starting the local Browser Bridge."
        case .stopped:
            return "The local Browser Bridge is not running."
        case .running:
            if presentation.officialUserscriptClient == nil {
                return "Install the userscript once to connect ghpr with GitHub."
            }
            if presentation.unhealthyPlacementCount > 0 {
                return "Some ghpr actions could not attach to GitHub."
            }
            return presentation.isGitHubPageConnected
                ? "A GitHub page is connected."
                : "Ready when you open a GitHub pull request."
        }
    }

    private var browserSummarySymbol: String {
        switch presentation.bridgeStatus.state {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .starting:
            return "clock.fill"
        case .stopped:
            return "bolt.slash.fill"
        case .running:
            if presentation.officialUserscriptClient == nil {
                return "puzzlepiece.extension"
            }
            if presentation.unhealthyPlacementCount > 0 {
                return "exclamationmark.triangle.fill"
            }
            return "checkmark.circle.fill"
        }
    }

    private var browserSummaryColor: Color {
        switch presentation.bridgeStatus.state {
        case .failed:
            return .red
        case .starting:
            return .orange
        case .stopped:
            return .secondary
        case .running:
            return presentation.officialUserscriptClient == nil || presentation.unhealthyPlacementCount > 0
                ? .orange
                : .green
        }
    }

    private var bridgeStatusText: String {
        switch presentation.bridgeStatus.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(let port): return "Running · \(port)"
        case .failed(let message): return message
        }
    }

    private var bridgeStatusSymbol: String {
        switch presentation.bridgeStatus.state {
        case .running: return "bolt.horizontal.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .starting: return "clock"
        case .stopped: return "bolt.slash"
        }
    }

    private var bridgeStatusColor: Color {
        switch presentation.bridgeStatus.state {
        case .running: return .green
        case .failed: return .red
        case .starting: return .orange
        case .stopped: return .secondary
        }
    }

    private var officialUserscriptText: String {
        guard let client = presentation.officialUserscriptClient else {
            return "Not paired"
        }
        return "Installed · v\(client.version)"
    }

    private func scopeSummary(_ scopes: Set<BrowserScope>) -> String {
        scopes
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        actions.openURL(url)
    }
}

struct CodingAgentIntegrationContent: View {
    let presentation: BrowserIntegrationPresentation
    let actions: BrowserIntegrationActions
    @State private var showingDetails = false


    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: integrationSummarySymbol)
                    .foregroundColor(integrationSummaryColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(integrationSummaryTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text("Install the Skill Builder and review-import MCP for Claude Code, Codex, and OMP.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("coding-agent-integration-status")

            if let errorMessage = presentation.agentInstallError {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("coding-agent-integration-install-error")
            }

            HStack(spacing: 8) {
                Button {
                    if let url = presentation.workbenchURL {
                        actions.openURL(url)
                    }
                } label: {
                    Label("Open Workbench in Browser", systemImage: "arrow.up.right.square")
                }
                .disabled(presentation.workbenchURL == nil)
                .accessibilityIdentifier("open-skill-workbench")

                if !allAgentsInstalled {
                    Button("Install for All Agents") {
                        actions.installForAllAgents()
                    }
                    .accessibilityIdentifier("install-coding-agent-integration")
                }
            }

            Text("Skill Workbench opens in your default browser.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Button {
                showingDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showingDetails ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("Installation details")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            .accessibilityIdentifier("coding-agent-integration-details-toggle")
            .accessibilityValue(showingDetails ? "Expanded" : "Collapsed")

            if showingDetails {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(presentation.agentInstallStatuses) { status in
                        HStack {
                            Text(status.agent.displayName)
                            Spacer()
                            Label(
                                status.installed ? "Installed" : "Not installed",
                                systemImage: status.installed ? "checkmark.circle.fill" : "circle"
                            )
                            .font(.caption)
                            .foregroundColor(status.installed ? .green : .secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        if allAgentsInstalled {
                            Button("Reinstall for All Agents") {
                                actions.installForAllAgents()
                            }
                            .accessibilityIdentifier("install-coding-agent-integration")
                        }

                        Button {
                            if let url = presentation.workbenchURL {
                                actions.openURL(url.appending(fragment: "contract"))
                            }
                        } label: {
                            Label("View Contract in Browser", systemImage: "arrow.up.right.square")
                        }
                        .disabled(presentation.workbenchURL == nil)
                    }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coding-agent-integration-settings")
        .environment(\.openURL, OpenURLAction { url in
            actions.openURL(url)
            return .handled
        })
    }

    private var installedAgentCount: Int {
        presentation.agentInstallStatuses.lazy.filter(\.installed).count
    }

    private var allAgentsInstalled: Bool {
        !presentation.agentInstallStatuses.isEmpty && installedAgentCount == presentation.agentInstallStatuses.count
    }

    private var integrationSummaryTitle: String {
        if allAgentsInstalled {
            return "Ready for all coding agents"
        }
        if installedAgentCount == 0 {
            return "Coding Agent Integration is not installed"
        }
        return "Installed for \(installedAgentCount) of \(presentation.agentInstallStatuses.count) agents"
    }

    private var integrationSummarySymbol: String {
        allAgentsInstalled ? "checkmark.circle.fill" : "terminal"
    }

    private var integrationSummaryColor: Color {
        allAgentsInstalled ? .green : .secondary
    }


}


struct BrowserPairingApprovalView: View {
    @ObservedObject var controller: ExtensionPlatformController
    let approval: PendingPairingApproval
    let dismiss: () -> Void

    @State private var selectedScopes: Set<BrowserScope>
    @State private var errorMessage: String?

    init(
        controller: ExtensionPlatformController,
        approval: PendingPairingApproval,
        dismiss: @escaping () -> Void
    ) {
        self.controller = controller
        self.approval = approval
        self.dismiss = dismiss
        let requested = approval.descriptor.requestedScopes
        let existing = controller.pairedClients.first { $0.id == approval.descriptor.id }?.scopes ?? []
        _selectedScopes = State(
            initialValue: requested.filter { $0.risk == .standard || existing.contains($0) }
        )
    }

    private var missingRequiredScopes: Set<BrowserScope> {
        approval.descriptor.requiredScopes.subtracting(selectedScopes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.system(size: 28))
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect “\(approval.descriptor.name)” to ghpr?")
                        .font(.headline)
                        .accessibilityIdentifier("pairing-client-name")
                    Text("Version \(approval.descriptor.version) · \(approval.descriptor.id)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text("Requested permissions")
                .font(.subheadline.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(
                        approval.descriptor.requestedScopes.sorted { $0.rawValue < $1.rawValue }
                    ) { scope in
                        VStack(alignment: .leading, spacing: 1) {
                            Toggle(isOn: binding(for: scope)) {
                                HStack(spacing: 7) {
                                    Image(
                                        systemName: scope.risk == .elevated
                                            ? "exclamationmark.triangle.fill"
                                            : "checkmark.shield.fill"
                                    )
                                    .foregroundColor(scope.risk == .elevated ? .orange : .green)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(scope.displayName)
                                            .accessibilityIdentifier("pairing-scope-name-\(scope.rawValue)")
                                        Text(scope.rawValue)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("pairing-scope-\(scope.rawValue)")

                            if approval.descriptor.requiredScopes.contains(scope) {
                                Text("Required for this action")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.orange)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                }
            }

            if !missingRequiredScopes.isEmpty {
                Text("Select \(missingRequiredScopes.map(\.displayName).joined(separator: ", ")) to continue.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Deny", role: .cancel) {
                    do {
                        try controller.denyPairing(approval)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Allow") {
                    do {
                        try controller.approvePairing(approval, scopes: selectedScopes)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!missingRequiredScopes.isEmpty)
                .keyboardShortcut(.return)
                .accessibilityIdentifier("allow-pairing")
            }
        }
        .padding(22)
        .frame(width: 460, height: 430)
    }

    private func binding(for scope: BrowserScope) -> Binding<Bool> {
        Binding(
            get: { selectedScopes.contains(scope) },
            set: { selected in
                if selected {
                    selectedScopes.insert(scope)
                } else {
                    selectedScopes.remove(scope)
                }
            }
        )
    }
}

private extension URL {
    func appending(fragment: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url ?? self
    }
}
