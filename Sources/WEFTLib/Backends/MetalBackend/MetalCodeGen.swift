// MetalCodeGen.swift - Generate Metal Shading Language from IR

import Foundation

// MARK: - Metal Code Generator

public class MetalCodeGen {
    private let program: IRProgram
    private let swatch: Swatch

    /// Cache descriptors for visual domain (provided by CacheManager)
    private var cacheDescriptors: [CacheNodeDescriptor] = []

    /// Track which cache we're currently generating valueExpr for (to handle self-references)
    private var currentlyGeneratingCacheIndex: Int? = nil

    /// Base texture index for loaded textures (camera=1, audio=2, textures start at 3)
    public static let textureBaseIndex = 3

    /// Base texture index for text textures (text textures start at 100)
    public static let textTextureBaseIndex = 100

    /// Base texture index for scope textures (layout previews)
    public static let scopeTextureBaseIndex = 50

    /// Scoped bundles to render as layout previews (topologically ordered)
    private let scopedBundles: [String]

    /// Pre-computed variable names for scoped bundles (CSE): bundleName -> [Metal var names per strand]
    private var precomputedVars: [String: [String]] = [:]

    /// Number of scope textures needed (exposed for MetalBackend)
    public private(set) var scopeTextureCount: Int = 0

    /// Bundle names corresponding to each scope texture (exposed for MetalBackend)
    public private(set) var scopedBundleNames: [String] = []

    /// Cross-domain inputs: bundleName -> ordered list of strand names
    private let crossDomainInputs: [String: [String]]

    /// Pre-computed mapping: "bundle.strand" -> index into crossDomainData buffer
    public private(set) var crossDomainSlotMap: [String: Int] = [:]

    /// Total number of cross-domain float slots
    public private(set) var crossDomainSlotCount: Int = 0

    /// Intermediate textures needed for heavy remap expressions.
    /// Each entry is a base expression (pre-getDirectExpression) that will be rendered
    /// to an r32Float texture, then sampled at remapped UV coordinates.
    private var intermediateTextures: [(id: String, baseExpr: IRExpr)] = []
    private var currentlyGeneratingIntermediateIndex: Int? = nil

    /// Tracks bundles currently being inlined to detect circular references
    private var inliningBundles: Set<String> = []

    /// Recursion depth counter to guard against stack overflow
    private var expressionDepth: Int = 0
    private static let maxExpressionDepth = 512

    /// Base texture index for intermediate textures (must be <= 127 for Metal)
    public static let intermediateTextureBaseIndex = 115

    /// Number of intermediate textures needed (exposed for MetalBackend)
    public var intermediateTextureCount: Int { intermediateTextures.count }

    public init(program: IRProgram, swatch: Swatch, cacheDescriptors: [CacheNodeDescriptor] = [], crossDomainInputs: [String: [String]] = [:], scopedBundles: [String] = []) {
        self.program = program
        self.swatch = swatch
        self.crossDomainInputs = crossDomainInputs
        self.scopedBundles = scopedBundles
        // Filter to only visual domain caches
        self.cacheDescriptors = cacheDescriptors.filter { $0.domain == .visual }

        // Build slot map for cross-domain inputs
        var slot = 0
        for (bundle, strands) in crossDomainInputs.sorted(by: { $0.key < $1.key }) {
            for strand in strands {
                crossDomainSlotMap["\(bundle).\(strand)"] = slot
                slot += 1
            }
        }
        crossDomainSlotCount = slot
    }

    /// Get set of texture resource IDs used in this swatch
    public func usedTextureIds() -> Set<Int> {
        var textureIds = Set<Int>()

        for bundleName in swatch.bundles {
            if let bundle = program.bundles[bundleName] {
                for strand in bundle.strands {
                    collectTextureIds(from: strand.expr, into: &textureIds)
                }
            }
        }

        return textureIds
    }

    /// Recursively collect texture resource IDs from an expression
    private func collectTextureIds(from expr: IRExpr, into textureIds: inout Set<Int>) {
        if case .builtin(let name, let args) = expr, name == "texture",
           args.count >= 1, case .num(let id) = args[0] {
            textureIds.insert(Int(id))
        }
        expr.forEachChild { collectTextureIds(from: $0, into: &textureIds) }
    }

    /// Get set of text resource IDs used in this swatch
    public func usedTextIds() -> Set<Int> {
        var textIds = Set<Int>()

        for bundleName in swatch.bundles {
            if let bundle = program.bundles[bundleName] {
                for strand in bundle.strands {
                    collectTextIds(from: strand.expr, into: &textIds)
                }
            }
        }

        return textIds
    }

    /// Recursively collect text resource IDs from an expression
    private func collectTextIds(from expr: IRExpr, into textIds: inout Set<Int>) {
        if case .builtin(let name, let args) = expr, name == "text",
           args.count >= 1, case .num(let id) = args[0] {
            textIds.insert(Int(id))
        }
        expr.forEachChild { collectTextIds(from: $0, into: &textIds) }
    }

