import CoreGraphics
import Foundation
import ImageIO

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// The decoded representation of an animated (or still) image (GIF, APNG,
/// animated WebP, …).
///
/// A source is either created already complete (local files and in-memory data)
/// or created empty and fed by ``append(data:isFinal:)`` while a download streams
/// in. In the streaming case ``frameCount`` grows as each frame's bytes arrive
/// and ``updates`` fires, so views can show — and start playing — the frames
/// that exist so far instead of waiting for the whole file to download.
///
/// Frames are decoded lazily from the underlying `CGImageSource` the first time
/// they are displayed and then cached, so even a very large animation never
/// fully expands into memory at once. The cache is bounded and evicts the
/// least-recently-used frames under memory pressure; evicted frames are simply
/// re-decoded on demand.
final class AnimatedImageSource: @unchecked Sendable {

    /// The longest-side cap, in pixels, that frames are downsampled to on decode.
    let maxPixelSize: Int

    private let cgSource: CGImageSource
    private let cache = NSCache<NSNumber, CGImage>()
    private let prefetchQueue = DispatchQueue(label: "AnimatedImageSource.prefetch", qos: .userInitiated)

    /// Serializes every ImageIO call on `cgSource`. An incremental source is
    /// mutated by `CGImageSourceUpdateData` while other threads decode from it,
    /// and ImageIO does not document that as safe.
    private let ioLock = NSLock()

    /// Guards the mutable loading state below.
    private let lock = NSLock()
    private var _frameCount: Int
    private var _loopCount: Int
    private var _pixelSize: CGSize
    private var _isComplete: Bool
    private var _loadError: Error?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    // Per-frame durations are read lazily (and memoized incrementally): reading
    // them for every frame up front would delay even the first frame.
    private let durationsLock = NSLock()
    private var cachedDurations: [Double] = []

    /// The number of fully-loaded, decodable frames. Grows while streaming.
    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _frameCount
    }

    /// The number of times to repeat the animation. `0` means loop forever.
    var loopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _loopCount
    }

    /// The pixel dimensions of the first frame, used for intrinsic sizing.
    var pixelSize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return _pixelSize
    }

    /// Whether loading has ended (successfully or not) and ``frameCount`` is final.
    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isComplete
    }

    /// The error that ended a streaming load, if it failed.
    var loadError: Error? {
        lock.lock(); defer { lock.unlock() }
        return _loadError
    }

    /// Creates a fully-loaded source wrapping an existing `CGImageSource`.
    init(cgSource: CGImageSource, frameCount: Int, loopCount: Int, pixelSize: CGSize, maxPixelSize: Int) {
        self.cgSource = cgSource
        self.maxPixelSize = maxPixelSize
        self._frameCount = frameCount
        self._loopCount = loopCount
        self._pixelSize = pixelSize
        self._isComplete = true
        // Bound decoded-frame memory to roughly 256 MB. The least recently used
        // frames are evicted and transparently re-decoded when needed again.
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    /// Creates an empty source to be fed incrementally with ``append(data:isFinal:)``
    /// as a download streams in.
    init(incrementalWithMaxPixelSize maxPixelSize: Int) {
        self.cgSource = CGImageSourceCreateIncremental(nil)
        self.maxPixelSize = maxPixelSize
        self._frameCount = 0
        self._loopCount = 0
        self._pixelSize = .zero
        self._isComplete = false
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    // MARK: - Streaming

    /// Feeds the bytes downloaded so far. `data` must always contain the entire
    /// file from the first byte, per `CGImageSourceUpdateData`'s contract. Newly
    /// completed frames become visible through ``frameCount`` and ``updates``.
    func append(data: Data, isFinal: Bool) {
        ioLock.lock()
        CGImageSourceUpdateData(cgSource, data as CFData, isFinal)
        let parsed = CGImageSourceGetCount(cgSource)
        // While streaming, the newest frame's data may still be arriving, so only
        // the frames strictly before it are safe to decode.
        let completed = isFinal ? parsed : Swift.max(0, parsed - 1)
        let size = completed > 0 ? AnimatedImageDecoder.pixelSize(cgSource, 0) : nil
        let loops = completed > 0 ? AnimatedImageDecoder.loopCount(cgSource) : 0
        ioLock.unlock()

        lock.lock()
        let grew = completed > _frameCount
        if grew {
            _frameCount = completed
            if _pixelSize == .zero, let size {
                _pixelSize = size
            }
            if _loopCount == 0 {
                _loopCount = loops
            }
        }
        if isFinal { _isComplete = true }
        guard grew || isFinal else {
            lock.unlock()
            return
        }
        let continuations = Array(observers.values)
        if isFinal { observers.removeAll() }
        lock.unlock()

        for continuation in continuations {
            continuation.yield(())
            if isFinal { continuation.finish() }
        }
    }

    /// Ends a streaming load with an error. Frames that already arrived remain
    /// displayable; views that have nothing yet can report the failure.
    func fail(_ error: Error) {
        lock.lock()
        _loadError = error
        _isComplete = true
        let continuations = Array(observers.values)
        observers.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.yield(())
            continuation.finish()
        }
    }

    /// Fires once immediately with the current state, again whenever more frames
    /// become available, and finishes once loading has completed. For an
    /// already-complete source it fires once and finishes right away.
    var updates: AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.yield(())
            lock.lock()
            if _isComplete {
                lock.unlock()
                continuation.finish()
                return
            }
            let id = UUID()
            observers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.observers[id] = nil
                self.lock.unlock()
            }
        }
    }

    // MARK: - Frames

    /// Reads (and memoizes) the per-frame display durations for the frames
    /// available so far, extending the memo as new frames stream in. This is the
    /// expensive metadata pass, so call it off the main thread.
    func loadFrameDurations() -> [Double] {
        let count = frameCount
        durationsLock.lock()
        defer { durationsLock.unlock() }
        while cachedDurations.count < count {
            ioLock.lock()
            let duration = AnimatedImageDecoder.frameDuration(cgSource, cachedDurations.count)
            ioLock.unlock()
            cachedDurations.append(duration)
        }
        return cachedDurations
    }

    /// Returns the decoded image for `index`, decoding and caching it on first use,
    /// and eagerly decodes the following frame on a background queue so that
    /// playback rarely has to decode on the main thread. This may decode
    /// synchronously, so call it off the main thread.
    func frame(at index: Int) -> CGImage? {
        let image = decodedFrame(at: index)
        prefetch(index + 1)
        return image
    }

    /// Returns the frame only if it is already decoded; otherwise schedules a
    /// background decode and returns `nil`. Never decodes synchronously, so it is
    /// safe to call from the main thread without blocking.
    func cachedFrame(at index: Int) -> CGImage? {
        guard index >= 0, index < frameCount else { return nil }
        if let cached = cache.object(forKey: NSNumber(value: index)) {
            prefetch(index + 1)   // stay one frame ahead
            return cached
        }
        prefetch(index)
        return nil
    }

    /// Synchronously decodes (or returns the cached) frame at `index`, downsampling
    /// to at most ``maxPixelSize`` on the longest side. Downsampling is what keeps a
    /// physically large animation cheap to decode, hold, and draw.
    private func decodedFrame(at index: Int) -> CGImage? {
        guard index >= 0, index < frameCount else { return nil }
        let key = NSNumber(value: index)
        if let cached = cache.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        ioLock.lock()
        let image = CGImageSourceCreateThumbnailAtIndex(cgSource, index, options as CFDictionary)
        ioLock.unlock()
        guard let image else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Decodes `index` in the background if it is in range and not already cached.
    private func prefetch(_ index: Int) {
        guard index >= 0, index < frameCount else { return }
        let key = NSNumber(value: index)
        guard cache.object(forKey: key) == nil else { return }
        prefetchQueue.async { [weak self] in
            guard let self, self.cache.object(forKey: key) == nil else { return }
            _ = self.decodedFrame(at: index)
        }
    }
}

