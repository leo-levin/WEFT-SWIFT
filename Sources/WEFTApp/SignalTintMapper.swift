// SignalTintMapper.swift - Map strand names to source ranges for signal tinting

import AppKit

/// Maps strand names ("bundle.strand") to their source code ranges.
/// Used by the editor to apply amber background tinting based on probe values.
///
/// Reuses the WeftTokenizer and WeftTokenProcessor from WeftSyntaxColoring.swift.
/// The mapping is rebuilt on every edit (piggybacks on syntax highlighting).
class SignalTintMapper {

    /// Mapping from strand key ("bundle.strand" or "me.x") to all source ranges where it appears.
    private(set) var strandRanges: [String: [NSRange]] = [:]

    /// Rebuild the strand-name-to-ranges mapping from source code.
    func rebuild(from source: String) {
        var result: [String: [NSRange]] = [:]

        guard !source.isEmpty else {
            strandRanges = result
            return
        }

        let tokenizer = WeftTokenizer(source: source)
        let rawTokens = tokenizer.tokenize()
        let processor = WeftTokenProcessor()
        let tokens = processor.process(rawTokens)

        // Walk tokens looking for patterns:
        // 1. bundleName . strandAccessor  -> "bundle.strand" covering full span
        // 2. bundleName [ strandDeclName, strandDeclName ] -> each "bundle.strandName"
        // 3. keyword(me) . strandAccessor -> "me.field"
        var i = 0
        while i < tokens.count {
            let token = tokens[i]

            if token.type == .bundleName || (token.type == .keyword && token.text == "me") {
                let bundleName = token.text
                let bundleRange = token.range
                let afterBundle = i + 1

                // Skip whitespace
                var j = afterBundle
                while j < tokens.count && tokens[j].type == .whitespace {
                    j += 1
                }

                if j < tokens.count {
                    // Pattern: bundle.strand (strandAccessor includes the dot)
                    if tokens[j].type == .strandAccessor {
                        let accessor = tokens[j]
                        // strandAccessor text is ".fieldName" — strip the dot
                        let strandName = String(accessor.text.dropFirst())
                        let key = "\(bundleName).\(strandName)"
                        // Range covers bundle name through strand accessor
                        let fullRange = NSUnionRange(bundleRange, accessor.range)
                        result[key, default: []].append(fullRange)
                        i = j + 1
                        continue
                    }

                    // Pattern: bundle[strand1, strand2, ...]
                    if tokens[j].type == .strandDeclBracket && tokens[j].text == "[" {
                        j += 1
                        while j < tokens.count {
                            if tokens[j].type == .strandDeclBracket && tokens[j].text == "]" {
                                j += 1
                                break
                            }
                            if tokens[j].type == .strandDeclName {
                                let strandName = tokens[j].text
                                let key = "\(bundleName).\(strandName)"
                                result[key, default: []].append(tokens[j].range)
                            }
                            j += 1
                        }
                        i = j
                        continue
                    }
                }
            }

            i += 1
        }

        strandRanges = result
    }
}
