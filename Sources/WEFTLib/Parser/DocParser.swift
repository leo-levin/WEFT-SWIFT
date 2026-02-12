// DocParser.swift - Parse documentation comments from WEFT source

import Foundation

/// Documentation for a spindle function
public struct SpindleDoc: Sendable {
    public let name: String
    public let signature: String
    public let description: String
    public let params: [(name: String, desc: String)]
    public let returns: String?
    public let example: String?

    public init(
        name: String,
        signature: String,
        description: String,
        params: [(name: String, desc: String)] = [],
        returns: String? = nil,
        example: String? = nil
    ) {
        self.name = name
        self.signature = signature
        self.description = description
        self.params = params
        self.returns = returns
        self.example = example
    }
}

/// Parser for extracting documentation comments from WEFT source code
public class DocParser {

    /// Parse all spindle documentation from source code
    /// Returns a dictionary mapping spindle name to its documentation
    public func parseDocComments(from source: String) -> [String: SpindleDoc] {
        var docs: [String: SpindleDoc] = [:]
        let lines = source.components(separatedBy: .newlines)

        var docCommentLines: [String] = []
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Collect /// doc comment lines
            if line.hasPrefix("///") {
                docCommentLines.append(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }

            // Check if this line is a spindle definition
            if line.hasPrefix("spindle ") && !docCommentLines.isEmpty {
                if let doc = parseSpindleDoc(from: docCommentLines, spindleLine: line) {
                    docs[doc.name] = doc
                }
            }

            // Reset doc comment buffer for non-doc-comment, non-empty lines
            if !line.isEmpty && !line.hasPrefix("//") {
                docCommentLines = []
            }

            i += 1
        }

        return docs
    }

