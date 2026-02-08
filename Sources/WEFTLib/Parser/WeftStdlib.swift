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
#include "std_core.weft"
"""

    /// URL to the stdlib directory in the bundle (for "View Stdlib" menu)
    public static var directoryURL: URL? {
        findStdlibURL()
    }

    /// Find stdlib URL - checks multiple locations for .app bundle compatibility
    static func findStdlibURL() -> URL? {
        // Try the resource bundle inside .app (for distributed app)
        if let resourceBundle = Bundle.main.url(forResource: "WEFT_WEFTLib", withExtension: "bundle"),
           let bundle = Bundle(url: resourceBundle),
           let url = bundle.url(forResource: "stdlib", withExtension: nil) {
            return url
        }

        // Try Bundle.main directly (for some bundle configurations)
        if let url = Bundle.main.url(forResource: "stdlib", withExtension: nil) {
            return url
        }

        // For SPM development builds, try Bundle.module
        // Only safe to access if we're not in an app bundle (Bundle.main has no bundlePath ending in .app)
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            if let url = Bundle.module.url(forResource: "stdlib", withExtension: nil) {
                return url
            }
        }

        return nil
    }
}
