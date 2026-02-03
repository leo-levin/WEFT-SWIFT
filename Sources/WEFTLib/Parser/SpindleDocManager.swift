// SpindleDocManager.swift - Centralized spindle documentation management

import Foundation

/// Manages documentation for all spindles (stdlib and builtins)
public class SpindleDocManager {

    /// Shared instance for app-wide access
    public static let shared = SpindleDocManager()

    /// All spindle documentation (stdlib + builtins)
    private var docs: [String: SpindleDoc] = [:]

    /// Whether docs have been loaded
    private var isLoaded = false

    public init() {
        loadDocs()
    }

    /// Load documentation from stdlib files and builtins
    public func loadDocs() {
        guard !isLoaded else { return }

        // Start with builtin docs
        docs = BuiltinDocs.docs

        // Load stdlib docs
        if let stdlibURL = WeftStdlib.findStdlibURL() {
            loadStdlibDocs(from: stdlibURL)
        }

        isLoaded = true
    }

    /// Reload documentation (useful if stdlib files change)
    public func reloadDocs() {
        isLoaded = false
        docs.removeAll()
        loadDocs()
    }

    /// Look up documentation for a spindle or builtin by name
    public func documentation(for name: String) -> SpindleDoc? {
        return docs[name]
    }

    /// Get all documented spindle names
    public var documentedNames: [String] {
        return Array(docs.keys).sorted()
    }

    /// Check if a name has documentation
    public func hasDocumentation(for name: String) -> Bool {
        return docs[name] != nil
    }

    // MARK: - Private

    private func loadStdlibDocs(from directory: URL) {
        let parser = DocParser()
        let fileManager = FileManager.default

        do {
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for file in files where file.pathExtension == "weft" {
                if let source = try? String(contentsOf: file, encoding: .utf8) {
                    let fileDocs = parser.parseDocComments(from: source)
                    // Merge, preferring stdlib docs over any existing
                    for (name, doc) in fileDocs {
                        docs[name] = doc
                    }
                }
            }
        } catch {
            print("SpindleDocManager: Failed to load stdlib docs: \(error)")
        }
    }
}