    /// Generate complete Metal shader source
    public func generate() throws -> String {
        var code = """
        #include <metal_stdlib>
        using namespace metal;

        // Uniforms passed from CPU
        struct Uniforms {
            float time;
            float width;
            float height;
            float mouseX;
            float mouseY;
            float mouseDown;
            float _padding;
        };

        """

        // Get output bundle name from bindings
        let outputBundleName = MetalBackend.bindings.compactMap { binding -> String? in
            if case .output(let output) = binding { return output.bundleName }
            return nil
        }.first

        // Generate compute kernel for output
        if let bundleName = outputBundleName, swatch.bundles.contains(bundleName) {
            // Pre-scan for heavy remaps that need intermediate textures
            scanForHeavyRemaps(bundleName: bundleName)

            // Generate intermediate kernels first (one per heavy remap base)
            for (i, intermediate) in intermediateTextures.enumerated() {
                code += try generateIntermediateKernel(index: i, baseExpr: intermediate.baseExpr)
            }

            code += try generateDisplayKernel(bundleName: bundleName)
        }

        return code
    }

    /// Get set of used input builtin names from this swatch
    public func usedInputs() -> Set<String> {
        // Get input binding names from MetalBackend
        let inputNames = Set(MetalBackend.bindings.compactMap { binding -> String? in
            if case .input(let input) = binding { return input.builtinName }
            return nil
        })

        // Collect all builtins used in the swatch's bundles, following bundle references
        var usedBuiltins = Set<String>()
        var visitedBundles = Set<String>()

        func collectBuiltins(from expr: IRExpr) {
            if case .builtin(let name, _) = expr {
                usedBuiltins.insert(name)
            }
            if case .index(let bundle, _) = expr,
               bundle != "me", !visitedBundles.contains(bundle),
               swatch.bundles.contains(bundle) {
                visitedBundles.insert(bundle)
                if let targetBundle = program.bundles[bundle] {
                    for strand in targetBundle.strands {
                        collectBuiltins(from: strand.expr)
                    }
                }
            }
            expr.forEachChild { collectBuiltins(from: $0) }
        }

        for bundleName in swatch.bundles {
            visitedBundles.insert(bundleName)
            if let bundle = program.bundles[bundleName] {
                for strand in bundle.strands {
                    collectBuiltins(from: strand.expr)
                }
            }
        }

        // Start with intersection of input bindings and used builtins
        var result = usedBuiltins.intersection(inputNames)

        // Also include universal input builtins (mouse, key)
        let universalInputs: Set<String> = ["mouse", "key"]
        result.formUnion(usedBuiltins.intersection(universalInputs))

        return result
    }

    /// Check if program uses cache
    public func usesCache() -> Bool {
        return !cacheDescriptors.isEmpty
    }

    /// Get the number of cache buffer pairs needed
    public func cacheBufferCount() -> Int {
        return cacheDescriptors.count * 2  // history + signal per cache
    }

    // MARK: - Heavy Remap Detection & Intermediate Texture Generation

    /// Scan the display bundle and all transitively-referenced bundles for .remap nodes
    /// whose base resolves to a heavy expression (containing spindle .call nodes).
    /// Collect unique bases that need intermediate textures.
    private func scanForHeavyRemaps(bundleName: String) {
        var seen = Set<String>()
        var visitedBundles = Set<String>()
        scanBundleForHeavyRemaps(bundleName, seen: &seen, visitedBundles: &visitedBundles)
    }

    private func scanBundleForHeavyRemaps(_ bundleName: String, seen: inout Set<String>, visitedBundles: inout Set<String>) {
        guard !visitedBundles.contains(bundleName) else { return }
        visitedBundles.insert(bundleName)
        guard let bundle = program.bundles[bundleName] else { return }

        for strand in bundle.strands {
            collectHeavyRemapBases(from: strand.expr, seen: &seen, visitedBundles: &visitedBundles)
        }
    }

    private func collectHeavyRemapBases(from expr: IRExpr, seen: inout Set<String>, visitedBundles: inout Set<String>) {
        if case .remap(let base, _) = expr {
            let directExpr = IRTransformations.getDirectExpression(base, program: program)
            if directExpr.isHeavyExpression() {
                let key = base.description
                if !seen.contains(key) {
                    seen.insert(key)
                    intermediateTextures.append((
                        id: "intermediate_\(intermediateTextures.count)",
                        baseExpr: base
                    ))
                }
            }
        }
        // Follow .index references into other bundles so we find remaps
        // deeper in the dependency chain (not just in the display bundle).
        if case .index(let bundle, _) = expr, bundle != "me" {
            scanBundleForHeavyRemaps(bundle, seen: &seen, visitedBundles: &visitedBundles)
        }
        expr.forEachChild { collectHeavyRemapBases(from: $0, seen: &seen, visitedBundles: &visitedBundles) }
    }

