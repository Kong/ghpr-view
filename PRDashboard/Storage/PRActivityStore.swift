import Foundation
import os

enum PRActivityStoreError: LocalizedError {
    case corruptFile(url: URL, underlying: String)
    case writeFailed(url: URL, underlying: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case .corruptFile(let url, let underlying):
            return String(localized: "Activity history at \(url.lastPathComponent) could not be read and was left untouched: \(underlying)")
        case .writeFailed(let url, let underlying):
            return String(localized: "Failed to save activity history to \(url.lastPathComponent): \(underlying)")
        case .unsupportedSchemaVersion(let found, let supported):
            return String(localized: "Activity history uses schema version \(found), newer than the supported version \(supported).")
        }
    }
}

/// Durable, account-scoped store for monitor checkpoints, activity events and action items.
///
/// Design constraints (from the monitor contract):
/// - Never stored in the expirable caches directory: a lost checkpoint would re-notify.
/// - One file per account (`endpoint` + viewer node ID), so logging out or switching
///   accounts never deletes another account's history.
/// - A corrupt file is preserved and reported. It is never reset silently, because a
///   silent reset would replay historical activity as if it were new.
/// - `persist` writes first; callers only advance their in-memory committed observation
///   after the write succeeds.
final class PRActivityStore {
    static let shared = PRActivityStore()

    private let logger = Logger(subsystem: "com.prdashboard", category: "PRActivityStore")
    private let fileManager: FileManager
    private let directoryURL: URL
    private let lock = NSLock()
    private var lastPersistedData: [String: Data] = [:]

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? PRActivityStore.defaultDirectoryURL(fileManager: fileManager)
        try? fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("ghpr", isDirectory: true)
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    func fileURL(for account: MonitorAccountKey) -> URL {
        directoryURL.appendingPathComponent("\(account.storageSlug).json")
    }

    /// Account slugs with a stored file. Used to prove other accounts' history survives.
    func storedAccountSlugs() -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    /// Returns nil when the account has no stored history yet.
    func load(account: MonitorAccountKey) throws -> PRActivityAccountState? {
        let url = fileURL(for: account)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PRActivityStoreError.corruptFile(url: url, underlying: error.localizedDescription)
        }

        let decoded: PRActivityAccountState
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoded = try decoder.decode(PRActivityAccountState.self, from: data)
        } catch {
            // Leave the file in place: it holds the only copy of the user's history.
            throw PRActivityStoreError.corruptFile(url: url, underlying: error.localizedDescription)
        }

        guard decoded.schemaVersion <= PRActivityAccountState.currentSchemaVersion else {
            throw PRActivityStoreError.unsupportedSchemaVersion(
                found: decoded.schemaVersion,
                supported: PRActivityAccountState.currentSchemaVersion
            )
        }

        lock.lock()
        lastPersistedData[account.storageSlug] = data
        lock.unlock()
        return decoded
    }

    /// Atomically persists the account state. Throws when the data could not be written;
    /// callers must then keep the previous in-memory observation.
    func persist(_ state: PRActivityAccountState) throws {
        let url = fileURL(for: state.account)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw PRActivityStoreError.writeFailed(url: url, underlying: error.localizedDescription)
        }

        lock.lock()
        let alreadyPersisted = lastPersistedData[state.account.storageSlug] == data
        lock.unlock()
        if alreadyPersisted { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw PRActivityStoreError.writeFailed(url: url, underlying: error.localizedDescription)
        }

        lock.lock()
        lastPersistedData[state.account.storageSlug] = data
        lock.unlock()
        logger.debug("Persisted activity state for \(state.account.displayName, privacy: .public) (\(state.events.count) events)")
    }

    #if DEBUG
    /// Test-only: removes this store's own directory, never another store instance's.
    func removeAllForTesting() {
        try? fileManager.removeItem(at: directoryURL)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        lock.lock()
        lastPersistedData = [:]
        lock.unlock()
    }
    #endif
}
