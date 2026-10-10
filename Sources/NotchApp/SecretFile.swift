import Foundation
import OSLog

private let secretsLog = Logger(subsystem: "com.robin.notch", category: "secrets")

/// Secrets (the Spotify refresh token, plug-in API keys) as owner-only files under
/// `~/Library/Application Support/Notch/`. Not the Keychain: its legacy ACL re-prompts for the
/// login password every time a side-loaded binary changes, which for a rebuilt app is every build.
enum SecretFile {
    private static func url(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Notch", isDirectory: true).appendingPathComponent(name)
    }

    static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func write(_ value: String, as name: String) {
        let file = url(name)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(value.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            secretsLog.error("couldn't save \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }
}
