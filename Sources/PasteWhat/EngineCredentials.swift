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
        try AtomicPrivateFile.write(Data(secret.utf8), to: jevFile)
    }

    static func removeJevKey() throws {
        if hasJevKey { try FileManager.default.removeItem(at: jevFile) }
    }
}