    /// Generate an intermediate compute kernel that evaluates one heavy expression
    /// and writes to an r32Float texture.
    private func generateIntermediateKernel(index: Int, baseExpr: IRExpr) throws -> String {
        // Resolve the base to its direct expression (inline spindle calls etc.)
        let directExpr = IRTransformations.getDirectExpression(baseExpr, program: program)
        currentlyGeneratingIntermediateIndex = index
        let valueCode = try generateExpression(directExpr)
        currentlyGeneratingIntermediateIndex = nil

        // Build params: same resource bindings as the display kernel needs
        let usedInputNames = usedInputs()
        let usedTextures = usedTextureIds()
        let usedTexts = usedTextIds()
        var extraParams = ""
        var needsSampler = false

        for binding in MetalBackend.bindings {
            if case .input(let input) = binding, usedInputNames.contains(input.builtinName) {
                if let shaderParam = input.shaderParam {
                    extraParams += "\n    \(shaderParam),"
                    needsSampler = true
                }
            }
        }

        for textureId in usedTextures.sorted() {
            let textureIndex = MetalCodeGen.textureBaseIndex + textureId
            extraParams += "\n    texture2d<float, access::sample> texture\(textureId) [[texture(\(textureIndex))]],"
            needsSampler = true
        }

        for textId in usedTexts.sorted() {
            let textureIndex = MetalCodeGen.textTextureBaseIndex + textId
            extraParams += "\n    texture2d<float, access::sample> textTexture\(textId) [[texture(\(textureIndex))]],"
            needsSampler = true
        }

        // Add prior intermediate texture params (for chained heavy remaps like edges(edges(...)))
        for priorIdx in 0..<index {
            let texIndex = MetalCodeGen.intermediateTextureBaseIndex + priorIdx
            extraParams += "\n    texture2d<float, access::sample> intermediateTex\(priorIdx) [[texture(\(texIndex))]],"
            needsSampler = true
        }

        if needsSampler {
            extraParams += "\n    sampler textureSampler [[sampler(0)]],"
        }

        for (i, _) in cacheDescriptors.enumerated() {
            let historyIdx = CacheNodeDescriptor.shaderHistoryBufferIndex(cachePosition: i)
            let signalIdx = CacheNodeDescriptor.shaderSignalBufferIndex(cachePosition: i)
            extraParams += "\n    device float* cache\(i)_history [[buffer(\(historyIdx))]],"
            extraParams += "\n    device float* cache\(i)_signal [[buffer(\(signalIdx))]],"
        }

        if usedInputNames.contains("key") {
            extraParams += "\n    device float* keyStates [[buffer(1)]],"
        }

        if crossDomainSlotCount > 0 {
            extraParams += "\n    device float* crossDomainData [[buffer(30)]],"
        }

        // Text helper variables (needed if expression uses text())
        var textHelpers = ""
        for textId in usedTexts.sorted() {
            textHelpers += """
                float textTex\(textId)_w = float(textTexture\(textId).get_width());
                float textTex\(textId)_h = float(textTexture\(textId).get_height());
                float textTex\(textId)_aspect = textTex\(textId)_w / textTex\(textId)_h;

            """
        }

        // Cache helper variables (READ-ONLY in intermediate kernels to avoid double-ticking).
        // Only declare cache*_result by reading from history buffers; the display kernel
        // handles the actual tick logic.
        var cacheHelpers = ""
        if !cacheDescriptors.isEmpty {
            cacheHelpers = """

                // Pixel index for cache buffer access
                uint pixelIndex = gid.y * uint(uniforms.width) + gid.x;

            """

            for (cacheIdx, descriptor) in cacheDescriptors.enumerated() {
                let historySize = descriptor.historySize
                let tapIndex = min(descriptor.tapIndex, historySize - 1)

                cacheHelpers += """

                    // Cache \(cacheIdx): \(descriptor.id) (read-only)
                    uint cache\(cacheIdx)_historyBase = pixelIndex * \(historySize);
                    float cache\(cacheIdx)_result = cache\(cacheIdx)_history[cache\(cacheIdx)_historyBase + \(tapIndex)];

                """
            }
        }

        return """
        kernel void intermediateKernel\(index)(
            texture2d<float, access::write> output [[texture(0)]],\(extraParams)
            constant Uniforms& uniforms [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            float x = float(gid.x) / uniforms.width;
            float y = float(gid.y) / uniforms.height;
            float t = uniforms.time;
            float w = uniforms.width;
            float h = uniforms.height;
            \(textHelpers)\(cacheHelpers)
            float value = \(valueCode);
            output.write(float4(value, 0.0, 0.0, 1.0), gid);
        }

        """
    }

