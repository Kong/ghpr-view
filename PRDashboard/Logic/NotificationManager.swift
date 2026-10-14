import Foundation
import UserNotifications
import AppKit
import os

private let notificationLogger = Logger(
    subsystem: "com.prdashboard",
    category: "NotificationManager"
)

enum NotificationDeliveryError: LocalizedError, Equatable {
    case notAuthorized
    case schedulingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return String(localized: "macOS notifications are not authorized for PR Dashboard.")
        case .schedulingFailed(let reason):
            return String(localized: "macOS notification could not be delivered: \(reason)")
        }
    }
}

/// Native (macOS) delivery for activity digests, plus the shared mute preference.
///
/// Only digests are delivered here: the app no longer posts one notification per PR
/// event. Authorization failure affects this channel alone and never marks the Slack
/// channel unavailable.
final class NotificationManager: NSObject, ObservableObject {
    static let digestCategoryIdentifier = "PR_ACTIVITY_DIGEST"
    static let openActivityActionIdentifier = "OPEN_ACTIVITY"
    static let muteActionIdentifier = "MUTE_PR"
    static let digestBatchUserInfoKey = "digest_batch_id"
    static let prIdentifierUserInfoKey = "pr_identifier"

    @Published private(set) var isAuthorized = false
    var openURL: (@MainActor (URL) -> Void)?
    /// Opens the native activity entry when the user activates a digest notification.
    var openActivity: (@MainActor () -> Void)?

    private let notificationCenter: UNUserNotificationCenter?
    private var mutedPRIdentifiers: Set<String> = []
    private static let mutedPRIdentifiersKey = "muted_pr_identifiers"
    /// Pre-1.7 builds stored mute state as GitHub database IDs with no owner/repo, so the
    /// values cannot be mapped onto identifiers. Nothing in the UI ever wrote that key.
    private static let legacyMutedPRIDsKey = "muted_pr_ids"

    init(useSystemNotificationCenter: Bool = true) {
        notificationCenter = useSystemNotificationCenter
            ? UNUserNotificationCenter.current()
            : nil
        super.init()
        notificationCenter?.delegate = self
        loadMutedPRs()
        registerCategories()
    }

    func requestPermission() {
        notificationCenter?.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }
            if let error {
                notificationLogger.error(
                    "Notification permission failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Digest delivery

    func deliverDigest(_ batch: DigestBatch) async throws -> DigestReceipt {
        guard let notificationCenter, isAuthorized else {
            throw NotificationDeliveryError.notAuthorized
        }

        let content = UNMutableNotificationContent()
        content.title = PRActivityDigestFormatter.nativeTitle(for: batch)
        content.body = PRActivityDigestFormatter.nativeBody(for: batch)
        content.sound = .default
        content.categoryIdentifier = Self.digestCategoryIdentifier
        content.userInfo = [Self.digestBatchUserInfoKey: batch.id]

        let request = UNNotificationRequest(
            identifier: "digest-\(batch.id)",
            content: content,
            trigger: nil
        )

        try await add(request, to: notificationCenter)
        return DigestReceipt(
            channelID: nil,
            workspace: nil,
            messageTimestamp: batch.id,
            recipientUserID: nil
        )
    }

    /// Drops a digest that was already shown. A recovered CI failure must not keep
    /// sitting in Notification Center as if it still needs attention.
    func withdrawDigest(id: String) {
        let identifier = "digest-\(id)"
        notificationCenter?.removeDeliveredNotifications(withIdentifiers: [identifier])
        notificationCenter?.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: NotificationDeliveryError.schedulingFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Mute preference

    /// Mute state for a PR, shared by digest delivery and the activity view. Muting
    /// affects delivery only: collection and the existing unread counts are untouched.
    func isPRMuted(_ identifier: String) -> Bool {
        mutedPRIdentifiers.contains(identifier)
    }

    func mutePR(_ identifier: String) {
        var updated = mutedPRIdentifiers
        updated.insert(identifier)
        mutedPRIdentifiers = updated
        saveMutedPRs(updated)
    }

    func unmutePR(_ identifier: String) {
        var updated = mutedPRIdentifiers
        updated.remove(identifier)
        mutedPRIdentifiers = updated
        saveMutedPRs(updated)
    }

    // MARK: - Private

    private func loadMutedPRs() {
        if let identifiers = UserDefaults.standard.stringArray(forKey: Self.mutedPRIdentifiersKey) {
            mutedPRIdentifiers = Set(identifiers)
        }
        if let legacy = UserDefaults.standard.array(forKey: Self.legacyMutedPRIDsKey) as? [Int] {
            if !legacy.isEmpty {
                notificationLogger.warning(
                    "Discarding \(legacy.count, privacy: .public) legacy PR mute entries: database IDs cannot be mapped to repository identifiers."
                )
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyMutedPRIDsKey)
        }
    }

    private func saveMutedPRs(_ identifiers: Set<String>) {
        UserDefaults.standard.set(Array(identifiers).sorted(), forKey: Self.mutedPRIdentifiersKey)
    }

    private func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: Self.openActivityActionIdentifier,
            title: String(localized: "Open Activity"),
            options: .foreground
        )

        let category = UNNotificationCategory(
            identifier: Self.digestCategoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter?.setNotificationCategories([category])
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let isDigest = response.notification.request.content.categoryIdentifier == Self.digestCategoryIdentifier
            || userInfo[Self.digestBatchUserInfoKey] != nil

        switch response.actionIdentifier {
        case Self.muteActionIdentifier:
            if let identifier = userInfo[Self.prIdentifierUserInfoKey] as? String {
                mutePR(identifier)
            } else if isDigest, let batchID = userInfo[Self.digestBatchUserInfoKey] as? String {
                notificationLogger.info("Digest mute action ignored: batch \(batchID, privacy: .public) covers several PRs.")
            }

        case Self.openActivityActionIdentifier, UNNotificationDefaultActionIdentifier:
            if isDigest, let openActivity {
                Task { @MainActor in
                    openActivity()
                }
            } else if let urlString = userInfo["pr_url"] as? String,
                      let url = URL(string: urlString) {
                if let openURL {
                    Task { @MainActor in
                        openURL(url)
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
            }

        default:
            break
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the digest even when the app is in the foreground.
        completionHandler([.banner, .sound])
    }
}

/// `PRActivityDigestChannel` adapter for the native channel.
@MainActor
final class MacOSActivityDigestChannel: PRActivityDigestChannel {
    let channel: DigestChannel = .macOS
    private let notificationManager: NotificationManager

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
    }

    var isAvailable: Bool { notificationManager.isAuthorized }

    var targetBinding: [String: String] { [:] }

    func deliver(_ batch: DigestBatch) async throws -> DigestReceipt {
        try await notificationManager.deliverDigest(batch)
    }

    func withdrawDeliveredDigest(id: String) {
        notificationManager.withdrawDigest(id: id)
    }
}
