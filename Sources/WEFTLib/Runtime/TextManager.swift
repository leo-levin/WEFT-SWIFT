// TextManager.swift - Manages rendering text strings to Metal textures

import Foundation
import Metal
import CoreText
import CoreGraphics

#if os(macOS)
import AppKit
#endif

// MARK: - Text Rendering Error

public enum TextRenderError: Error, LocalizedError {
    case contextCreationFailed
    case textureCreationFailed

    public var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "Could not create graphics context for text rendering"
        case .textureCreationFailed:
            return "Could not create Metal texture for text"
        }
    }
}

// MARK: - Text Manager

/// Renders text strings to Metal textures for the text() builtin.
/// Uses Core Text to render text with default font settings.
public class TextManager {
    private let device: MTLDevice

    /// Rendered text textures by resource ID
    private var textures: [Int: MTLTexture] = [:]

    /// Default font for text rendering
    private var font: CTFont

    /// Texture dimensions (max width/height for rendered text)
    public var maxTextureWidth: Int = 1024
    public var maxTextureHeight: Int = 256

    public init(device: MTLDevice) {
        self.device = device
        // Default font: Helvetica 64pt for good quality at various scales
        self.font = CTFontCreateWithName("Helvetica" as CFString, 64.0, nil)
    }

    /// Set the font for text rendering
    public func setFont(name: String, size: CGFloat) {
        self.font = CTFontCreateWithName(name as CFString, size, nil)
    }

    /// Render all text strings to textures
    /// - Parameter textResources: Array of text strings from IRProgram.textResources
    /// - Returns: Dictionary mapping resource ID to rendered texture
    public func renderTexts(_ textResources: [String]) throws -> [Int: MTLTexture] {
        textures = [:]

        for (index, text) in textResources.enumerated() {
            let texture = try renderText(text)
            textures[index] = texture
        }

        return textures
    }

    /// Render a single text string to a Metal texture
    /// - Parameter text: The text string to render
    /// - Returns: Metal texture containing the rendered text (R8 format - alpha mask)
    private func renderText(_ text: String) throws -> MTLTexture {
        // Create attributed string with white text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor.white
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)

        // Create CTLine to measure text
        let line = CTLineCreateWithAttributedString(attrString as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let lineHeight = ascent + descent

        // Calculate texture dimensions with padding
        let padding: CGFloat = 4
        var texWidth = Int(ceil(lineWidth)) + Int(padding * 2)
        var texHeight = Int(ceil(lineHeight)) + Int(padding * 2)

        // Clamp to max dimensions
        texWidth = min(texWidth, maxTextureWidth)
        texHeight = min(texHeight, maxTextureHeight)

        // Ensure minimum size
        texWidth = max(texWidth, 1)
        texHeight = max(texHeight, 1)

        // Create bitmap context (grayscale for alpha mask)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = texWidth
        var bitmapData = [UInt8](repeating: 0, count: texWidth * texHeight)

        guard let context = CGContext(
            data: &bitmapData,
            width: texWidth,
            height: texHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw TextRenderError.contextCreationFailed
        }

        // Clear to black (transparent in alpha mask)
        context.setFillColor(gray: 0.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: texWidth, height: texHeight))

        // Draw text in white
        context.setFillColor(gray: 1.0, alpha: 1.0)

        // Position text (Core Graphics has origin at bottom-left, flip Y)
        // Text baseline at descent + padding from bottom
        context.textPosition = CGPoint(x: padding, y: descent + padding)
        CTLineDraw(line, context)

        // Create Metal texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,  // Single channel for alpha mask
            width: texWidth,
            height: texHeight,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TextRenderError.textureCreationFailed
        }

        // Copy bitmap data to texture
        texture.replace(
            region: MTLRegionMake2D(0, 0, texWidth, texHeight),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )

        return texture
    }
}
