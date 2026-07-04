import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// The current phase of an asynchronous animated-image load, mirroring `AsyncImagePhase`.
public enum AsyncAnimatedImagePhase {
    /// No image is loaded yet.
    case empty
    /// An image successfully loaded.
    case success(AnimatedImage<Image>)
    /// An image failed to load with an error.
    case failure(Error)

    /// The loaded image, if the phase represents a success.
    public var image: AnimatedImage<Image>? {
        if case let .success(image) = self { return image }
        return nil
    }

    /// The error, if the phase represents a failure.
    public var error: Error? {
        if case let .failure(error) = self { return error }
        return nil
    }
}

/// A view that asynchronously loads and displays an animated image, mirroring the
/// API and behavior of SwiftUI's `AsyncImage`.
///
/// The image is decoded progressively and plays HLS-style while it downloads:
/// the first frame is shown as a still the moment its bytes arrive, playback
/// starts once a small buffer of frames exists, and if playback catches up with
/// the download it holds the current frame as a still until enough frames
/// rebuffer. Views that request the same URL share a single download and decode.
///
/// ```swift
/// AsyncAnimatedImage(url: URL(string: "https://example.com/loading.gif"))
///
/// AsyncAnimatedImage(url: url, playback: .once) { image in
///     image.resizable().scaledToFit()
/// } placeholder: {
///     ProgressView()
/// }
/// ```
public struct AsyncAnimatedImage<Content: View>: View {

    private let url: URL?
    private let scale: CGFloat
    private let playback: AnimatedImagePlayback
    private let transaction: Transaction
    private let content: (AsyncAnimatedImagePhase) -> Content

    @State private var phase: AsyncAnimatedImagePhase = .empty

    /// Loads and displays an animated image using a custom view for each phase.
    ///
    /// - Parameters:
    ///   - url: The URL of the image to display.
    ///   - scale: The scale to use for the image. Defaults to `1`.
    ///   - playback: The playback configuration for the loaded image. Defaults to ``AnimatedImagePlayback/automatic``.
    ///   - transaction: The transaction used when the phase changes.
    ///   - content: A closure that maps the current ``AsyncAnimatedImagePhase`` to a view.
    public init(
        url: URL?,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic,
        transaction: Transaction = Transaction(),
        @ViewBuilder content: @escaping (AsyncAnimatedImagePhase) -> Content
    ) {
        self.url = url
        self.scale = scale
        self.playback = playback
        self.transaction = transaction
        self.content = content
    }

    public var body: some View {
        content(phase)
            .task(id: url) {
                await load()
            }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }

        // One shared, progressively-decoded source per URL: every view showing
        // the same image joins the same download, and a source that was already
        // fetched is reused outright. Downloading and decoding happen off the
        // main actor inside the loader; this view only observes.
        let source = AnimatedImageRemoteLoader.shared.source(for: url)

        // Hold the placeholder just until the first frame is renderable, then
        // hand the still-growing source to AnimatedImage, which follows it as
        // the remaining frames stream in.
        if source.frameCount == 0 {
            for await _ in source.updates {
                if source.frameCount > 0 { break }
            }
        }
        guard !Task.isCancelled else { return }

        withTransaction(transaction) {
            if source.frameCount > 0 {
                phase = .success(image(for: source, id: AnyHashable(url)))
            } else {
                phase = .failure(source.loadError ?? URLError(.cannotDecodeContentData))
            }
        }
    }

    private func image(for source: AnimatedImageSource?, id: AnyHashable) -> AnimatedImage<Image> {
        AnimatedImage(source: source, scale: scale, id: id, playback: playback) { $0 }
    }
}

// MARK: - Convenience initializers

extension AsyncAnimatedImage where Content == _ConditionalContent<AnimatedImage<Image>, Color> {