/// Decodes animated (and static) image data into a lazily-decoding source using ImageIO.
enum AnimatedImageDecoder {

    /// A sensible default used when an image reports no per-frame delay.
    private static let defaultDelay: Double = 0.1
    /// Delays shorter than this are treated as `defaultDelay`, matching browser behavior.
    private static let minimumDelay: Double = 0.02
    /// Default longest-side cap, in pixels, for downsampling on decode. Large enough
    /// to look sharp on-screen, small enough to keep oversized animations fast.
    static let defaultMaxPixelSize = 1024

    static func decode(data: Data, maxPixelSize: Int = defaultMaxPixelSize) -> AnimatedImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source: source, maxPixelSize: maxPixelSize)
    }

    static func decode(url: URL, maxPixelSize: Int = defaultMaxPixelSize) -> AnimatedImageSource? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source: source, maxPixelSize: maxPixelSize)
    }

    static func decode(source: CGImageSource, maxPixelSize: Int = defaultMaxPixelSize) -> AnimatedImageSource? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        // Return as soon as we know the frame count and dimensions. Per-frame
        // durations (the expensive pass) and pixel data are read lazily, so the
        // first frame can be shown before the whole animation is decoded.
        guard let pixelSize = pixelSize(source, 0) else { return nil }
        return AnimatedImageSource(
            cgSource: source,
            frameCount: count,
            loopCount: loopCount(source),
            pixelSize: pixelSize,
            maxPixelSize: maxPixelSize
        )
    }

    // MARK: - Pixel size

    static func pixelSize(_ source: CGImageSource, _ index: Int) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    // MARK: - Frame timing

    static func frameDuration(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return defaultDelay
        }

        let raw: Double?
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            raw = delay(gif, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
        } else if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            raw = delay(png, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        } else if let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            raw = delay(webp, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        } else {
            raw = nil
        }

        guard let delay = raw, delay > 0 else { return defaultDelay }
        return delay < minimumDelay ? defaultDelay : delay
    }

    private static func delay(_ dictionary: [CFString: Any], _ unclamped: CFString, _ clamped: CFString) -> Double? {
        if let value = dictionary[unclamped] as? Double, value > 0 { return value }
        if let value = dictionary[clamped] as? Double, value > 0 { return value }
        return nil
    }

    // MARK: - Loop count

    static func loopCount(_ source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] else { return 0 }

        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let count = gif[kCGImagePropertyGIFLoopCount] as? Int {
            return count
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let count = png[kCGImagePropertyAPNGLoopCount] as? Int {
            return count
        }
        if let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any],
           let count = webp[kCGImagePropertyWebPLoopCount] as? Int {
            return count
        }
        return 0
    }
}
