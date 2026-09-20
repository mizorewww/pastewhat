import Foundation

/// Runs the actual application's identity-to-model projection on synthetic data.
/// Compile with Models.swift and RecommendationContext.swift; no AppKit capture occurs.
@main
enum ProjectContext {
    struct Input: Decodable {
        var id: String
        var nativeContext: AppContext
    }

    struct Output: Encodable {
        var id: String
        var context: ModelContext
    }

    static func main() throws {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        let inputs = try JSONDecoder().decode([Input].self, from: data)
        let outputs = inputs.map { Output(id: $0.id, context: $0.nativeContext.modelContext) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(outputs))
    }
}
