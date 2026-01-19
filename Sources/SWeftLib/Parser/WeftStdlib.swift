// WeftStdlib.swift - Standard library for WEFT language

import Foundation

/// Contains the WEFT standard library source code
/// These spindles are automatically prepended to user code
public enum WeftStdlib {

    /// The standard library source code
    /// Uses #include to pull in the actual stdlib files from the bundled resources
    public static let source = """
// WEFT Standard Library
// This file is automatically prepended to user code when includeStdlib is enabled
#include "core.weft"
"""

    /// URL to the stdlib directory in the bundle (for "View Stdlib" menu)
    public static var directoryURL: URL? {
        Bundle.module.url(forResource: "stdlib", withExtension: nil)
    }
}
