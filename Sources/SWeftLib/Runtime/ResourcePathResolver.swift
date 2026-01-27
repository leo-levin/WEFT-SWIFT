// ResourcePathResolver.swift - Unified path resolution for WEFT resources

import Foundation

// MARK: - Resource Error

/// Unified error type for resource loading operations
public enum ResourceError: Error, LocalizedError {
    case fileNotFound(String)
    case loadFailed(String)
    case invalidFormat(String)
    case pickerCancelled
    case deviceNotAvailable

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Resource not found: \(path)"
        case .loadFailed(let message):
            return "Failed to load resource: \(message)"
        case .invalidFormat(let format):
            return "Invalid format: \(format)"
        case .pickerCancelled:
            return "File picker was cancelled"
        case .deviceNotAvailable:
            return "Device not available"
        }
    }
}

// MARK: - Resource Path Resolver

/// Handles path resolution for WEFT resources (textures, samples, etc.)
/// Implements a consistent search strategy across all resource types.
public struct ResourcePathResolver {
    /// The source file URL for relative path resolution
    public let sourceFileURL: URL?

    public init(sourceFileURL: URL? = nil) {
        self.sourceFileURL = sourceFileURL
    }

    /// Resolve a resource path to a URL
    /// - Parameter path: File path (can be relative or absolute)
    /// - Returns: Resolved URL if the file exists
    /// - Throws: ResourceError.fileNotFound if the file cannot be located
    ///
    /// Resolution order:
    /// 1. Absolute path (starts with "/" or "~")
    /// 2. Relative to source file directory
    /// 3. Relative to .weft-resources folder next to source file
    /// 4. Relative to current working directory
    public func resolve(_ path: String) throws -> URL {
        // 1. Try as absolute path
        if path.hasPrefix("/") || path.hasPrefix("~") {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // 2. Try relative to source file
        if let sourceURL = sourceFileURL {
            let sourceDir = sourceURL.deletingLastPathComponent()
            let relativeURL = sourceDir.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: relativeURL.path) {
                return relativeURL
            }

            // 3. Try in .weft-resources folder next to source file
            let resourcesDir = sourceDir.appendingPathComponent(".weft-resources")
            let resourceURL = resourcesDir.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: resourceURL.path) {
                return resourceURL
            }
        }

        // 4. Try relative to current working directory
        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: cwdURL.path) {
            return cwdURL
        }

        throw ResourceError.fileNotFound(path)
    }

    /// Check if a path matches any of the given extensions (case-insensitive)
    public static func hasExtension(_ path: String, in extensions: Set<String>) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return extensions.contains(ext)
    }

    /// Common image file extensions
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif", "bmp", "gif"
    ]

    /// Common audio file extensions
    public static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "flac", "ogg", "caf"
    ]
}