    /// Parse documentation from collected /// lines and spindle definition line
    private func parseSpindleDoc(from docLines: [String], spindleLine: String) -> SpindleDoc? {
        // Extract spindle name and signature from definition line
        guard let (name, signature) = parseSpindleSignature(spindleLine) else {
            return nil
        }

        var descriptionLines: [String] = []
        var params: [(name: String, desc: String)] = []
        var returns: String? = nil
        var example: String? = nil

        for line in docLines {
            if line.hasPrefix("@param ") {
                // Parse @param name - description
                let paramPart = String(line.dropFirst(7))
                if let dashIndex = paramPart.firstIndex(of: "-") {
                    let paramName = paramPart[..<dashIndex].trimmingCharacters(in: .whitespaces)
                    let paramDesc = paramPart[paramPart.index(after: dashIndex)...].trimmingCharacters(in: .whitespaces)
                    params.append((name: paramName, desc: paramDesc))
                } else if let spaceIndex = paramPart.firstIndex(of: " ") {
                    // Handle "@param name description" without dash
                    let paramName = String(paramPart[..<spaceIndex])
                    let paramDesc = String(paramPart[paramPart.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
                    params.append((name: paramName, desc: paramDesc))
                }
            } else if line.hasPrefix("@returns ") || line.hasPrefix("@return ") {
                let prefix = line.hasPrefix("@returns ") ? "@returns " : "@return "
                returns = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("@example ") {
                example = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else {
                // Regular description line
                descriptionLines.append(line)
            }
        }

        let description = descriptionLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        return SpindleDoc(
            name: name,
            signature: signature,
            description: description,
            params: params,
            returns: returns,
            example: example
        )
    }

    /// Extract name and signature from spindle definition line
    private func parseSpindleSignature(_ line: String) -> (name: String, signature: String)? {
        // Pattern: spindle name(params) {
        // Remove trailing { and whitespace
        var cleaned = line
        if let braceIndex = cleaned.firstIndex(of: "{") {
            cleaned = String(cleaned[..<braceIndex]).trimmingCharacters(in: .whitespaces)
        }

        // Extract name from "spindle name(params)"
        guard cleaned.hasPrefix("spindle ") else { return nil }
        let afterSpindle = String(cleaned.dropFirst(8))

        // Find the opening paren to get the name
        guard let parenIndex = afterSpindle.firstIndex(of: "(") else { return nil }
        let name = String(afterSpindle[..<parenIndex]).trimmingCharacters(in: .whitespaces)

        // Build clean signature
        let signature = "spindle \(afterSpindle)"

        return (name, signature)
    }
}

// MARK: - Builtin Documentation

/// Hardcoded documentation for built-in functions
public struct BuiltinDocs {

    /// All builtin function documentation
    public static let docs: [String: SpindleDoc] = [
        // Math functions
        "sin": SpindleDoc(
            name: "sin",
            signature: "sin(x)",
            description: "Sine function. Returns the sine of x (in radians).",
            params: [("x", "Angle in radians")],
            returns: "Value in range [-1, 1]"
        ),
        "cos": SpindleDoc(
            name: "cos",
            signature: "cos(x)",
            description: "Cosine function. Returns the cosine of x (in radians).",
            params: [("x", "Angle in radians")],
            returns: "Value in range [-1, 1]"
        ),
        "tan": SpindleDoc(
            name: "tan",
            signature: "tan(x)",
            description: "Tangent function. Returns the tangent of x (in radians).",
            params: [("x", "Angle in radians")],
            returns: "Tangent value"
        ),
        "abs": SpindleDoc(
            name: "abs",
            signature: "abs(x)",
            description: "Absolute value. Returns the magnitude of x.",
            params: [("x", "Input value")],
            returns: "Non-negative value"
        ),
        "floor": SpindleDoc(
            name: "floor",
            signature: "floor(x)",
            description: "Floor function. Returns the largest integer not greater than x.",
            params: [("x", "Input value")],
            returns: "Rounded down integer value"
        ),
        "ceil": SpindleDoc(
            name: "ceil",
            signature: "ceil(x)",
            description: "Ceiling function. Returns the smallest integer not less than x.",
            params: [("x", "Input value")],
            returns: "Rounded up integer value"
        ),
        "sqrt": SpindleDoc(
            name: "sqrt",
            signature: "sqrt(x)",
            description: "Square root. Returns the square root of x.",
            params: [("x", "Non-negative input value")],
            returns: "Square root of x"
        ),
        "pow": SpindleDoc(
            name: "pow",
            signature: "pow(base, exp)",
            description: "Power function. Returns base raised to the power of exp.",
            params: [("base", "Base value"), ("exp", "Exponent")],
            returns: "base^exp"
        ),
        // Interpolation functions
        "lerp": SpindleDoc(
            name: "lerp",
            signature: "lerp(a, b, t)",
            description: "Linear interpolation between two values.",
            params: [("a", "Start value"), ("b", "End value"), ("t", "Interpolation factor (0-1)")],
            returns: "Blended value: a + (b - a) * t",
            example: "result.val = lerp(0, 100, 0.5)  // 50"
        ),
        "clamp": SpindleDoc(
            name: "clamp",
            signature: "clamp(x, min, max)",
            description: "Clamp a value to a range.",
            params: [("x", "Value to clamp"), ("min", "Minimum bound"), ("max", "Maximum bound")],
            returns: "Value constrained to [min, max]",
            example: "result.val = clamp(1.5, 0, 1)  // 1.0"
        ),
        "step": SpindleDoc(
            name: "step",
            signature: "step(edge, x)",
            description: "Step function. Returns 0 if x < edge, 1 otherwise.",
            params: [("edge", "Threshold value"), ("x", "Input value")],
            returns: "0.0 or 1.0"
        ),
        "smoothstep": SpindleDoc(
            name: "smoothstep",
            signature: "smoothstep(edge0, edge1, x)",
            description: "Smooth Hermite interpolation between 0 and 1.",
            params: [
                ("edge0", "Lower edge of transition"),
                ("edge1", "Upper edge of transition"),
                ("x", "Input value")
            ],
            returns: "Smooth transition value in [0, 1]",
            example: "result.val = smoothstep(0.4, 0.6, me.x)"
        ),

        // Utility functions
        "min": SpindleDoc(
            name: "min",
            signature: "min(a, b)",
            description: "Returns the smaller of two values.",
            params: [("a", "First value"), ("b", "Second value")],
            returns: "Minimum of a and b"
        ),
        "max": SpindleDoc(
            name: "max",
            signature: "max(a, b)",
            description: "Returns the larger of two values.",
            params: [("a", "First value"), ("b", "Second value")],
            returns: "Maximum of a and b"
        ),
        "fract": SpindleDoc(
            name: "fract",
            signature: "fract(x)",
            description: "Fractional part. Returns x - floor(x).",
            params: [("x", "Input value")],
            returns: "Fractional part in [0, 1)"
        ),
        "mod": SpindleDoc(
            name: "mod",
            signature: "mod(x, y)",
            description: "Modulo operation. Returns x - y * floor(x/y).",
            params: [("x", "Dividend"), ("y", "Divisor")],
            returns: "Remainder of x/y"
        ),
        // WEFT-specific
        "osc": SpindleDoc(
            name: "osc",
            signature: "osc(freq)",
            description: "Sine wave oscillator at given frequency.",
            params: [("freq", "Frequency in Hz")],
            returns: "Sine wave value in [-1, 1]",
            example: "wave.val = osc(440)  // 440Hz sine wave"
        ),
        "cache": SpindleDoc(
            name: "cache",
            signature: "cache(value, historySize, tapIndex, signal)",
            description: "Cache a value with history buffer. Enables feedback effects by accessing previous values.",
            params: [
                ("value", "Current value to cache"),
                ("historySize", "Number of frames/samples to store"),
                ("tapIndex", "Index into history (1 = previous frame)"),
                ("signal", "Update signal (me.t for frames, me.i for samples)")
            ],
            returns: "Value from history at tapIndex",
            example: "trail.val = cache(current.val, 2, 1, me.t)"
        ),
        "key": SpindleDoc(
            name: "key",
            signature: "key(keyCode)",
            description: "Check if a keyboard key is pressed.",
            params: [("keyCode", "macOS virtual key code")],
            returns: "1.0 if pressed, 0.0 otherwise",
            example: "moving.val = key(49)  // Check spacebar"
        ),

        // Resources
        "camera": SpindleDoc(
            name: "camera",
            signature: "camera(x, y)",
            description: "Sample the camera feed at normalized coordinates.",
            params: [("x", "Horizontal position (0-1)"), ("y", "Vertical position (0-1)")],
            returns: "[r, g, b] color values",
            example: "img[r,g,b] = camera(me.x, me.y)"
        ),
        "microphone": SpindleDoc(
            name: "microphone",
            signature: "microphone()",
            description: "Get current audio input from microphone.",
            returns: "[left, right] stereo audio samples",
            example: "audio[l,r] = microphone()"
        ),
        "texture": SpindleDoc(
            name: "texture",
            signature: "texture(texId, x, y)",
            description: "Sample a loaded texture at normalized coordinates.",
            params: [
                ("texId", "Texture ID (from load)"),
                ("x", "Horizontal position (0-1)"),
                ("y", "Vertical position (0-1)")
            ],
            returns: "[r, g, b, a] color values"
        ),
        "load": SpindleDoc(
            name: "load",
            signature: "load(\"path\")",
            description: "Load an image file as a texture.",
            params: [("path", "Path to image file (relative to .weft file)")],
            returns: "Texture ID for use with texture()",
            example: "tex.id = load(\"background.png\")"
        ),
        "sample": SpindleDoc(
            name: "sample",
            signature: "sample(sampleId, index)",
            description: "Read a sample from a loaded audio file.",
            params: [
                ("sampleId", "Sample ID (from load)"),
                ("index", "Sample index")
            ],
            returns: "Audio sample value"
        ),
        "text": SpindleDoc(
            name: "text",
            signature: "text(textId, x, y)",
            description: "Sample rendered text at normalized coordinates.",
            params: [
                ("textId", "Text resource ID"),
                ("x", "Horizontal position (0-1)"),
                ("y", "Vertical position (0-1)")
            ],
            returns: "[r, g, b, a] color values"
        ),
        "mouse": SpindleDoc(
            name: "mouse",
            signature: "mouse()",
            description: "Get current mouse state.",
            returns: "[x, y, down] - normalized position and button state",
            example: "m[x,y,down] = mouse()"
        ),
    ]

    /// Look up documentation for a builtin function
    public static func documentation(for name: String) -> SpindleDoc? {
        return docs[name]
    }
}
