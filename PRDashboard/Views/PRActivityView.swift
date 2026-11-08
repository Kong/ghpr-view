import SwiftUI
import AppKit

struct PRActivityActions {
    var observe: () -> Void
    var openURL: (URL) -> Void
    var markHandled: ([String]) -> Void
    var snooze: ([String], TimeInterval) -> Void
    var setMuted: (MonitoredPR, Bool) -> Void
    var setTracked: (MonitoredPR, Bool) -> Void
    var retry: (DigestBatch) -> Void
}

struct PRActivityView: View {
    @ObservedObject var viewModel: PRListViewModel
    @ObservedObject var navigation: ActivityNavigation

    var body: some View {
        PRActivityContent(
            snapshot: viewModel.activity,
            groups: viewModel.activityItemsByPR,
            mutedIdentifiers: Set(viewModel.activity.monitoredPRs.filter(viewModel.isActivityMuted).map { $0.reference.identifier }),
            actions: PRActivityActions(
                observe: { viewModel.refreshActivity() },
                openURL: { NSWorkspace.shared.open($0) },
                markHandled: { viewModel.markActivityHandled($0) },
                snooze: { viewModel.snoozeActivity($0, until: Date().addingTimeInterval($1)) },
                setMuted: { viewModel.setActivityMuted($1, pr: $0) },
                setTracked: { viewModel.setActivityTracking($0, tracked: $1) },
                retry: { viewModel.retryActivityDigest($0) }
            ), navigation: navigation
        )
    }
}

