// ResourceManager.swift - Generic resource management protocol for WEFT

import Foundation

// MARK: - Resource Manager Protocol

/// Protocol for resource managers that load and cache resources by path.
/// Implementations include TextureManager, SampleManager, etc.
public protocol ResourceManagerProtocol {
    /// The type of resource being managed
    associatedtype Resource

    /// The error type for loading failures
    associatedtype LoadError: Error & LocalizedError

    /// Cache of loaded resources by resolved path
    var cache: [String: Resource] { get set }

    /// Resources indexed by resource ID (for shader binding)
    var resources: [Int: Resource] { get set }

    /// Tracks which resources failed to load and why
    var loadErrors: [Int: (path: String, error: LoadError)] { get set }

    /// Callback for when a file picker is needed (set by UI layer)
    var onPickerNeeded: ((_ forResourceId: Int, _ fileTypes: [String]) async -> URL?)? { get set }

    /// File extensions this manager handles (lowercase)
    static var supportedExtensions: Set<String> { get }

    /// Load a resource from a URL
    func loadFromURL(_ url: URL) throws -> Resource

    /// Create a placeholder resource for failed loads
    func createPlaceholder() -> Resource?
}

// MARK: - Default Implementations

extension ResourceManagerProtocol {
    /// Load resources from an array of paths, filtering by supported extensions
    /// - Parameters:
    ///   - paths: Array of file paths from IRProgram.resources
    ///   - sourceFileURL: URL of the .weft source file (for relative path resolution)
    /// - Returns: Dictionary mapping resource ID to loaded resource
    public mutating func loadResources(
        paths: [String],
        sourceFileURL: URL?
    ) throws -> [Int: Resource] {
        resources = [:]
        loadErrors = [:]

        let resolver = ResourcePathResolver(sourceFileURL: sourceFileURL)

        for (index, path) in paths.enumerated() {
            // Skip resources not handled by this manager
            guard ResourcePathResolver.hasExtension(path, in: Self.supportedExtensions) else {
                continue
            }

            do {
                let resource = try loadResource(path: path, resolver: resolver)
                resources[index] = resource
            } catch let error as LoadError {
                loadErrors[index] = (path: path, error: error)
                if let placeholder = createPlaceholder() {
                    resources[index] = placeholder
                }
            } catch {
                // Convert generic error to LoadError if possible
                loadErrors[index] = (path: path, error: convertError(error))
                if let placeholder = createPlaceholder() {
                    resources[index] = placeholder
                }
            }
        }

        return resources
    }

    /// Load a single resource from a path
    /// - Parameters:
    ///   - path: File path (can be relative or absolute)
    ///   - resolver: Path resolver for finding the file
    /// - Returns: Loaded resource
    public mutating func loadResource(
        path: String,
        resolver: ResourcePathResolver
    ) throws -> Resource {
        // Check cache first
        if let cached = cache[path] {
            return cached
        }

        // Resolve path
        let url = try resolver.resolve(path)

        // Load resource
        let resource = try loadFromURL(url)

        // Cache by original path
        cache[path] = resource

        return resource
    }

    /// Get a loaded resource by ID
    public func getResource(at index: Int) -> Resource? {
        resources[index]
    }

    /// Get all loaded resources
    public func getAllResources() -> [Int: Resource] {
        resources
    }

    /// Get the count of loaded resources
    public var resourceCount: Int {
        resources.count
    }

    /// Clear all cached resources
    public mutating func clearCache() {
        cache.removeAll()
        resources.removeAll()
    }

    /// Convert a generic error - default implementation returns a generic load failure
    /// Subclasses should override to return their specific error type
    private func convertError(_ error: Error) -> LoadError {
        // This is a workaround - concrete types should handle this
        fatalError("ResourceManager subclass must implement convertError or handle all errors")
    }
}

// MARK: - File Type Utilities

extension ResourceManagerProtocol {
    /// Check if a path matches this manager's supported extensions
    public static func canHandle(path: String) -> Bool {
        ResourcePathResolver.hasExtension(path, in: supportedExtensions)
    }
}