    /// Generate display compute kernel
    private func generateDisplayKernel(bundleName: String) throws -> String {
        guard let displayBundle = program.bundles[bundleName] else {
            throw BackendError.missingResource("\(bundleName) bundle not found")
        }

        // Build shader params from used input bindings
        let usedInputNames = usedInputs()
        let usedTextures = usedTextureIds()
        var extraParams = ""
        var needsSampler = false

        for binding in MetalBackend.bindings {
            if case .input(let input) = binding, usedInputNames.contains(input.builtinName) {
                if let shaderParam = input.shaderParam {
                    extraParams += "\n    \(shaderParam),"
                    needsSampler = true
                }
            }
        }

        // Add texture parameters for loaded textures
        for textureId in usedTextures.sorted() {
            let textureIndex = MetalCodeGen.textureBaseIndex + textureId
            extraParams += "\n    texture2d<float, access::sample> texture\(textureId) [[texture(\(textureIndex))]],"
            needsSampler = true
        }

        // Add texture parameters for text textures
        let usedTexts = usedTextIds()
        for textId in usedTexts.sorted() {
            let textureIndex = MetalCodeGen.textTextureBaseIndex + textId
            extraParams += "\n    texture2d<float, access::sample> textTexture\(textId) [[texture(\(textureIndex))]],"
            needsSampler = true
        }

        // Generate helper code for text texture dimensions/aspect ratios
        var textHelpers = ""
        for textId in usedTexts.sorted() {
            textHelpers += """
                float textTex\(textId)_w = float(textTexture\(textId).get_width());
                float textTex\(textId)_h = float(textTexture\(textId).get_height());
                float textTex\(textId)_aspect = textTex\(textId)_w / textTex\(textId)_h;

            """
        }

        // Add intermediate texture parameters for heavy remap expressions
        for (i, _) in intermediateTextures.enumerated() {
            let texIndex = MetalCodeGen.intermediateTextureBaseIndex + i
            extraParams += "\n    texture2d<float, access::sample> intermediateTex\(i) [[texture(\(texIndex))]],"
            needsSampler = true
        }

        // Add scope texture parameters for layout previews
        let validScopedBundles = scopedBundles.filter { $0 != bundleName && swatch.bundles.contains($0) && program.bundles[$0] != nil }
        for (i, _) in validScopedBundles.enumerated() {
            let texIndex = MetalCodeGen.scopeTextureBaseIndex + i
            extraParams += "\n    texture2d<float, access::write> scopeTex\(i) [[texture(\(texIndex))]],"
        }
        scopeTextureCount = validScopedBundles.count
        scopedBundleNames = validScopedBundles

        if needsSampler {
            extraParams += "\n    sampler textureSampler [[sampler(0)]],"
        }

        // Add cache buffer parameters
        for (i, _) in cacheDescriptors.enumerated() {
            let historyIdx = CacheNodeDescriptor.shaderHistoryBufferIndex(cachePosition: i)
            let signalIdx = CacheNodeDescriptor.shaderSignalBufferIndex(cachePosition: i)
            extraParams += "\n    device float* cache\(i)_history [[buffer(\(historyIdx))]],"
            extraParams += "\n    device float* cache\(i)_signal [[buffer(\(signalIdx))]],"
        }

        // Add key state buffer parameter if key() builtin is used
        if usedInputNames.contains("key") {
            extraParams += "\n    device float* keyStates [[buffer(1)]],"
        }

        // Add cross-domain data buffer parameter
        if crossDomainSlotCount > 0 {
            extraParams += "\n    device float* crossDomainData [[buffer(30)]],"
        }

        // Generate cache helper code if needed
        var cacheHelpers = ""
        if !cacheDescriptors.isEmpty {
            cacheHelpers = """

                // Pixel index for cache buffer access
                uint pixelIndex = gid.y * uint(uniforms.width) + gid.x;

            """

            // Pre-compute all cache operations as separate statements (MSL doesn't support lambdas)
            for (cacheIdx, descriptor) in cacheDescriptors.enumerated() {
                // Track which cache we're generating so self-references return buffer reads
                currentlyGeneratingCacheIndex = cacheIdx
                let valueCode = try generateExpression(descriptor.valueExpr)
                currentlyGeneratingCacheIndex = nil
                let signalCode = try generateExpression(descriptor.signalExpr)
                let historySize = descriptor.historySize
                let tapIndex = min(descriptor.tapIndex, historySize - 1)

                cacheHelpers += """

                    // Cache \(cacheIdx): \(descriptor.id)
                    float cache\(cacheIdx)_value = \(valueCode);
                    float cache\(cacheIdx)_signal_val = \(signalCode);
                    uint cache\(cacheIdx)_historyBase = pixelIndex * \(historySize);
                    float cache\(cacheIdx)_prevSignal = cache\(cacheIdx)_signal[pixelIndex];
                    bool cache\(cacheIdx)_shouldTick = isnan(cache\(cacheIdx)_prevSignal) || cache\(cacheIdx)_prevSignal != cache\(cacheIdx)_signal_val;
                    if (cache\(cacheIdx)_shouldTick) {
                        cache\(cacheIdx)_signal[pixelIndex] = cache\(cacheIdx)_signal_val;
                        for (int j = \(historySize - 1); j > 0; j--) {
                            cache\(cacheIdx)_history[cache\(cacheIdx)_historyBase + j] = cache\(cacheIdx)_history[cache\(cacheIdx)_historyBase + j - 1];
                        }
                        cache\(cacheIdx)_history[cache\(cacheIdx)_historyBase] = cache\(cacheIdx)_value;
                    }
                    float cache\(cacheIdx)_result = cache\(cacheIdx)_history[cache\(cacheIdx)_historyBase + \(tapIndex)];

                """
            }
        }

        // Generate scope preamble: pre-compute scoped bundle values and write to scope textures
        var scopePreamble = ""
        for (scopeIdx, scopeBundleName) in validScopedBundles.enumerated() {
            guard let scopeBundle = program.bundles[scopeBundleName] else { continue }
            let safeName = sanitizeName(scopeBundleName)
            var varNames: [String] = []

            scopePreamble += "\n            // Scope: \(scopeBundleName)\n"
            for strand in scopeBundle.strands.sorted(by: { $0.index < $1.index }) {
                let varName = "scope_\(safeName)_\(sanitizeName(strand.name))"
                let exprCode = try generateExpression(strand.expr)
                scopePreamble += "            float \(varName) = \(exprCode);\n"
                varNames.append(varName)
            }

            // Register for CSE before generating further expressions
            precomputedVars[scopeBundleName] = varNames

            // Write to scope texture (pack up to 4 strands into rgba)
            let channels = ["r", "g", "b", "a"]
            var components: [String] = []
            for (i, varName) in varNames.prefix(4).enumerated() {
                _ = channels[i]
                components.append(varName)
            }
            // Pad missing color channels with 0.0, alpha with 1.0 (opaque)
            while components.count < 3 {
                components.append("0.0")
            }
            if components.count < 4 {
                components.append("1.0")
            }
            scopePreamble += "            scopeTex\(scopeIdx).write(float4(\(components.joined(separator: ", "))), gid);\n"
        }

        // NOW generate color expressions (after scope preamble populates precomputedVars for CSE)
        var colorExprs: [String] = []
        for strand in displayBundle.strands.sorted(by: { $0.index < $1.index }) {
            let expr = try generateExpression(strand.expr)
            colorExprs.append(expr)
        }

        // Pad to 3 channels if needed
        while colorExprs.count < 3 {
            colorExprs.append("0.0")
        }

        return """
        kernel void displayKernel(
            texture2d<float, access::write> output [[texture(0)]],\(extraParams)
            constant Uniforms& uniforms [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            float x = float(gid.x) / uniforms.width;
            float y = float(gid.y) / uniforms.height;
            float t = uniforms.time;
            float w = uniforms.width;
            float h = uniforms.height;
            \(textHelpers)\(cacheHelpers)\(scopePreamble)
            float r = \(colorExprs[0]);
            float g = \(colorExprs[1]);
            float b = \(colorExprs.count > 2 ? colorExprs[2] : "0.0");

            output.write(float4(r, g, b, 1.0), gid);
        }
        """
    }

