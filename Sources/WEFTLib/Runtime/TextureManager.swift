// TextureManager.swift - Manages loading and caching of textures for WEFT programs

import Foundation
import Metal
import MetalKit

// MARK: - Texture Loading Error

public enum TextureError: Error, LocalizedError {
    case deviceNotAvailable
    case fileNotFound(String)
    case loadFailed(String)
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotAvailable:
            return "Metal device not available"
        case .fileNotFound(let path):
            return "Texture file not found: \(path)"
        case .loadFailed(let message):
            return "Failed to load texture: \(message)"
        case .invalidFormat(let format):
            return "Invalid texture format: \(format)"
        }
    }
}

// MARK: - Resource Path Resolution

/// Shared resource path resolution logic used by TextureManager and SampleManager.
/// Tries: absolute path, relative to source file, .weft-resources dir, CWD.
enum ResourcePathResolver {
    static func resolve(_ path: String, relativeTo sourceFileURL: URL?) throws -> URL {
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

        throw TextureError.fileNotFound(path)
    }
}

// MARK: - Texture Manager

public class TextureManager {
    private let device: MTLDevice
    private let loader: MTKTextureLoader

    /// Cache of loaded textures by resolved path
    private var cache: [String: MTLTexture] = [:]

    /// Textures indexed by resource ID (for shader binding)
    private var textures: [Int: MTLTexture] = [:]

    /// Tracks which resources failed to load and why
    public private(set) var loadErrors: [Int: (path: String, error: TextureError)] = [:]

    public init(device: MTLDevice) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
    }

    /// Load all textures from program resources
    /// - Parameters:
    ///   - resources: Array of file paths from IRProgram.resources
    ///   - sourceFileURL: URL of the .weft source file (for relative path resolution)
    /// - Returns: Dictionary mapping resource ID to loaded texture
    public func loadTextures(
        resources: [String],
        sourceFileURL: URL?
    ) throws -> [Int: MTLTexture] {
        textures = [:]
        loadErrors = [:]

        for (index, path) in resources.enumerated() {
            // Skip non-image resources (audio handled by SampleManager)
            let ext = (path as NSString).pathExtension.lowercased()
            let audioExtensions = ["wav", "aiff", "aif", "mp3", "m4a", "flac", "ogg", "caf"]
            if audioExtensions.contains(ext) {
                continue
            }

            do {
                let texture = try loadTexture(path: path, relativeTo: sourceFileURL)
                textures[index] = texture
            } catch let error as TextureError {
                loadErrors[index] = (path: path, error: error)
                // Create a placeholder texture (1x1 magenta for debugging)
                if let placeholder = createPlaceholderTexture() {
                    textures[index] = placeholder
                }
            } catch {
                loadErrors[index] = (path: path, error: .loadFailed(error.localizedDescription))
                if let placeholder = createPlaceholderTexture() {
                    textures[index] = placeholder
                }
            }
        }

        return textures
    }

    /// Load a single texture from a path
    public func loadTexture(path: String, relativeTo sourceFileURL: URL?) throws -> MTLTexture {
        // Check cache first
        if let cached = cache[path] {
            return cached
        }

        // Resolve path
        let url = try ResourcePathResolver.resolve(path, relativeTo: sourceFileURL)

        // Load texture
        let texture = try loadTextureFromURL(url)

        // Cache by original path
        cache[path] = texture

        return texture
    }

    /// Load a texture from a URL
    private func loadTextureFromURL(_ url: URL) throws -> MTLTexture {
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.shared.rawValue,
            .SRGB: false,
            .generateMipmaps: false
        ]

        do {
            return try loader.newTexture(URL: url, options: options)
        } catch {
            throw TextureError.loadFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Create a 1x1 magenta placeholder texture for missing resources
    private func createPlaceholderTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Magenta color (1, 0, 1, 1)
        var pixels: [UInt8] = [255, 0, 255, 255]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixels,
            bytesPerRow: 4
        )

        return texture
    }
}
