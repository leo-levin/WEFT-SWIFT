// Logger.swift - Consistent logging framework for WEFT

import Foundation
import os.log

// MARK: - Log Level

public enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case none = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var prefix: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .none: return ""
        }
    }
}

// MARK: - Logger

public final class Logger {
    /// Shared singleton instance
    public static let shared = Logger()

    /// Minimum level to log (messages below this level are ignored)
    public var minLevel: LogLevel = .info

    /// Whether to include timestamps in log messages
    public var includeTimestamp: Bool = false

    /// Subsystem-specific log levels (overrides minLevel for specific subsystems)
    private var subsystemLevels: [String: LogLevel] = [:]

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    // MARK: - Configuration

    /// Set log level for a specific subsystem
    public func setLevel(_ level: LogLevel, for subsystem: String) {
        subsystemLevels[subsystem] = level
    }

    /// Get effective log level for a subsystem
    public func effectiveLevel(for subsystem: String) -> LogLevel {
        subsystemLevels[subsystem] ?? minLevel
    }

    // MARK: - Logging Methods

    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        subsystem: String = "WEFT"
    ) {
        guard level >= effectiveLevel(for: subsystem) else { return }

        var output = ""

        if includeTimestamp {
            output += "[\(dateFormatter.string(from: Date()))] "
        }

        output += "[\(level.prefix)] "
        output += "[\(subsystem)] "
        output += message()

        print(output)
    }

    public func debug(_ message: @autoclosure () -> String, subsystem: String = "WEFT") {
        log(.debug, message(), subsystem: subsystem)
    }

    public func info(_ message: @autoclosure () -> String, subsystem: String = "WEFT") {
        log(.info, message(), subsystem: subsystem)
    }

    public func warning(_ message: @autoclosure () -> String, subsystem: String = "WEFT") {
        log(.warning, message(), subsystem: subsystem)
    }

    public func error(_ message: @autoclosure () -> String, subsystem: String = "WEFT") {
        log(.error, message(), subsystem: subsystem)
    }
}

// MARK: - Convenience Global Functions

/// Global logger instance for convenience
public let log = Logger.shared

// MARK: - Subsystem Constants

public enum LogSubsystem {
    public static let coordinator = "Coordinator"
    public static let metal = "Metal"
    public static let audio = "Audio"
    public static let texture = "Texture"
    public static let sample = "Sample"
    public static let text = "Text"
    public static let cache = "Cache"
    public static let camera = "Camera"
    public static let microphone = "Microphone"
    public static let parser = "Parser"
    public static let compiler = "Compiler"
}
