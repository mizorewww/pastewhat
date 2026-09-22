import Darwin
import Foundation

struct EngineConfiguration: Codable, Sendable, Equatable {
    var backend: String
    var pythonPath: String
    var modelPath: String

    var isRemote: Bool { backend == "jev" }
    var displayName: String { isRemote ? "Jev" : backend == "ranker" ? "PasteWhat Ranker" : "Laya" }

    static func discover() -> Self {
        let configurationURL = AppPaths.support.appendingPathComponent("engine.json")
        if let data = try? Data(contentsOf: configurationURL),
           let saved = try? JSONDecoder().decode(Self.self, from: data) {
            return saved
        }

        let manager = FileManager.default
        let workspaces = workspaceURLs
        let siblingDirectories = workspaces.map {
            $0.deletingLastPathComponent().appendingPathComponent("laya-mlx", isDirectory: true)
        }
        let pythonCandidates = (siblingDirectories + workspaces).map {
            $0.appendingPathComponent(".venv/bin/python").path
        }
        let modelCandidates = siblingDirectories.map {
            $0.appendingPathComponent("models/hub/laya-multilingual-mlx", isDirectory: true).path
        }
        return Self(
            backend: "mlx",
            pythonPath: pythonCandidates.first(where: manager.isExecutableFile(atPath:)) ?? "/usr/bin/python3",
            modelPath: modelCandidates.first(where: { path in
                var isDirectory: ObjCBool = false
                return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }) ?? AppPaths.support.appendingPathComponent("Models/laya-multilingual-mlx", isDirectory: true).path
        )
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try AtomicPrivateFile.write(data, to: AppPaths.support.appendingPathComponent("engine.json"))
    }

    static var workspaceURLs: [URL] {
        var directories: [URL] = []
        if let path = Bundle.main.object(forInfoDictionaryKey: "PasteWhatWorkspace") as? String,
           !path.isEmpty {
            directories.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL)
        }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
        if !directories.contains(current) { directories.append(current) }
        return directories
    }
}