    /// Generate Metal expression from IR expression
    public func generateExpression(_ expr: IRExpr) throws -> String {
        expressionDepth += 1
        defer { expressionDepth -= 1 }

        guard expressionDepth <= Self.maxExpressionDepth else {
            throw BackendError.unsupportedExpression(
                "Expression nested too deeply (\(expressionDepth) levels) — possible circular bundle reference")
        }

        switch expr {
        case .num(let value):
            return formatNumber(value)

        case .param(let name):
            // Coordinate parameters
            return name

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                // Access coordinate: me.x, me.y, me.t, etc.
                if case .param(let field) = indexExpr {
                    return field
                }
                throw BackendError.unsupportedExpression("Dynamic me index")
            }

            // CSE: if this bundle has pre-computed scope variables, return the variable name
            if let varNames = precomputedVars[bundle] {
                let strandIdx: Int?
                if case .num(let idx) = indexExpr {
                    strandIdx = Int(idx)
                } else if case .param(let field) = indexExpr,
                          let targetBundle = program.bundles[bundle],
                          let strand = targetBundle.strands.first(where: { $0.name == field }) {
                    strandIdx = strand.index
                } else {
                    strandIdx = nil
                }
                if let idx = strandIdx, idx < varNames.count {
                    return varNames[idx]
                }
            }

            // Check if this index refers to a cache location - return precomputed result
            let cacheKey: String
            if case .param(let field) = indexExpr {
                cacheKey = "\(bundle).\(field)"
            } else if case .num(let idx) = indexExpr {
                cacheKey = "\(bundle).\(Int(idx))"
            } else {
                cacheKey = ""
            }

            // Look for matching cache descriptor with self-reference - return the precomputed result
            // to break the cycle. For caches WITHOUT self-reference, let the expression expand normally.
            if !cacheKey.isEmpty {
                for (cacheIndex, descriptor) in cacheDescriptors.enumerated() {
                    // Only use cache_result shortcut for self-referential caches (cycle breaking)
                    guard descriptor.hasSelfReference else { continue }

                    let descKey1 = "\(descriptor.bundleName).\(descriptor.strandIndex)"
                    // Also check by strand name
                    if let targetBundle = program.bundles[descriptor.bundleName],
                       let strand = targetBundle.strands.first(where: { $0.index == descriptor.strandIndex }) {
                        let descKey2 = "\(descriptor.bundleName).\(strand.name)"
                        if cacheKey == descKey1 || cacheKey == descKey2 {
                            // If we're generating this cache's valueExpr, DON'T return cache_result
                            // (it's not defined yet). Instead, fall through to expand the strand.
                            // The strand's expression contains the cache builtin, which will be
                            // handled by generateCacheAccess with the self-reference check.
                            if let currentIdx = currentlyGeneratingCacheIndex, currentIdx == cacheIndex {
                                // Fall through to expand the strand expression
                                break
                            }
                            // Reference to a cache output - return the precomputed result
                            return "cache\(cacheIndex)_result"
                        }
                    }
                }
            }

            // Access another bundle's strand
            if let targetBundle = program.bundles[bundle] {
                // Check if the referenced bundle is in this swatch — if not, it's cross-domain
                if !swatch.bundles.contains(bundle) {
                    // Try cross-domain buffer read
                    if case .param(let field) = indexExpr,
                       let slot = crossDomainSlotMap["\(bundle).\(field)"] {
                        return "crossDomainData[\(slot)]"
                    }
                    if case .num(let idx) = indexExpr,
                       let strands = crossDomainInputs[bundle] {
                        let i = Int(idx)
                        if i < strands.count,
                           let slot = crossDomainSlotMap["\(bundle).\(strands[i])"] {
                            return "crossDomainData[\(slot)]"
                        }
                    }
                    throw BackendError.unsupportedExpression(
                        "Cannot use bundle '\(bundle)' in display — no cross-domain buffer available"
                    )
                }

                // Detect circular bundle references before inlining
                guard !inliningBundles.contains(bundle) else {
                    throw BackendError.unsupportedExpression(
                        "Circular reference: bundle '\(bundle)' is already being inlined")
                }
                inliningBundles.insert(bundle)
                defer { inliningBundles.remove(bundle) }

                if case .num(let idx) = indexExpr {
                    let strandIdx = Int(idx)
                    if strandIdx < targetBundle.strands.count {
                        return try generateExpression(targetBundle.strands[strandIdx].expr)
                    }
                } else if case .param(let field) = indexExpr {
                    // Named strand access
                    if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                        return try generateExpression(strand.expr)
                    }
                }
            }

