// IRParser.swift - Parse IR from JSON

import Foundation

public enum IRParseError: Error, LocalizedError {
    case invalidJSON(Error)
    case missingField(String)
    case invalidStructure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let error):
            return "Invalid JSON: \(error.localizedDescription)"
        case .missingField(let field):
            return "Missing required field: \(field)"
        case .invalidStructure(let message):
            return "Invalid IR structure: \(message)"
        }
    }
}

public struct IRParser {
    public init() {}

    /// Parse IR program from JSON data
    public func parse(data: Data) throws -> IRProgram {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(IRProgram.self, from: data)
        } catch let decodingError as DecodingError {
            throw IRParseError.invalidJSON(decodingError)
        } catch {
            throw IRParseError.invalidJSON(error)
        }
    }

    /// Parse IR program from JSON string
    public func parse(json: String) throws -> IRProgram {
        guard let data = json.data(using: .utf8) else {
            throw IRParseError.invalidStructure("Could not convert string to UTF-8 data")
        }
        return try parse(data: data)
    }

    /// Parse IR program from file URL
    public func parse(url: URL) throws -> IRProgram {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    /// Parse IR program from file path
    public func parse(path: String) throws -> IRProgram {
        let url = URL(fileURLWithPath: path)
        return try parse(url: url)
    }
}

// MARK: - JSON Structure Helpers

/// Alternative parsing for more complex JSON structures
extension IRParser {
    /// Parse from a dictionary representation (for manual JSON handling)
    public func parse(dictionary: [String: Any]) throws -> IRProgram {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try parse(data: data)
    }
}
