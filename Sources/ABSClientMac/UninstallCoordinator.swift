import Foundation
import Security
import ABSCore

enum UninstallError: LocalizedError {
    case missingApplicationSupport
    case failedToCreateHelper

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupport:
            return "Unable to locate Application Support directory."
        case .failedToCreateHelper:
            return "Unable to create uninstall helper script."
        }
    }
}

enum UninstallStep: String, CaseIterable, Identifiable {
    case validatePaths
    case exportDownloads
    case clearKeychain
    case clearDefaults
    case prepareHelper
    case launchHelper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .validatePaths:
            return "Validate uninstall paths"
        case .exportDownloads:
            return "Export downloaded books (optional)"
        case .clearKeychain:
            return "Clear saved credentials"
        case .clearDefaults:
            return "Clear app preferences"
        case .prepareHelper:
            return "Prepare uninstall helper"
        case .launchHelper:
            return "Launch helper and finalize uninstall"
        }
    }
}

enum UninstallCoordinator {
    static func prepareAndLaunchUninstall(
        exportDownloadsTo destinationURL: URL?,
        selectedDownloadItemIDs: Set<String> = [],
        onStepStateChange: ((UninstallStep, Bool) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let processID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.indexd.app"

        onStepStateChange?(.validatePaths, true)
        guard let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw UninstallError.missingApplicationSupport
        }
        onStepStateChange?(.validatePaths, false)

        let appSupportDirectory = applicationSupportRoot.appendingPathComponent("indexd", isDirectory: true)
        let downloadCacheDirectory = appSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)

        onStepStateChange?(.exportDownloads, true)
        if let destinationURL {
            try exportDownloadsIfNeeded(
                from: downloadCacheDirectory,
                manifestURL: appSupportDirectory.appendingPathComponent("downloads-manifest.json"),
                to: destinationURL.standardizedFileURL,
                selectedItemIDs: selectedDownloadItemIDs
            )
        }
        onStepStateChange?(.exportDownloads, false)

        onStepStateChange?(.clearKeychain, true)
        clearAuthKeychainEntries()
        onStepStateChange?(.clearKeychain, false)

        onStepStateChange?(.clearDefaults, true)
        clearDefaults(bundleIdentifier: bundleIdentifier)
        onStepStateChange?(.clearDefaults, false)

        let homeLibrary = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let removalPaths = [
            appSupportDirectory,
            homeLibrary.appendingPathComponent("Caches/indexd", isDirectory: true),
            homeLibrary.appendingPathComponent("Caches/\(bundleIdentifier)", isDirectory: true),
            homeLibrary.appendingPathComponent("Logs/indexd", isDirectory: true),
            homeLibrary.appendingPathComponent("Logs/\(bundleIdentifier)", isDirectory: true),
            homeLibrary.appendingPathComponent("Preferences/\(bundleIdentifier).plist", isDirectory: false),
            appURL
        ]

        onStepStateChange?(.prepareHelper, true)
        let helperScriptURL = try createUninstallHelperScript(
            processID: processID,
            removalPaths: removalPaths
        )
        onStepStateChange?(.prepareHelper, false)

        onStepStateChange?(.launchHelper, true)
        try launchHelper(at: helperScriptURL)
        onStepStateChange?(.launchHelper, false)
    }

    private static func exportDownloadsIfNeeded(
        from cacheURL: URL,
        manifestURL: URL,
        to destinationURL: URL,
        selectedItemIDs: Set<String>
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }

        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(
            at: cacheURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let selectedFilenames: Set<String>
        if selectedItemIDs.isEmpty {
            selectedFilenames = []
        } else {
            selectedFilenames = Set(
                (loadRecordsFromManifest(at: manifestURL) ?? [])
                    .filter { selectedItemIDs.contains($0.itemID) }
                    .map(\.localFileName)
            )
        }

        for sourceURL in contents {
            if !selectedFilenames.isEmpty && !selectedFilenames.contains(sourceURL.lastPathComponent) {
                continue
            }
            let targetURL = uniqueDestinationURL(
                base: destinationURL.appendingPathComponent(sourceURL.lastPathComponent),
                fileManager: fileManager
            )
            do {
                try fileManager.moveItem(at: sourceURL, to: targetURL)
            } catch {
                try fileManager.copyItem(at: sourceURL, to: targetURL)
                try? fileManager.removeItem(at: sourceURL)
            }
        }
    }

    private static func loadRecordsFromManifest(at manifestURL: URL) -> [DownloadRecord]? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode([DownloadRecord].self, from: data)
    }

    private static func uniqueDestinationURL(base: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: base.path) else { return base }

        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let parent = base.deletingLastPathComponent()
        var attempt = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(ext)"
            let candidate = parent.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private static func clearAuthKeychainEntries() {
        let defaults = UserDefaults.standard
        let maybeServerURL = defaults.string(forKey: "abs.server.url").flatMap(URL.init(string:))
        let host = maybeServerURL?.host ?? maybeServerURL?.absoluteString
        guard let host, !host.isEmpty else {
            return
        }

        let service = "com.indexd.auth.\(host)"
        let accounts = ["auth.token", "auth.credentials"]
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    private static func clearDefaults(bundleIdentifier: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "abs.server.url")
        defaults.removePersistentDomain(forName: bundleIdentifier)
        defaults.synchronize()

        if let devStoreDefaults = UserDefaults(suiteName: "indexd.DevSecureStore") {
            devStoreDefaults.removePersistentDomain(forName: "indexd.DevSecureStore")
            devStoreDefaults.synchronize()
        }
    }

    private static func createUninstallHelperScript(
        processID: Int32,
        removalPaths: [URL]
    ) throws -> URL {
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("indexd-uninstall-\(UUID().uuidString).sh")

        let removeLines = removalPaths
            .map(\.path)
            .map(shellQuoted)
            .map { "rm -rf -- \($0) || true" }
            .joined(separator: "\n")

        let script = """
        #!/bin/bash
        set -euo pipefail

        TARGET_PID=\(processID)
        while kill -0 "$TARGET_PID" 2>/dev/null; do
          sleep 0.2
        done

        \(removeLines)

        rm -f -- "$0" || true
        """

        do {
            try script.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: helperURL.path
            )
            return helperURL
        } catch {
            throw UninstallError.failedToCreateHelper
        }
    }

    private static func launchHelper(at helperURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperURL.path]
        process.standardOutput = nil
        process.standardError = nil
        process.standardInput = nil
        try process.run()
    }

    private static func shellQuoted(_ input: String) -> String {
        "'" + input.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
