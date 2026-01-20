// SampleManager.swift - Manages loading and caching of audio samples for WEFT programs

import Foundation
import AVFoundation

// MARK: - Sample Loading Error

public enum SampleError: Error, LocalizedError {
    case fileNotFound(String)
    case loadFailed(String)
    case invalidFormat(String)
    case pickerCancelled
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Audio file not found: \(path)"
        case .loadFailed(let message):
            return "Failed to load audio: \(message)"
        case .invalidFormat(let format):
            return "Invalid audio format: \(format)"
        case .pickerCancelled:
            return "File picker was cancelled"
        case .conversionFailed(let message):
            return "Audio conversion failed: \(message)"
        }
    }
}

// MARK: - Audio Sample Buffer

public struct AudioSampleBuffer {
    /// Interleaved audio samples (L, R, L, R, ...)
    public let samples: [Float]

    /// Number of channels (1 = mono, 2 = stereo)
    public let channels: Int

    /// Sample rate of the audio
    public let sampleRate: Double

    /// Number of frames (samples per channel)
    public let frameCount: Int

    public init(samples: [Float], channels: Int, sampleRate: Double, frameCount: Int) {
        self.samples = samples
        self.channels = channels
        self.sampleRate = sampleRate
        self.frameCount = frameCount
    }

    /// Get a sample at the given frame and channel with looping
    public func getSample(at frame: Int, channel: Int) -> Float {
        guard !samples.isEmpty, frameCount > 0 else { return 0.0 }

        // Handle negative frames and looping
        var wrappedFrame = frame % frameCount
        if wrappedFrame < 0 {
            wrappedFrame += frameCount
        }

        // Clamp channel
        let clampedChannel = max(0, min(channel, channels - 1))

        // Calculate index into interleaved buffer
        let index = wrappedFrame * channels + clampedChannel
        guard index >= 0 && index < samples.count else { return 0.0 }

        return samples[index]
    }
}

// MARK: - Sample Manager

public class SampleManager {
    /// Cache of loaded samples by resolved path
    private var cache: [String: AudioSampleBuffer] = [:]

    /// Samples indexed by resource ID
    private var samples: [Int: AudioSampleBuffer] = [:]

    /// Tracks which resources failed to load and why
    public private(set) var loadErrors: [Int: (path: String, error: SampleError)] = [:]

    /// Target sample rate for resampling (set from audio output)
    public var targetSampleRate: Double = 44100

    /// Callback for when a file picker is needed (set by UI layer)
    public var onPickerNeeded: ((_ forResourceId: Int, _ fileTypes: [String]) async -> URL?)?

    public init() {}

    /// Load all audio samples from program resources
    /// - Parameters:
    ///   - resources: Array of file paths from IRProgram.resources
    ///   - sourceFileURL: URL of the .weft source file (for relative path resolution)
    /// - Returns: Dictionary mapping resource ID to loaded sample
    public func loadSamples(
        resources: [String],
        sourceFileURL: URL?
    ) throws -> [Int: AudioSampleBuffer] {
        samples = [:]
        loadErrors = [:]

        for (index, path) in resources.enumerated() {
            // Skip non-audio resources (images handled by TextureManager)
            let ext = (path as NSString).pathExtension.lowercased()
            let audioExtensions = ["wav", "aiff", "aif", "mp3", "m4a", "flac", "ogg", "caf"]
            guard audioExtensions.contains(ext) else {
                continue
            }

            do {
                let sample = try loadSample(path: path, relativeTo: sourceFileURL)
                samples[index] = sample
                print("SampleManager: Loaded sample \(index) from '\(path)' (\(sample.frameCount) frames, \(sample.channels) channels)")
            } catch let error as SampleError {
                print("SampleManager: Failed to load sample \(index) from '\(path)': \(error)")
                loadErrors[index] = (path: path, error: error)
                // Create a silent placeholder
                samples[index] = createSilentSample()
            } catch {
                print("SampleManager: Failed to load sample \(index) from '\(path)': \(error)")
                loadErrors[index] = (path: path, error: .loadFailed(error.localizedDescription))
                samples[index] = createSilentSample()
            }
        }

        return samples
    }

    /// Load a single audio sample from a path
    /// - Parameters:
    ///   - path: File path (can be relative or absolute)
    ///   - relativeTo: Base URL for relative path resolution
    /// - Returns: Loaded audio sample buffer
    public func loadSample(path: String, relativeTo sourceFileURL: URL?) throws -> AudioSampleBuffer {
        // Check cache first
        if let cached = cache[path] {
            return cached
        }

        // Resolve path
        let url = try resolveSamplePath(path, relativeTo: sourceFileURL)

        // Load sample
        let sample = try loadSampleFromURL(url)

        // Cache by original path
        cache[path] = sample

        return sample
    }

    /// Resolve a sample path to a URL
    private func resolveSamplePath(_ path: String, relativeTo sourceFileURL: URL?) throws -> URL {
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

        throw SampleError.fileNotFound(path)
    }

