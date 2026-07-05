import Foundation

enum OllamaModelCatalog {
    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            let name: String
        }

        let models: [Model]
    }

    enum CatalogError: LocalizedError {
        case invalidResponse

        var errorDescription: String? {
            "Ollama no respondió correctamente."
        }
    }

    static func isSelectorEnabled(for engine: String) -> Bool {
        engine == "ollama"
    }

    static func modelNames(from data: Data) throws -> [String] {
        let response = try JSONDecoder().decode(TagsResponse.self, from: data)
        let names = response.models
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func fetch() async throws -> [String] {
        let url = URL(string: "http://127.0.0.1:11434/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw CatalogError.invalidResponse
        }
        return try modelNames(from: data)
    }
}