            throw BackendError.unsupportedExpression("Cannot resolve bundle \(bundle)")

        case .binaryOp(let op, let left, let right):
            let leftCode = try generateExpression(left)
            let rightCode = try generateExpression(right)
            return try generateBinaryOp(op: op, left: leftCode, right: rightCode)

        case .unaryOp(let op, let operand):
            let operandCode = try generateExpression(operand)
            return try generateUnaryOp(op: op, operand: operandCode)

        case .call(let spindle, let args):
            // Inline spindle call - substitute args for params and return first value
            guard let spindleDef = program.spindles[spindle] else {
                throw BackendError.unsupportedExpression("Unknown spindle: \(spindle)")
            }
            guard !spindleDef.returns.isEmpty else {
                throw BackendError.unsupportedExpression("Spindle \(spindle) has no returns")
            }
            // Build substitutions (params + locals) and inline the return expression
            let substitutions = IRTransformations.buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(in: inlined, substitutions: substitutions)
            return try generateExpression(inlined)

        case .builtin(let name, let args):
            return try generateBuiltin(name: name, args: args)

        case .extract(let callExpr, let index):
            // Extract specific return value from spindle call
            guard case .call(let spindle, let args) = callExpr else {
                throw BackendError.unsupportedExpression("Extract requires a call expression")
            }
            guard let spindleDef = program.spindles[spindle] else {
                throw BackendError.unsupportedExpression("Unknown spindle: \(spindle)")
            }
            guard index < spindleDef.returns.count else {
                throw BackendError.unsupportedExpression("Extract index \(index) out of bounds for spindle \(spindle)")
            }
            // Build substitutions (params + locals) and inline the return expression
            let substitutions = IRTransformations.buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(in: inlined, substitutions: substitutions)
            return try generateExpression(inlined)

        case .remap(let base, let substitutions):
            let directExpr = IRTransformations.getDirectExpression(base, program: program)

            // Check if this remap base has an intermediate texture (heavy expression).
            // When generating an intermediate kernel, only reference prior intermediates (index < current)
            // to avoid self-references or forward references.
            let maxIntermediateIndex = currentlyGeneratingIntermediateIndex ?? intermediateTextures.count
            if directExpr.isHeavyExpression(),
               let intermediateIndex = intermediateTextures.prefix(maxIntermediateIndex).firstIndex(where: { $0.baseExpr.description == base.description }) {
                // Sample from pre-rendered intermediate texture at remapped UV coordinates
                let uExpr: String
                let vExpr: String
                if let xSub = substitutions["me.x"] {
                    uExpr = try generateExpression(xSub)
                } else {
                    uExpr = "x"
                }
                if let ySub = substitutions["me.y"] {
                    vExpr = try generateExpression(ySub)
                } else {
                    vExpr = "y"
                }
                return "intermediateTex\(intermediateIndex).sample(textureSampler, float2(\(uExpr), \(vExpr))).r"
            }

            // Lightweight expression: inline as before
            let remapped = IRTransformations.applyRemap(to: directExpr, substitutions: substitutions)
            return try generateExpression(remapped)

        case .cacheRead(let cacheId, let tapIndex):
            // cacheRead is used to break cycles - but only return buffer read when
            // generating a cache's valueExpr (self-reference). Otherwise return the
            // precomputed result.
            guard let (cacheIndex, descriptor) = cacheDescriptors.enumerated().first(where: { (_, desc) in
                desc.id == cacheId
            }) else {
                // Fallback: return 0 if no descriptor found
                return "0.0"
            }

            // Only return buffer read if generating THIS cache's valueExpr (self-reference)
            if let currentIdx = currentlyGeneratingCacheIndex, currentIdx == cacheIndex {
                let historySize = descriptor.historySize
                let clampedTap = min(tapIndex, historySize - 1)
                return "cache\(cacheIndex)_history[pixelIndex * \(historySize) + \(clampedTap)]"
            }