    /// Load an audio sample from a URL
    private func loadSampleFromURL(_ url: URL) throws -> AudioSampleBuffer {
        // Open the audio file
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw SampleError.loadFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }

        let processingFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard frameCount > 0 else {
            throw SampleError.invalidFormat("Empty audio file")
        }

        // Create buffer for reading
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            throw SampleError.loadFailed("Could not create buffer")
        }

        // Read the audio data
        do {
            try audioFile.read(into: buffer)
        } catch {
            throw SampleError.loadFailed("Could not read audio: \(error.localizedDescription)")
        }

        // Convert to our format
        let channelCount = Int(processingFormat.channelCount)
        let sampleRate = processingFormat.sampleRate
        let actualFrameCount = Int(buffer.frameLength)

        // Extract interleaved samples
        var interleavedSamples: [Float] = []
        interleavedSamples.reserveCapacity(actualFrameCount * channelCount)

        if let floatData = buffer.floatChannelData {
            for frame in 0..<actualFrameCount {
                for channel in 0..<channelCount {
                    interleavedSamples.append(floatData[channel][frame])
                }
            }
        } else {
            throw SampleError.invalidFormat("Audio format not supported (must be float)")
        }

        // Resample if needed
        let finalSamples: [Float]
        let finalSampleRate: Double
        let finalFrameCount: Int

        if abs(sampleRate - targetSampleRate) > 1.0 {
            // Need to resample
            let resampleRatio = targetSampleRate / sampleRate
            finalFrameCount = Int(Double(actualFrameCount) * resampleRatio)
            finalSampleRate = targetSampleRate

            var resampled: [Float] = []
            resampled.reserveCapacity(finalFrameCount * channelCount)

            for frame in 0..<finalFrameCount {
                let srcFrame = Double(frame) / resampleRatio
                let srcFrameInt = Int(srcFrame)
                let frac = Float(srcFrame - Double(srcFrameInt))

                for channel in 0..<channelCount {
                    let idx1 = srcFrameInt * channelCount + channel
                    let idx2 = min(srcFrameInt + 1, actualFrameCount - 1) * channelCount + channel

                    if idx1 < interleavedSamples.count && idx2 < interleavedSamples.count {
                        // Linear interpolation
                        let sample = interleavedSamples[idx1] * (1.0 - frac) + interleavedSamples[idx2] * frac
                        resampled.append(sample)
                    } else if idx1 < interleavedSamples.count {
                        resampled.append(interleavedSamples[idx1])
                    } else {
                        resampled.append(0.0)
                    }
                }
            }

            finalSamples = resampled
        } else {
            finalSamples = interleavedSamples
            finalSampleRate = sampleRate
            finalFrameCount = actualFrameCount
        }

        return AudioSampleBuffer(
            samples: finalSamples,
            channels: channelCount,
            sampleRate: finalSampleRate,
            frameCount: finalFrameCount
        )
    }

    /// Create a silent sample as placeholder
    private func createSilentSample() -> AudioSampleBuffer {
        return AudioSampleBuffer(
            samples: [0.0, 0.0],  // One frame of stereo silence
            channels: 2,
            sampleRate: targetSampleRate,
            frameCount: 1
        )
    }

    /// Get a loaded sample by resource ID
    public func getSample(at index: Int) -> AudioSampleBuffer? {
        return samples[index]
    }

    /// Get all loaded samples
    public func getAllSamples() -> [Int: AudioSampleBuffer] {
        return samples
    }

    /// Get the count of loaded samples
    public var sampleCount: Int {
        return samples.count
    }

    /// Clear all cached samples
    public func clearCache() {
        cache.removeAll()
        samples.removeAll()
    }
}

// MARK: - Sample Manager Extension for Async Loading

extension SampleManager {
    /// Load sample with file picker fallback for missing files
    public func loadSampleWithPicker(
        path: String,
        resourceId: Int,
        sourceFileURL: URL?
    ) async throws -> AudioSampleBuffer {
        // If path is empty or just whitespace, trigger picker
        if path.trimmingCharacters(in: .whitespaces).isEmpty {
            return try await requestSampleFromPicker(resourceId: resourceId)
        }

        // Try to load from path
        do {
            return try loadSample(path: path, relativeTo: sourceFileURL)
        } catch SampleError.fileNotFound {
            // File not found - try picker if available
            return try await requestSampleFromPicker(resourceId: resourceId)
        }
    }

    /// Request a sample via file picker
    private func requestSampleFromPicker(resourceId: Int) async throws -> AudioSampleBuffer {
        guard let picker = onPickerNeeded else {
            throw SampleError.fileNotFound("(no picker available)")
        }

        let fileTypes = ["wav", "aiff", "aif", "mp3", "m4a", "flac", "caf"]

        guard let url = await picker(resourceId, fileTypes) else {
            throw SampleError.pickerCancelled
        }

        return try loadSampleFromURL(url)
    }
}
