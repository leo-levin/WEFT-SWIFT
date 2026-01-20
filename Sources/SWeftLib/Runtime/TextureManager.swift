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
    case pickerCancelled

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
        case .pickerCancelled:
            return "File picker was cancelled"
        }
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

    /// Callback for when a file picker is needed (set by UI layer)
    public var onPickerNeeded: ((_ forResourceId: Int, _ fileTypes: [String]) async -> URL?)?

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

        for (index, path) in resources.enumerated() {
            do {
                let texture = try loadTexture(path: path, relativeTo: sourceFileURL)
                textures[index] = texture
                print("TextureManager: Loaded texture \(index) from '\(path)'")
            } catch {
                print("TextureManager: Failed to load texture \(index) from '\(path)': \(error)")
                // Create a placeholder texture (1x1 magenta for debugging)
                if let placeholder = createPlaceholderTexture() {
                    textures[index] = placeholder
                }
            }
        }

        return textures
    }

    /// Load a single texture from a path
    /// - Parameters:
    ///   - path: File path (can be relative or absolute)
    ///   - relativeTo: Base URL for relative path resolution
    /// - Returns: Loaded Metal texture
    public func loadTexture(path: String, relativeTo sourceFileURL: URL?) throws -> MTLTexture {
        // Check cache first
        if let cached = cache[path] {
            return cached
        }

        // Resolve path
        let url = try resolveTexturePath(path, relativeTo: sourceFileURL)

        // Load texture
        let texture = try loadTextureFromURL(url)

        // Cache by original path
        cache[path] = texture

        return texture
    }

    /// Resolve a texture path to a URL
    private func resolveTexturePath(_ path: String, relativeTo sourceFileURL: URL?) throws -> URL {
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

    /// Load a texture from a URL
    private func loadTextureFromURL(_ url: URL) throws -> MTLTexture {
        // Configure texture loading options
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.shared.rawValue,
            .SRGB: false,  // Keep linear color space
            .generateMipmaps: false
        ]

        do {
            let texture = try loader.newTexture(URL: url, options: options)
            return texture
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

    /// Get a loaded texture by resource ID
    public func getTexture(at index: Int) -> MTLTexture? {
        return textures[index]
    }

    /// Get all loaded textures
    public func getAllTextures() -> [Int: MTLTexture] {
        return textures
    }

    /// Get the count of loaded textures
    public var textureCount: Int {
        return textures.count
    }

    /// Clear all cached textures
    public func clearCache() {
        cache.removeAll()
        textures.removeAll()
    }
}

// MARK: - Texture Manager Extension for Async Loading

extension TextureManager {
    /// Load texture with file picker fallback for missing files
    /// - Parameters:
    ///   - path: File path (can be empty to trigger picker immediately)
    ///   - resourceId: The resource ID for this texture
    ///   - sourceFileURL: URL of the .weft source file
    /// - Returns: Loaded Metal texture
    public func loadTextureWithPicker(
        path: String,
        resourceId: Int,
        sourceFileURL: URL?
    ) async throws -> MTLTexture {
        // If path is empty or just whitespace, trigger picker
        if path.trimmingCharacters(in: .whitespaces).isEmpty {
            return try await requestTextureFromPicker(resourceId: resourceId)
        }

        // Try to load from path
        do {
            return try loadTexture(path: path, relativeTo: sourceFileURL)
        } catch TextureError.fileNotFound {
            // File not found - try picker if available
            return try await requestTextureFromPicker(resourceId: resourceId)
        }
    }

    /// Request a texture via file picker
    private func requestTextureFromPicker(resourceId: Int) async throws -> MTLTexture {
        guard let picker = onPickerNeeded else {
            throw TextureError.fileNotFound("(no picker available)")
        }

        let fileTypes = ["png", "jpg", "jpeg", "heic", "tiff", "bmp", "gif"]

        guard let url = await picker(resourceId, fileTypes) else {
            throw TextureError.pickerCancelled
        }

        return try loadTextureFromURL(url)
    }
}