    /// Loads and displays an animated image, showing a plain placeholder until it loads.
    ///
    /// - Parameters:
    ///   - url: The URL of the image to display.
    ///   - scale: The scale to use for the image. Defaults to `1`.
    ///   - playback: The playback configuration for the loaded image. Defaults to ``AnimatedImagePlayback/automatic``.
    public init(url: URL?, scale: CGFloat = 1, playback: AnimatedImagePlayback = .automatic) {
        self.init(url: url, scale: scale, playback: playback) { phase in
            if let image = phase.image {
                image
            } else {
                Color(white: 0.9)
            }
        }
    }
}

extension AsyncAnimatedImage {

    /// Loads and displays a modifiable animated image using a custom placeholder.
    ///
    /// - Parameters:
    ///   - url: The URL of the image to display.
    ///   - scale: The scale to use for the image. Defaults to `1`.
    ///   - playback: The playback configuration for the loaded image. Defaults to ``AnimatedImagePlayback/automatic``.
    ///   - content: A closure that maps the loaded ``AnimatedImage`` to a view.
    ///   - placeholder: A closure that provides the view to show while loading.
    public init<I: View, P: View>(
        url: URL?,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic,
        @ViewBuilder content: @escaping (AnimatedImage<Image>) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.init(url: url, scale: scale, playback: playback) { phase in
            if let image = phase.image {
                content(image)
            } else {
                placeholder()
            }
        }
    }
}

// MARK: - Shared streaming loader

/// Starts — or joins — the streaming download for a remote animated image.
///
/// All views asking for the same URL share one download and one progressively
/// growing ``AnimatedImageSource`` (and therefore one decoded-frame cache),
/// instead of each fetching and decoding the file independently. Completed
/// sources are kept in ``AnimatedImageSourceCache`` for reuse.
final class AnimatedImageRemoteLoader: @unchecked Sendable {

    static let shared = AnimatedImageRemoteLoader()

    private let lock = NSLock()
    private var inFlight: [String: AnimatedImageSource] = [:]

    /// Returns the shared source for `url`, starting its download if nothing is
    /// cached or in flight. The returned source may still be loading — observe
    /// ``AnimatedImageSource/updates`` to follow it. A download runs to
    /// completion once started, so the result is cached even if every view that
    /// wanted it has since disappeared.
    func source(for url: URL) -> AnimatedImageSource {
        let key = url.absoluteString
        lock.lock()
        if let finished = AnimatedImageSourceCache.shared.source(forKey: key) {
            lock.unlock()
            return finished
        }
        if let active = inFlight[key] {
            lock.unlock()
            return active
        }
        let source = AnimatedImageSource(incrementalWithMaxPixelSize: AnimatedImageDecoder.defaultMaxPixelSize)
        inFlight[key] = source
        lock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            await Self.download(url: url, into: source)
            self?.finish(key: key, source: source)
        }
        return source
    }

    private func finish(key: String, source: AnimatedImageSource) {
        lock.lock()
        inFlight[key] = nil
        // Only successful loads are kept; a failed one is retried the next time
        // a view asks for the URL.
        if source.loadError == nil, source.frameCount > 0 {
            AnimatedImageSourceCache.shared.insert(source, forKey: key)
        }
        lock.unlock()
    }

    /// Loads the file from the disk cache, or streams the download while feeding
    /// the shared source so frames become renderable while the rest of the file
    /// is still on the wire.
    private static func download(url: URL, into source: AnimatedImageSource) async {
        // A disk hit skips the network entirely: one parse pass and done.
        if let cached = AnimatedImageDiskCache.read(forKey: url.absoluteString) {
            source.append(data: cached, isFinal: true)
            _ = source.cachedFrame(at: 0)   // schedule the first frame's decode
            return
        }

        var buffer = Data()
        // `CGImageSourceUpdateData` re-parses from the start of the buffer, so
        // feeding it every tiny network chunk is quadratic on large files. Parse
        // eagerly until the first frame is out, then batch the updates.
        var unparsedBytes = 0
        var decodingFirstFrame = false
        do {
            for try await chunk in dataStream(from: url) {
                buffer.append(chunk)
                unparsedBytes += chunk.count
                if source.frameCount == 0 || unparsedBytes >= 128 * 1024 {
                    source.append(data: buffer, isFinal: false)
                    unparsedBytes = 0
                }
                // Start decoding the first frame the instant its bytes are in,
                // so it is already on hand when the view asks for it.
                if !decodingFirstFrame, source.frameCount > 0 {
                    decodingFirstFrame = true
                    _ = source.cachedFrame(at: 0)   // schedules a background decode
                }
            }
            source.append(data: buffer, isFinal: true)
            if source.frameCount > 0 {
                AnimatedImageDiskCache.write(buffer, forKey: url.absoluteString)
            }
        } catch {
            source.fail(error)
        }
    }

    /// The session shared by all animated-image downloads. Sharing one session
    /// reuses warm connections (TCP/TLS) to hosts serving several images. Disk
    /// persistence is handled by ``AnimatedImageDiskCache`` instead of `URLCache`,
    /// which both refuses responses bigger than a few percent of its capacity
    /// (animation files routinely are) and requires server cache headers.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 0)
        return URLSession(configuration: configuration)
    }()

    /// Streams the bytes of `url` as they arrive, so frames can be decoded
    /// before the download completes.
    private static func dataStream(from url: URL) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: url)
            task.delegate = StreamingDelegate(continuation: continuation)
            task.priority = URLSessionTask.highPriority
            continuation.onTermination = { _ in
                task.cancel()
            }
            task.resume()
        }
    }
}

