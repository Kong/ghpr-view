import Foundation

struct HomebrewCaskVersion: Equatable {
    let installed: AppVersion
    let advertised: AppVersion

    func canInstall(_ release: ReleaseInfo) -> Bool {
        advertised >= release.version && advertised > installed
    }
}

struct HomebrewInstallation: Equatable {
    static let cask = "xiaocang/tap/prdashboard"
    static let upgradeCommand = "brew upgrade --cask \(cask)"

    let executableURL: URL
    let appURL: URL

    static func resolve(
        appURL: URL,
        prefixes: [URL] = standardPrefixes,
        fileManager: FileManager = .default
    ) -> Self? {
        let runningPath = appURL.resolvingSymlinksInPath().path

        for prefix in prefixes {
            let metadata = prefix.appendingPathComponent("Caskroom/prdashboard/.metadata", isDirectory: true)
            let receiptURL = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
            guard let receiptData = try? Data(contentsOf: receiptURL),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: receiptData),
                  receipt.source.tap == "xiaocang/tap" else {
                continue
            }

            let configURL = metadata.appendingPathComponent("config.json")
            let configuration = (try? Data(contentsOf: configURL))
                .flatMap { try? JSONDecoder().decode(CaskConfiguration.self, from: $0) }
            let appDirectory = configuration?.explicit?.appdir ?? configuration?.defaults?.appdir ?? "/Applications"
            let installedApp = URL(fileURLWithPath: (appDirectory as NSString).expandingTildeInPath)
                .appendingPathComponent("PRDashboard.app", isDirectory: true)
            guard installedApp.resolvingSymlinksInPath().path == runningPath,
                  fileManager.fileExists(atPath: installedApp.path) else { continue }

            return Self(executableURL: prefix.appendingPathComponent("bin/brew"), appURL: installedApp)
        }

        return nil
    }

    func caskVersion() async -> HomebrewCaskVersion? {
        let arguments = ["info", "--cask", "--json=v2", Self.cask]
        return await Task.detached(priority: .utility) {
            guard let data = try? run(arguments) else { return nil }
            return Self.caskVersion(in: data)
        }.value
    }

    func refreshMetadata() async throws {
        try await Task.detached(priority: .utility) {
            _ = try run(["update"])
        }.value
    }

    static func caskVersion(in data: Data) -> HomebrewCaskVersion? {
        guard let info = try? JSONDecoder().decode(CaskInfo.self, from: data),
              let cask = info.casks.first(where: { $0.fullToken == Self.cask }),
              let installed = cask.installed,
              let installedVersion = stableVersion(installed),
              let advertisedVersion = stableVersion(cask.version) else {
            return nil
        }
        return HomebrewCaskVersion(installed: installedVersion, advertised: advertisedVersion)
    }

    func launchUpgrade(expectedVersion: AppVersion, resultURL: URL, parentPID: Int32) throws {
        let script = """
        pid=$1
        brew=$2
        app=$3
        cask=$4
        version=$5
        result=$6
        remaining=30
        while kill -0 "$pid" 2>/dev/null; do
          [ "$remaining" -gt 0 ] || exit 1
          remaining=$((remaining - 1))
          /bin/sleep 1
        done

        export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
        "$brew" upgrade --cask --require-sha --appdir "${app%/*}" "$cask" </dev/null
        status=$?
        umask 077
        printf '%s\\n%s\\n' "$status" "$version" > "$result.tmp" && /bin/mv -f "$result.tmp" "$result"
        /usr/bin/open "$app"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "prdashboard-homebrew-upgrade", String(parentPID), executableURL.path,
            appURL.path, Self.cask, expectedVersion.rawValue, resultURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static var standardPrefixes: [URL] {
        let paths = ["/opt/homebrew", "/usr/local", ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"]]
        return paths.compactMap { path in
            guard let path, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private static func stableVersion(_ version: String) -> AppVersion? {
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return AppVersion(version)
    }

    private func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailed()
        }
        return data
    }

    private struct CommandFailed: Error {}

    private struct Receipt: Decodable {
        struct Source: Decodable {
            let tap: String
        }

        let source: Source
    }

    private struct CaskConfiguration: Decodable {
        struct Options: Decodable {
            let appdir: String?
        }

        let explicit: Options?
        let defaults: Options?

        enum CodingKeys: String, CodingKey {
            case explicit
            case defaults = "default"
        }
    }

    private struct CaskInfo: Decodable {
        struct Cask: Decodable {
            let fullToken: String
            let version: String
            let installed: String?

            enum CodingKeys: String, CodingKey {
                case fullToken = "full_token"
                case version
                case installed
            }
        }

        let casks: [Cask]
    }
}