struct PRActivityContent: View {
    let snapshot: PRActivitySnapshot
    let groups: [(pr: MonitoredPR, items: [PRActionItem])]
    let mutedIdentifiers: Set<String>
    let actions: PRActivityActions
    @ObservedObject var navigation: ActivityNavigation
    @State private var showsIncompleteSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    notificationContext
                        .id(ActivityNotificationTarget.context)
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
            .onAppear { scrollToNotification(proxy) }
            .onChange(of: navigation.requestRevision) { _ in scrollToNotification(proxy) }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    actions.observe()
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
        if groups.isEmpty {
            Text(snapshot.isEstablishingBaseline
                 ? String(localized: "The first observation is still running. Existing activity is recorded silently as a baseline, so you are not notified about old events.")
                 : String(localized: "Nothing needs your attention right now. New activity is collected in the background."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            Text("Dismiss reminder only hides that row here. It does not reply, resolve, rerun CI, or change GitHub.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(groups, id: \.pr.prNodeID) { group in
                prCard(pr: group.pr, items: group.items)
            }
        }
    }

    private func prCard(pr: MonitoredPR, items: [PRActionItem]) -> some View {
        let reminders = PRActivityEngine.reminders(from: items)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    if let url = pr.url {
                        actions.openURL(url)
                    }
                } label: {
                    Text("\(pr.reference.repoFullName)#\(pr.reference.number)")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                menu(for: pr)
            }
            Text(pr.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)

            ForEach(reminders) { reminder in
                itemRow(reminder, pr: pr)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func itemRow(_ reminder: ActivityReminder, pr: MonitoredPR) -> some View {
        let events = snapshot.events
            .filter { reminder.eventIDs.contains($0.id) }
            .sorted { $0.occurredAt > $1.occurredAt }
        let suggested = reminder.actionKinds.map(PRActivityDigestFormatter.actionLabel).joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(reminder.reasons.map(PRActivityDigestFormatter.reasonLabel).joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                if reminder.state != .open {
                    Text(PRActivityDigestFormatter.stateLabel(reminder.state))
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                }
                Spacer()
            }
            let timestamp = events.first?.occurredAt ?? reminder.stateUpdatedAt
            Text("\(events.isEmpty ? "Reminder updated" : "Event") · \(timestamp.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(events.isEmpty ? "Reminder updated" : "Event") \(fullTimestamp(timestamp))")
                .help(fullTimestamp(timestamp))

            if let latest = events.first {
                Text("\(PRActivityDigestFormatter.changeLabel(latest.kind))\(latest.actor.map { " — \($0)" } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if events.count > 1 {
                Text(String(format: String(localized: "%lld other changes on this reminder"), events.count - 1))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !suggested.isEmpty {
                Text(String(format: String(localized: "Suggested: %@"), suggested))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("A suggestion only. ghpr does not do this on GitHub.")
            }

            HStack(spacing: 8) {
                if let url = reminder.evidenceURLs.first ?? pr.url {
                    Button("Open evidence") {
                        actions.openURL(url)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("Opens this on GitHub. ghpr does not reply, resolve, or rerun anything.")
                }
                if reminder.evidenceURLs.count > 1 {
                    Menu("More links") {
                        ForEach(Array(reminder.evidenceURLs.dropFirst().prefix(5)), id: \.absoluteString) { url in
                            Button(linkLabel(url)) {
                                actions.openURL(url)
                            }
                        }
                    }
                    .controlSize(.small)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                Button("Dismiss reminder") { actions.markHandled(reminder.itemIDs) }
                    .controlSize(.small)
                    .help("Hides this reminder in ghpr only. It does not reply, resolve a thread, rerun CI, or change GitHub. New activity shows it again.")
                Menu("Snooze") {
                    Button("1 hour") { actions.snooze(reminder.itemIDs, 3600) }
                    Button("24 hours") { actions.snooze(reminder.itemIDs, 24 * 3600) }
                    Button("7 days") { actions.snooze(reminder.itemIDs, 7 * 24 * 3600) }
                }
                .controlSize(.small)
                .frame(width: 90)
                .help("Hides this reminder until then. New activity shows it again immediately.")
            }
        }
        .padding(.vertical, 3)
        .id(ActivityNotificationTarget.reminder(id: reminder.id))
        .accessibilityIdentifier("activity-reminder-\(reminder.id)")
        .background(isTarget(reminder) ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func menu(for pr: MonitoredPR) -> some View {
        Menu {
            Button(mutedIdentifiers.contains(pr.reference.identifier) ? "Unmute notifications" : "Mute notifications") {
                actions.setMuted(pr, !mutedIdentifiers.contains(pr.reference.identifier))
            }
            Button(pr.isExplicitlyTracked ? "Stop tracking" : "Track this PR") {
                actions.setTracked(pr, !pr.isExplicitlyTracked)
            }
            Divider()
            Button("Open on GitHub") {
                if let url = pr.url {
                    actions.openURL(url)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }


    private func linkLabel(_ url: URL) -> String {
        let tail = url.lastPathComponent
        return tail.isEmpty ? url.absoluteString : tail
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
                            actions.setTracked(pr, false)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 6)
            Divider()
        }
    }

    // MARK: - Digest deliveries

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Digest deliveries")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(displayedBatches) { batch in
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
                            Button("Retry") { actions.retry(batch) }
                                .controlSize(.small)
                        }
                    }
                    ForEach(batch.deliveries, id: \.channel) { delivery in
                        Text("\(delivery.channel.rawValue): \(PRActivityDigestFormatter.deliveryLabel(delivery.status))\(delivery.failureMessage.map { " — \($0)" } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(delivery.status == .delivered || delivery.status == .superseded ? .secondary : .primary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers
    private var notificationContextValue: ActivityNotificationContext {
        ActivityNavigation.resolve(batchID: navigation.digestBatchID, snapshot: snapshot)
    }

    private var displayedBatches: [DigestBatch] {
        var batches = Array(snapshot.batches.suffix(5).reversed())
        if case .available(let batch, _) = notificationContextValue,
           !batches.contains(where: { $0.id == batch.id }) {
            batches.insert(batch, at: 0)
        }
        return batches
    }

    @ViewBuilder
    private var notificationContext: some View {
        switch notificationContextValue {
        case .none:
            EmptyView()
        case .missing:
            Text("This notification is no longer available in local history")
                .font(.caption)
                .accessibilityIdentifier("activity-digest-context")
        case .available(let batch, let items):
            VStack(alignment: .leading, spacing: 6) {
                Text("Notification · \(batch.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Notification \(fullTimestamp(batch.createdAt))")
                ForEach(batch.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.reference.repoFullName)#\(entry.reference.number) · \(entry.reasons.map(PRActivityDigestFormatter.reasonLabel).joined(separator: ", "))")
                        let current = items.filter { entry.actionItemIDs.contains($0.id) }
                        Text(current.isEmpty ? "No longer in current reminders" : current.map { PRActivityDigestFormatter.stateLabel($0.state) }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .accessibilityIdentifier("activity-digest-context")
        }
    }

    private func isTarget(_ reminder: ActivityReminder) -> Bool {
        guard case .available(let batch, _) = notificationContextValue else { return false }
        return !Set(batch.coveredActionItemIDs).isDisjoint(with: reminder.itemIDs)
    }

    private func scrollToNotification(_ proxy: ScrollViewProxy) {
        let reminders = groups.flatMap { PRActivityEngine.reminders(from: $0.items) }
        guard let target = ActivityNavigation.scrollTarget(
            batchID: navigation.digestBatchID, snapshot: snapshot, reminders: reminders
        ) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(target, anchor: .top) }
    }

    private func fullTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute().second().timeZone(.identifier(.long)))
    }


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