            // Otherwise return the precomputed result
            return "cache\(cacheIndex)_result"
        }
    }

    /// Generate binary operation
    private func generateBinaryOp(op: String, left: String, right: String) throws -> String {
        switch op {
        case "+": return "(\(left) + \(right))"
        case "-": return "(\(left) - \(right))"
        case "*": return "(\(left) * \(right))"
        case "/": return "(\(left) / \(right))"
        case "%": return "fmod(\(left), \(right))"
        case "^": return "pow(\(left), \(right))"
        case "<": return "(\(left) < \(right) ? 1.0 : 0.0)"
        case ">": return "(\(left) > \(right) ? 1.0 : 0.0)"
        case "<=": return "(\(left) <= \(right) ? 1.0 : 0.0)"
        case ">=": return "(\(left) >= \(right) ? 1.0 : 0.0)"
        case "==": return "(\(left) == \(right) ? 1.0 : 0.0)"
        case "!=": return "(\(left) != \(right) ? 1.0 : 0.0)"
        case "&&": return "((\(left) != 0.0 && \(right) != 0.0) ? 1.0 : 0.0)"
        case "||": return "((\(left) != 0.0 || \(right) != 0.0) ? 1.0 : 0.0)"
        default:
            throw BackendError.unsupportedExpression("Unknown binary operator: \(op)")
        }
    }

    /// Generate unary operation
    private func generateUnaryOp(op: String, operand: String) throws -> String {
        switch op {
        case "-": return "(-\(operand))"
        case "!": return "(\(operand) == 0.0 ? 1.0 : 0.0)"
        default:
            throw BackendError.unsupportedExpression("Unknown unary operator: \(op)")
        }
    }

    /// Generate builtin function call
    private func generateBuiltin(name: String, args: [IRExpr]) throws -> String {
        // Handle select specially - we need short-circuit evaluation
        if name == "select" {
            // select(index, branch0, branch1, ...)
            // Generate nested ternary: (idx < 1 ? b0 : (idx < 2 ? b1 : b2))
            guard args.count >= 2 else {
                throw BackendError.unsupportedExpression("select needs at least index and one branch")
            }
            let indexCode = try generateExpression(args[0])
            let branches = Array(args.dropFirst())

            if branches.count == 1 {
                return try generateExpression(branches[0])
            } else if branches.count == 2 {
                let b0 = try generateExpression(branches[0])
                let b1 = try generateExpression(branches[1])
                return "((\(indexCode)) != 0.0 ? (\(b1)) : (\(b0)))"
            } else {
                // Build nested ternary from right to left
                var result = try generateExpression(branches[branches.count - 1])
                for i in stride(from: branches.count - 2, through: 0, by: -1) {
                    let branchCode = try generateExpression(branches[i])
                    result = "((\(indexCode)) < \(Float(i + 1)) ? (\(branchCode)) : (\(result)))"
                }
                return result
            }
        }

        // Handle cache specially - need to generate inline tick logic
        if name == "cache" {
            return try generateCacheAccess(args: args)
        }

        let argCodes = try args.map { try generateExpression($0) }

        switch name {
        // Math functions
        case "sin": return "sin(\(argCodes[0]))"
        case "cos": return "cos(\(argCodes[0]))"
        case "tan": return "tan(\(argCodes[0]))"
        case "asin": return "asin(\(argCodes[0]))"
        case "acos": return "acos(\(argCodes[0]))"
        case "atan": return "atan(\(argCodes[0]))"
        case "atan2": return "atan2(\(argCodes[0]), \(argCodes[1]))"
        case "abs": return "abs(\(argCodes[0]))"
        case "floor": return "floor(\(argCodes[0]))"
        case "ceil": return "ceil(\(argCodes[0]))"
        case "round": return "round(\(argCodes[0]))"
        case "sqrt": return "sqrt(\(argCodes[0]))"
        case "pow": return "pow(\(argCodes[0]), \(argCodes[1]))"
        case "exp": return "exp(\(argCodes[0]))"
        case "log": return "log(\(argCodes[0]))"
        case "log2": return "log2(\(argCodes[0]))"

        // Utility functions
        case "min": return "min(\(argCodes[0]), \(argCodes[1]))"
        case "max": return "max(\(argCodes[0]), \(argCodes[1]))"
        case "clamp": return "clamp(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"
        case "lerp", "mix": return "mix(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"
        case "step": return "step(\(argCodes[0]), \(argCodes[1]))"
        case "smoothstep": return "smoothstep(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"
        case "fract": return "fract(\(argCodes[0]))"
        case "mod": return "fmod(\(argCodes[0]), \(argCodes[1]))"
        case "sign": return "sign(\(argCodes[0]))"

        // Noise (simplified - would need actual implementation)
        case "noise": return "fract(sin(dot(float2(\(argCodes[0]), \(argCodes.count > 1 ? argCodes[1] : "0.0")), float2(12.9898, 78.233))) * 43758.5453)"

        // Hardware inputs - now handled as builtins
        case "camera":
            // camera(u, v, channel)
            guard args.count >= 3 else {
                throw BackendError.unsupportedExpression("camera requires 3 arguments: u, v, channel")
            }
            let uCode = argCodes[0]
            let vCode = argCodes[1]
            let channel = args[2]
            let channelNames = ["r", "g", "b", "a"]
            let channelIdx: Int
            if case .num(let ch) = channel {
                channelIdx = Int(ch)
            } else {
                channelIdx = 0
            }
            let channelName = channelIdx < channelNames.count ? channelNames[channelIdx] : "r"
            return "cameraTexture.sample(textureSampler, float2(\(uCode), \(vCode))).\(channelName)"

        case "texture":
            // texture(resourceId, u, v, channel)
            guard args.count >= 4 else {
                throw BackendError.unsupportedExpression("texture requires 4 arguments: resourceId, u, v, channel")
            }
            let resourceId: Int
            if case .num(let rid) = args[0] {
                resourceId = Int(rid)
            } else {
                resourceId = 0
            }
            let uCode = argCodes[1]
            let vCode = argCodes[2]
            let channel = args[3]
            let texChannelNames = ["r", "g", "b", "a"]
            let texChannelIdx: Int
            if case .num(let ch) = channel {
                texChannelIdx = Int(ch)
            } else {
                texChannelIdx = 0
            }
            let texChannelName = texChannelIdx < texChannelNames.count ? texChannelNames[texChannelIdx] : "r"
            return "texture\(resourceId).sample(textureSampler, float2(\(uCode), \(vCode))).\(texChannelName)"

        case "microphone":
            // microphone(offset, channel)
            guard args.count >= 2 else {
                throw BackendError.unsupportedExpression("microphone requires 2 arguments: offset, channel")
            }
            let offsetCode = argCodes[0]
            let channel = args[1]
            let micChannelName: String
            if case .num(let ch) = channel {
                micChannelName = Int(ch) == 0 ? "r" : "g"
            } else {
                micChannelName = "r"
            }
            return "audioBuffer.sample(textureSampler, float2(\(offsetCode), 0.5)).\(micChannelName)"

        // Universal input builtins
        case "mouse":
            // mouse(channel) - returns x, y, or down based on channel
            // channel 0 = x, channel 1 = y, channel 2 = down
            guard args.count >= 1 else {
                throw BackendError.unsupportedExpression("mouse requires 1 argument: channel")
            }
            let channel = args[0]
            if case .num(let ch) = channel {
                switch Int(ch) {
                case 0: return "uniforms.mouseX"
                case 1: return "uniforms.mouseY"
                case 2: return "uniforms.mouseDown"
                default: return "uniforms.mouseX"
                }
            }
            // Dynamic channel access (rare case)
            return "(\(argCodes[0]) < 1.0 ? uniforms.mouseX : (\(argCodes[0]) < 2.0 ? uniforms.mouseY : uniforms.mouseDown))"

        case "key":
            // key(keyCode) - returns 0.0 or 1.0 based on key state
            guard args.count >= 1 else {
                throw BackendError.unsupportedExpression("key requires 1 argument: keyCode")
            }
            let keyCodeExpr = argCodes[0]
            // Access key state from buffer - clamp to valid range
            return "keyStates[clamp(int(\(keyCodeExpr)), 0, 255)]"

        case "text":
            // text(resourceId, x, y) -> sample from text texture (alpha mask)
            // Adjusts for aspect ratio to prevent stretching
            guard args.count >= 3 else {
                throw BackendError.unsupportedExpression("text requires 3 arguments: resourceId, x, y")
            }
            let resourceId: Int
            if case .num(let rid) = args[0] {
                resourceId = Int(rid)
            } else {
                resourceId = 0
            }
            let xCode = argCodes[1]
            let yCode = argCodes[2]
            // Correct for aspect ratio: scale x coordinate based on screen vs text aspect ratio
            // This ensures text maintains its natural proportions regardless of screen dimensions
            // adjustedX = x * screenAspect / textAspect
            // Return 0 (transparent) when sampling outside texture bounds
            let adjustedX = "((\(xCode)) * (w/h) / textTex\(resourceId)_aspect)"
            return "(\(adjustedX) >= 0.0 && \(adjustedX) <= 1.0 && (\(yCode)) >= 0.0 && (\(yCode)) <= 1.0 ? textTexture\(resourceId).sample(textureSampler, float2(\(adjustedX), (\(yCode)))).r : 0.0)"

        default:
            throw BackendError.unsupportedExpression("Unknown builtin: \(name)")
        }
    }

    /// Generate cache access code - returns reference to precomputed variable or buffer read for self-references
    private func generateCacheAccess(args: [IRExpr]) throws -> String {
        // cache(value, history_size, tap_index, signal)
        guard args.count >= 4 else {
            throw BackendError.unsupportedExpression("cache requires 4 arguments")
        }

        // Find matching descriptor by comparing value and signal expressions
        guard let (cacheIndex, descriptor) = cacheDescriptors.enumerated().first(where: { (_, desc) in
            desc.valueExpr == args[0] && desc.signalExpr == args[3]
        }) else {
            // Fallback: no descriptor available, just return value
            return try generateExpression(args[0])
        }

        // If we're currently generating the valueExpr for THIS cache, return buffer read
        // (self-reference: need previous frame's value, which is at position 0 before shift)
        if let currentIdx = currentlyGeneratingCacheIndex, currentIdx == cacheIndex {
            let historySize = descriptor.historySize
            // Always read from position 0 for self-reference - this is the most recent
            // stored value (from previous frame), before the current frame's shift
            return "cache\(cacheIndex)_history[pixelIndex * \(historySize) + 0]"
        }

        // Return reference to the precomputed result variable
        // (cache tick logic is generated in generateDisplayKernel's cacheHelpers)
        return "cache\(cacheIndex)_result"
    }

    /// Format a number for Metal code
    private func formatNumber(_ value: Double) -> String {
        if value == Double(Int(value)) {
            return "\(Int(value)).0"
        }
        return String(format: "%.6f", value)
    }

    /// Sanitize a bundle name for use as a Metal variable name
    private func sanitizeName(_ name: String) -> String {
        var result = ""
        for ch in name {
            if ch.isLetter || ch.isNumber || ch == "_" {
                result.append(ch)
            } else {
                result.append("_")
            }
        }
        // Ensure it starts with a letter or underscore
        if let first = result.first, first.isNumber {
            result = "_" + result
        }
        return result
    }
}