/// Bridges `URLSessionDataDelegate` chunk callbacks into an `AsyncThrowingStream`.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

// MARK: - Disk cache

/// A small disk cache holding the raw bytes of downloaded animated images, keyed
/// by a hash of the URL, so a previously fetched animation loads with no network
/// at all — including across app launches. Kept in the user's Caches directory
/// (purgeable by the system) and bounded by evicting the least recently used
/// files past ``capacity``.
///
/// All calls touch the file system, so call from a background context.
enum AnimatedImageDiskCache {

    /// Total size cap for the cache directory.
    private static let capacity = 512 * 1024 * 1024

    private static let directory: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("AnimatedImage/Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func fileURL(forKey key: String) -> URL? {
        guard let directory else { return nil }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    /// The cached file data for `key`, marking it recently used.
    static func read(forKey key: String) -> Data? {
        guard let url = fileURL(forKey: key), let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// Stores `data` for `key`, then evicts the least recently used files if the
    /// cache has outgrown its capacity.
    static func write(_ data: Data, forKey key: String) {
        guard let url = fileURL(forKey: key), data.count <= capacity else { return }
        try? data.write(to: url, options: .atomic)
        evictIfNeeded()
    }

    private static func evictIfNeeded() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
              ) else { return }

        let entries: [(url: URL, size: Int, used: Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (file, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > capacity else { return }

        for entry in entries.sorted(by: { $0.used < $1.used }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= capacity { break }
        }
    }
}

// MARK: - Decoded-source cache

/// A process-wide, in-memory cache of decoded ``AnimatedImageSource`` values keyed
/// by URL, so an animation that has already been fetched and decoded is reused when
/// an ``AsyncAnimatedImage`` reappears — avoiding a re-download and, more importantly,
/// a costly re-decode. Entries are evicted automatically under memory pressure.
///
/// This complements (rather than replaces) HTTP-level caching performed by
/// `URLSession`'s `URLCache`.
final class AnimatedImageSourceCache: @unchecked Sendable {

    static let shared = AnimatedImageSourceCache()

    private let cache = NSCache<NSString, AnimatedImageSource>()

    /// The decoded source previously stored for `key`, if any.
    func source(forKey key: String) -> AnimatedImageSource? {
        cache.object(forKey: key as NSString)
    }

    /// Stores a decoded source for `key`.
    func insert(_ source: AnimatedImageSource, forKey key: String) {
        cache.setObject(source, forKey: key as NSString)
    }
}
