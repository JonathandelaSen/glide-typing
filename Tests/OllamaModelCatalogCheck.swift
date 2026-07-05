import Foundation

@main
struct OllamaModelCatalogCheck {
    static func main() throws {
        let payload = """
        {
          "models": [
            { "name": "qwen3:4b" },
            { "name": "gemma3:1b" },
            { "name": "" }
          ]
        }
        """.data(using: .utf8)!

        let modelNames = try OllamaModelCatalog.modelNames(from: payload)
        precondition(modelNames == ["gemma3:1b", "qwen3:4b"])
        precondition(OllamaModelCatalog.isSelectorEnabled(for: "ollama"))
        precondition(!OllamaModelCatalog.isSelectorEnabled(for: "system"))
        precondition(!OllamaModelCatalog.isSelectorEnabled(for: "off"))
    }
}
