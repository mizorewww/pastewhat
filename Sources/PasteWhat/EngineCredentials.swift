import Darwin
import Foundation

enum EngineCredentials {
    private static var directory: URL { AppPaths.support.appendingPathComponent("credentials", isDirectory: true) }
    private static var jevFile: URL { directory.appendingPathComponent("jev.key") }

    static var hasJevKey: Bool { FileManager.default.fileExists(atPath: jevFile.path) }

    static func saveJevKey(_ value: String) throws {
        let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, secret.utf8.count <= 4096,
              secret.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".jev-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: Data(secret.utf8),
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            jevFile.withUnsafeFileSystemRepresentation { target in Darwin.rename(source!, target!) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func removeJevKey() throws {
        if hasJevKey { try FileManager.default.removeItem(at: jevFile) }
    }
}
