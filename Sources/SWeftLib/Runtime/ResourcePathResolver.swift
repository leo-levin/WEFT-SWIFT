// ResourcePathResolver.swift - Shared path resolution for resource managers

import Foundation

/// Shared utility for resolving resource paths in WEFT programs.
/// Used by TextureManager, SampleManager, and other resource loaders.
public enum ResourcePathResolver {
    /// Resolve a resource path to a URL.
    ///
    /// Resolution order:
    /// 1. Absolute path (starting with / or ~)
    /// 2. Relative to source file directory
    /// 3. In .weft-resources folder next to source file
    /// 4. Relative to current working directory
    ///
    /// - Parameters:
    ///   - path: The resource path (can be relative or absolute)
    ///   - sourceFileURL: Optional URL of the source .weft file
    /// - Returns: Resolved file URL, or nil if not found
    public static func resolve(_ path: String, relativeTo sourceFileURL: URL?) -> URL? {
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

        return nil
    }
}
