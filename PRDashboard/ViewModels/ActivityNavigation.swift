import Foundation
import Combine

enum ActivityNotificationContext {
    case none
    case available(batch: DigestBatch, items: [PRActionItem])
    case missing(batchID: String)
}

enum ActivityNotificationTarget: Hashable {
    case context
    case reminder(id: String)
}

@MainActor
final class ActivityNavigation: ObservableObject {
    @Published var digestBatchID: String? {
        didSet { requestRevision += 1 }
    }
    @Published private(set) var requestRevision: UInt64 = 0

    init(digestBatchID: String? = nil) {
        self.digestBatchID = digestBatchID
    }

    static func resolve(batchID: String?, snapshot: PRActivitySnapshot) -> ActivityNotificationContext {
        guard let batchID else { return .none }
        guard let batch = snapshot.batches.first(where: { $0.id == batchID }) else {
            return .missing(batchID: batchID)
        }
        let covered = Set(batch.coveredActionItemIDs)
        return .available(batch: batch, items: snapshot.actionItems.filter { covered.contains($0.id) })
    }

    static func scrollTarget(
        batchID: String?, snapshot: PRActivitySnapshot, reminders: [ActivityReminder]
    ) -> ActivityNotificationTarget? {
        switch resolve(batchID: batchID, snapshot: snapshot) {
        case .none:
            return nil
        case .missing:
            return .context
        case .available(let batch, _):
            let covered = Set(batch.coveredActionItemIDs)
            guard let reminder = reminders.first(where: { !covered.isDisjoint(with: $0.itemIDs) }) else {
                return .context
            }
            return .reminder(id: reminder.id)
        }
    }
}
