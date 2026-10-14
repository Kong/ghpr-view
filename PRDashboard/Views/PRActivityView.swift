import SwiftUI
import AppKit

/// Native "待处理" surface: what needs the user's attention, why, with the evidence
/// link and the manual action. Deliberately compact: action items are grouped per PR
/// instead of one card per event.
struct PRActivityView: View {
    @ObservedObject var viewModel: PRListViewModel
    @ObservedObject private var monitor: PRActivityMonitor
    @State private var showsIncompleteSources = false

    init(viewModel: PRListViewModel) {
        self.viewModel = viewModel
        self.monitor = viewModel.activityMonitorForView
    }

    private var snapshot: PRActivitySnapshot { viewModel.activity }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = snapshot.errorMessage {
                        banner(error, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    coverageSection
                    actionSection
                    trackedSection
                    if !snapshot.batches.isEmpty {
                        digestSection
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Activity")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.refreshActivity()
                } label: {
                    Label("Observe now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Run one activity observation pass now")
            }
            if let account = snapshot.account {
                Text("\(account.displayName) · \(snapshot.monitoredPRs.count) monitored PR(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var statusText: String {
        if snapshot.isPaused { return String(localized: "paused") }
        guard snapshot.isRunning else { return String(localized: "not running") }
        if snapshot.isEstablishingBaseline { return String(localized: "establishing baseline") }
        guard let lastPass = snapshot.lastPassAt else { return String(localized: "starting") }
        return String(localized: "last observation \(lastPass.formatted(date: .omitted, time: .shortened))")
    }

    // MARK: - Coverage

    @ViewBuilder
    private var coverageSection: some View {
        if let coverage = snapshot.coverage, !coverage.isComplete {
            banner(
                String(localized: "Discovery is incomplete (\(coverage.incompleteOrigins.map(originLabel).joined(separator: ", "))); some PRs may be missing until the next pass."),
                symbol: "magnifyingglass.circle",
                tint: .yellow
            )
        }
        if !incompleteSourceGroups.isEmpty {
            incompleteSourcesBanner
        }
    }

    private var incompleteSourcesBanner: some View {
        let groups = incompleteSourceGroups
        let count = groups.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                showsIncompleteSources.toggle()
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.yellow)
                    Image(systemName: showsIncompleteSources ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(incompleteSummary(groups, count: count))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity-incomplete-sources")
            .accessibilityValue(showsIncompleteSources ? "Expanded" : "Collapsed")

            if showsIncompleteSources {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(group.count) \(group.label)")
                            .font(.caption.weight(.medium))
                        ForEach(group.details, id: \.self) { detail in
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(group.prs.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12))
        .cornerRadius(6)
    }

    private func incompleteSummary(_ groups: [IncompleteObservationGroup], count: Int) -> String {
        let parts = groups.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
        return String(localized: "Not fully observed (\(count)): \(parts). Checkpoints were kept unchanged.")
    }

    private var incompleteSourceGroups: [IncompleteObservationGroup] {
        var order: [String] = []
        var grouped: [String: (prs: [String], details: [String])] = [:]
        for pr in snapshot.monitoredPRs {
            for source in MonitorSourceKind.allCases {
                guard let reason = pr.unhealthyReason(for: source) else { continue }
                let label = "\(PRActivityDigestFormatter.sourceLabel(source)) (\(reason.warningQualifier))"
                if grouped[label] == nil {
                    order.append(label)
                    grouped[label] = ([], [])
                }
                grouped[label]?.prs.append("\(pr.reference.repoFullName)#\(pr.reference.number)")
                if let detail = reason.warningDetail, !detail.isEmpty, grouped[label]?.details.contains(detail) == false {
                    grouped[label]?.details.append(detail)
                }
            }
        }
        return order.compactMap { label in
            guard let group = grouped[label] else { return nil }
            return IncompleteObservationGroup(label: label, prs: group.prs, details: group.details)
        }
    }

    private struct IncompleteObservationGroup: Identifiable {
        let label: String
        let prs: [String]
        let details: [String]
        var id: String { label }
        var count: Int { prs.count }
    }

    private func originLabel(_ origin: MonitorOrigin) -> String {
        switch origin {
        case .authored: return String(localized: "authored")
        case .requested: return String(localized: "review requested")
        case .reviewed: return String(localized: "reviewed by you")
        case .commented: return String(localized: "you commented")
        case .explicit: return String(localized: "tracked")
        }
    }

    // MARK: - Action items

    @ViewBuilder
    private var actionSection: some View {
        let groups = viewModel.activityItemsByPR
        if groups.isEmpty {
            Text(snapshot.isEstablishingBaseline
                 ? String(localized: "The first observation is still running. Existing activity is recorded silently as a baseline, so you are not notified about old events.")
                 : String(localized: "Nothing needs your attention right now. New activity is collected in the background."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ForEach(groups, id: \.pr.prNodeID) { group in
                prCard(pr: group.pr, items: group.items)
            }
        }
    }

    private func prCard(pr: MonitoredPR, items: [PRActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    if let url = pr.url {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("\(pr.reference.repoFullName)#\(pr.reference.number)")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text(pr.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                menu(for: pr)
            }

            ForEach(items) { item in
                itemRow(item, pr: pr)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func itemRow(_ item: PRActionItem, pr: MonitoredPR) -> some View {
        let events = viewModel.activityEvents(forPR: pr.prNodeID).filter { item.eventIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.reasons.map(PRActivityDigestFormatter.reasonLabel).joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                if item.state != .open {
                    Text(PRActivityDigestFormatter.stateLabel(item.state))
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                }
                Spacer()
                Text(item.actionKinds.map(PRActivityDigestFormatter.actionLabel).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let latest = events.first {
                Text("\(PRActivityDigestFormatter.changeLabel(latest.kind))\(latest.actor.map { " — \($0)" } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(Array(item.evidenceURLs.prefix(3)), id: \.absoluteString) { url in
                    Button("Open evidence") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                Spacer()
                Button("Handled") { viewModel.markActivityHandled(item) }
                    .controlSize(.small)
                Menu("Snooze") {
                    Button("1 hour") { viewModel.snoozeActivity(item, until: Date().addingTimeInterval(3600)) }
                    Button("Tomorrow") { viewModel.snoozeActivity(item, until: Date().addingTimeInterval(24 * 3600)) }
                    Button("Next week") { viewModel.snoozeActivity(item, until: Date().addingTimeInterval(7 * 24 * 3600)) }
                }
                .controlSize(.small)
                .frame(width: 90)
            }
        }
        .padding(.vertical, 3)
    }

    private func menu(for pr: MonitoredPR) -> some View {
        Menu {
            Button(viewModel.isActivityMuted(pr) ? "Unmute notifications" : "Mute notifications") {
                viewModel.setActivityMuted(!viewModel.isActivityMuted(pr), pr: pr)
            }
            Button(pr.isExplicitlyTracked ? "Stop tracking" : "Track this PR") {
                viewModel.setActivityTracking(pr, tracked: !pr.isExplicitlyTracked)
            }
            Divider()
            Button("Open on GitHub") {
                if let url = pr.url {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }

    // MARK: - Tracked PRs

    @ViewBuilder
    private var trackedSection: some View {
        let tracked = snapshot.monitoredPRs.filter(\.isExplicitlyTracked)
        if !tracked.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tracked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(tracked, id: \.prNodeID) { pr in
                    HStack {
                        Text("\(pr.reference.repoFullName)#\(pr.reference.number)")
                            .font(.caption2)
                        Spacer()
                        Button("Stop tracking") {
                            viewModel.setActivityTracking(pr, tracked: false)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
        }
    }

    // MARK: - Digest deliveries

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Digest deliveries")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(snapshot.batches.suffix(5).reversed()) { batch in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                        Text(batch.entries.map { "\($0.reference.repoFullName)#\($0.reference.number)" }.joined(separator: ", "))
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if batch.deliveries.contains(where: { $0.status == .failed || $0.status == .unknown }) {
                            Button("Retry") { viewModel.retryActivityDigest(batch) }
                                .controlSize(.small)
                        }
                    }
                    ForEach(batch.deliveries, id: \.channel) { delivery in
                        Text("\(delivery.channel.rawValue): \(PRActivityDigestFormatter.deliveryLabel(delivery.status))\(delivery.failureMessage.map { " — \($0)" } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(delivery.status == .delivered ? .secondary : .primary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(8)
        .background(tint.opacity(0.12))
        .cornerRadius(6)
    }
}
