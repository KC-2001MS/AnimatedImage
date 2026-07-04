import CoreGraphics
import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How an ``AnimatedImage`` repeats its animation.
public enum AnimatedImageLoop: Equatable, Sendable {
    /// Honor the loop count encoded in the image file (the default).
    case source
    /// Play through the frames exactly once, then hold on the last frame.
    case once
    /// Loop indefinitely, regardless of what the file specifies.
    case forever
    /// Loop a specific number of times, then hold on the last frame.
    case count(Int)
}

/// Playback configuration for an ``AnimatedImage``.
///
/// ```swift
/// // Play once; the view flips the binding to false when it finishes, and setting
/// // it back to true replays from the top.
/// AnimatedImage("celebrate", playback: .init(loop: .once, isPlaying: $isPlaying))
///
/// // Drive play/pause from a Bool.
/// AnimatedImage("spinner", playback: .init(loop: .forever, isPlaying: $isPlaying))
/// ```
public struct AnimatedImagePlayback {

    /// The repeat behavior. Defaults to ``AnimatedImageLoop/source``.
    public var loop: AnimatedImageLoop

    /// An optional two-way binding to the playing state. When bound, setting it to
    /// `false` pauses on the current frame and `true` resumes (or replays from the
    /// top once a finite animation has finished); the view also flips it to `false`
    /// when a finite (`once`/`count`) animation finishes. Leave `nil` to play
    /// automatically with no external control.
    public var isPlaying: Binding<Bool>?

    /// Creates a playback configuration.
    ///
    /// - Parameters:
    ///   - loop: The repeat behavior. Defaults to ``AnimatedImageLoop/source``.
    ///   - isPlaying: An optional two-way binding controlling and reflecting the
    ///     playing state. Defaults to `nil` (plays automatically).
    public init(
        loop: AnimatedImageLoop = .source,
        isPlaying: Binding<Bool>? = nil
    ) {
        self.loop = loop
        self.isPlaying = isPlaying
    }

    /// Honors the file's own loop count. The default.
    public static var automatic: AnimatedImagePlayback { .init() }
    /// Plays once, then holds on the last frame.
    public static var once: AnimatedImagePlayback { .init(loop: .once) }
    /// Loops indefinitely.
    public static var forever: AnimatedImagePlayback { .init(loop: .forever) }
}

/// A reference to an animated-image resource by name, enabling a type-safe,
/// non-literal call site such as `AnimatedImage(.spinner)`.
///
/// Xcode only auto-generates symbols for image and color sets, not data sets, so
/// declare the shortcuts you want yourself:
///
/// ```swift
/// extension AnimatedImageResource {
///     static let spinner = AnimatedImageResource(name: "spinner")
/// }
///
/// AnimatedImage(.spinner)
/// ```
public struct AnimatedImageResource: Hashable, Sendable {

    /// The resource name — a loose bundle file or an asset-catalog data set.
    public let name: String
    /// The bundle to search. Defaults to the main bundle.
    public let bundle: Bundle

    public init(name: String, bundle: Bundle = .main) {
        self.name = name
        self.bundle = bundle
    }
}

/// A view that displays an animated image (GIF, APNG, or animated WebP) from a
/// local source, mirroring the API and behavior of SwiftUI's `Image`.
///
/// Like `Image`, `AnimatedImage` loads its content synchronously from a bundle
/// resource, file URL, or in-memory `Data`. By default it renders each frame as
/// a plain, non-resizable `Image` — call ``resizable(capInsets:resizingMode:)``
/// to make it fill the space offered by its parent:
///
/// ```swift
/// AnimatedImage("loading")            // "loading.gif" from the main bundle
///     .resizable()
///     .scaledToFit()
///     .frame(width: 100, height: 100)
/// ```
///
/// For full control over how each frame is rendered — matching `AsyncImage`'s
/// `content` closure — use the transforming initializer. The closure receives the
/// current frame as a SwiftUI `Image`, so every `Image` modifier (`resizable`,
/// `interpolation`, `antialiased`, `renderingMode`, aspect ratio, …) is available:
///
/// ```swift
/// AnimatedImage("loading") { image in
///     image
///         .resizable()
///         .interpolation(.high)
///         .aspectRatio(contentMode: .fit)
/// }
/// ```
///
/// Playback is configured with the `playback` parameter (repeat forever, play
/// once, loop N times, or play/pause via a `Bool` binding) and driven by a
/// `TimelineView`, so it honors each frame's duration and pauses automatically
/// when the view is off-screen. The first frame is shown as soon as it decodes —
/// statically, before the rest of the animation is ready — and frames are decoded
/// lazily, so even a large animation appears quickly and stays memory-friendly.
///
/// To load an animated image over the network, use ``AsyncAnimatedImage`` instead.
public struct AnimatedImage<Content: View>: View {

    /// The instant playback started; shifted to implement pause/resume and reset
    /// whenever the source or trigger changes.
    @State private var start = Date()
    /// Elapsed seconds captured while paused, `nil` while playing.
    @State private var pausedElapsed: Double?
    /// Bumped on every playback state transition to (re)key the completion watcher.
    @State private var runID = 0
    /// Per-frame durations, loaded asynchronously. While `nil`, the first frame is
    /// shown statically; once loaded (for a multi-frame source) playback begins.
    @State private var durations: [Double]?
    /// The first frame, decoded off the main thread for a non-blocking initial paint
    /// and used as a fallback whenever a frame has not been decoded yet.
    @State private var firstFrame: CGImage?
    /// The most recent frame put on screen, held when the frame the clock asks
    /// for has not finished decoding — flashing back to the first frame instead
    /// would flicker.
    @State private var displayed = FrameHolder()
    /// While streaming, the elapsed position at which playback ran out of
    /// downloaded frames and stalled (HLS-style rebuffering); `nil` while playing
    /// normally. The stalled frame is held as a still, and playback resumes from
    /// this position once enough further frames have buffered.
    @State private var bufferStallElapsed: Double?

    private let source: AnimatedImageSource?
    private let scale: CGFloat
    private let id: AnyHashable
    private let playback: AnimatedImagePlayback
    private let transform: (Image) -> Content

    /// Creates an animated image from an already-decoded source and a per-frame
    /// transform applied to each frame's `Image`.
    init(
        source: AnimatedImageSource?,
        scale: CGFloat,
        id: AnyHashable,
        playback: AnimatedImagePlayback,
        transform: @escaping (Image) -> Content
    ) {
        self.source = source
        self.scale = scale
        self.id = id
        self.playback = playback
        self.transform = transform
    }

    /// Whether the animation should currently advance. Absent a binding it always plays.
    private var isPlaying: Bool { playback.isPlaying?.wrappedValue ?? true }

    // MARK: - Body

    public var body: some View {
        frames
            .task(id: id) { await loadContent() }
            .onChange(of: isPlaying) { _, nowPlaying in
                if nowPlaying {
                    if let durations, isCompleted(durations) {
                        // Finished playing → treat turning it back on as a replay.
                        start = Date()
                    } else {
                        // Resume: shift the origin so elapsed time continues where it stopped.
                        start = Date().addingTimeInterval(-(pausedElapsed ?? 0))
                    }
                    pausedElapsed = nil
                } else {
                    // Pause: remember how far we had played.
                    pausedElapsed = Date().timeIntervalSince(start)
                }
                runID += 1
            }
            .task(id: runID) { await watchPlayback() }
    }

    @ViewBuilder
    private var frames: some View {
        if let source {
            if let durations, durations.count > 1, isPlaying, bufferStallElapsed == nil {
                TimelineView(
                    AnimatedImageSchedule(
                        start: start,
                        durations: durations,
                        loopCount: scheduleLoopCount(source)
                    )
                ) { context in
                    let index = animatedImageFrameIndex(
                        elapsed: context.date.timeIntervalSince(start),
                        durations: durations,
                        loopCount: scheduleLoopCount(source)
                    )
                    // Never decode on the main thread: use the cached frame if it
                    // is ready, otherwise keep showing the current frame while the
                    // new one decodes in the background (it lands on the next tick).
                    render(hold(source.cachedFrame(at: index)))
                }
            } else if let durations, durations.count > 1 {
                // Paused by the caller, or stalled waiting for more frames to
                // download: hold on the frame we stopped at.
                let index = animatedImageFrameIndex(
                    elapsed: pausedElapsed ?? bufferStallElapsed ?? 0,
                    durations: durations,
                    loopCount: scheduleLoopCount(source)
                )
                render(hold(source.cachedFrame(at: index)))
            } else {
                // Durations not loaded yet (or a single/still frame): show the
                // first frame statically so something appears immediately.
                render(firstFrame ?? source.cachedFrame(at: 0))
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func render(_ cgImage: CGImage?) -> some View {
        if let cgImage {
            transform(Image(decorative: cgImage, scale: scale, orientation: .up))
        } else {
            Color.clear
        }
    }

    /// The frame to put on screen: the requested frame when it is decoded,
    /// otherwise the frame already showing (or, failing that, the first frame).
    /// Memoized into ``displayed`` as a plain side value — not observed state —
    /// so remembering it never triggers another render pass.
    private func hold(_ requested: CGImage?) -> CGImage? {
        let image = requested ?? displayed.image ?? firstFrame
        displayed.image = image
        return image
    }

    // MARK: - Playback control

    /// Decodes the first frame and reads the per-frame durations, both off the main
    /// thread, then starts playback. Nothing is decoded on the main thread, so the
    /// UI stays responsive. Re-runs whenever the source (`id`) changes.
    ///
    /// For a still-streaming remote source this follows ``AnimatedImageSource/updates``
    /// and plays HLS-style: the first frame is shown as a still the moment it
    /// exists, playback starts once an initial buffer of frames has downloaded,
    /// and whenever playback catches up with the download it stalls on the
    /// current frame (see ``watchPlayback()``) and resumes here — from that same
    /// frame — once enough further frames have buffered.
    private func loadContent() async {
        // Reset to the static-first-frame state for the (possibly new) source.
        durations = nil
        pausedElapsed = nil
        firstFrame = nil
        displayed.image = nil
        bufferStallElapsed = nil

        guard let source else { return }

        // Fires immediately with the current state, again per batch of newly
        // arrived frames, and ends when the source is fully loaded.
        for await _ in source.updates {
            if firstFrame == nil, source.frameCount > 0 {
                // Decode the first frame in the background, then read it from the cache.
                await Task.detached(priority: .userInitiated) { _ = source.frame(at: 0) }.value
                guard !Task.isCancelled else { return }
                firstFrame = source.cachedFrame(at: 0)
            }

            guard source.frameCount > 1 else { continue }
            let loaded = await Task.detached(priority: .userInitiated) { source.loadFrameDurations() }.value
            guard !Task.isCancelled else { return }
            let buffered = loaded.reduce(0, +)

            if durations == nil {
                // Hold the first frame until an initial buffer is ready (or the
                // whole file has already arrived), then start playing.
                guard source.isComplete || buffered >= animatedImageBufferSeconds else { continue }
                start = Date()
                durations = loaded
            } else {
                durations = loaded
                if let stalled = bufferStallElapsed,
                   source.isComplete || buffered - stalled >= animatedImageBufferSeconds {
                    // Rebuffered: resume playback from the frame we stalled on.
                    start = Date().addingTimeInterval(-stalled)
                    bufferStallElapsed = nil
                }
            }
            runID += 1
        }
    }

    /// Watches the playhead. While the file is still downloading, this detects
    /// the moment playback runs out of buffered frames and stalls it on the
    /// current frame (a still, until ``loadContent()`` rebuffers and resumes).
    /// Once loading is complete, it instead watches a finite animation with a
    /// bound playing state and flips the binding to `false` at the last frame so
    /// callers can observe completion. Re-armed via `runID` whenever playback
    /// state changes or more frames arrive.
    private func watchPlayback() async {
        guard isPlaying, let source, let durations, durations.count > 1 else { return }

        if !source.isComplete {
            guard bufferStallElapsed == nil else { return }
            // Sleep until the playhead reaches the end of the downloaded frames.
            // If more frames arrive first, `runID` changes and this task is
            // replaced by one that sleeps toward the new, later end.
            let playable = durations.reduce(0, +)
            let remaining = playable - Date().timeIntervalSince(start)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
                if Task.isCancelled { return }
            }
            // The buffer ran dry: hold this frame as a still while rebuffering.
            bufferStallElapsed = min(playable, Date().timeIntervalSince(start))
            return
        }

        guard playback.isPlaying != nil else { return }
        let loops = effectiveLoopCount(source)
        guard loops != 0 else { return }   // loops forever: never auto-stops

        let playLength = durations.reduce(0, +) * Double(loops)
        let remaining = playLength - Date().timeIntervalSince(start)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
            if Task.isCancelled { return }
        }
        pausedElapsed = playLength
        playback.isPlaying?.wrappedValue = false
    }

    /// Whether a finite animation has already played to its end (and is holding
    /// on the last frame). Always `false` for an infinite loop.
    private func isCompleted(_ durations: [Double]) -> Bool {
        guard let source else { return false }
        let loops = effectiveLoopCount(source)
        guard loops != 0, let elapsed = pausedElapsed else { return false }
        return elapsed >= durations.reduce(0, +) * Double(loops)
    }

    /// The loop count passed to the schedule, resolving the requested ``loop``
    /// mode against the source's own loop count.
    private func effectiveLoopCount(_ source: AnimatedImageSource) -> Int {
        switch playback.loop {
        case .source: return source.loopCount
        case .once: return 1
        case .forever: return 0
        case .count(let n): return Swift.max(1, n)
        }
    }

    /// The loop count for the running schedule. While the file is still
    /// downloading, the buffered frames play through linearly exactly once,
    /// freezing on the last one if the buffer runs dry; the requested loop
    /// behavior takes over when loading completes.
    private func scheduleLoopCount(_ source: AnimatedImageSource) -> Int {
        source.isComplete ? effectiveLoopCount(source) : 1
    }
}

/// Seconds of frames that must be buffered ahead before streaming playback
/// starts, and again before it resumes after running dry (HLS-style).
private let animatedImageBufferSeconds: Double = 2.0

/// A mutable box for the last frame put on screen. Written while rendering as a
/// memo (deliberately not observed state), so the fallback for a frame whose
/// decode is not ready can be "whatever is showing now" instead of frame 0.
private final class FrameHolder {
    var image: CGImage?
}

// MARK: - Plain, Image-like initializers & modifiers

extension AnimatedImage where Content == Image {

    /// Creates an animated image using a resource in a bundle.
    ///
    /// - Parameters:
    ///   - name: The name of the resource. An extension (e.g. `"gif"`) is optional.
    ///   - bundle: The bundle to search for the resource. Defaults to the main bundle.
    ///   - scale: The scale factor of the image. Defaults to `1`.
    ///   - playback: The playback configuration. Defaults to ``AnimatedImagePlayback/automatic``.
    public init(
        _ name: String,
        bundle: Bundle = .main,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic
    ) {
        self.init(source: animatedImageSource(name: name, bundle: bundle), scale: scale, id: AnyHashable(name), playback: playback, transform: { $0 })
    }

    /// Creates an animated image from the contents of a file URL.
    public init(
        contentsOf url: URL,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic
    ) {
        self.init(source: AnimatedImageDecoder.decode(url: url), scale: scale, id: AnyHashable(url), playback: playback, transform: { $0 })
    }

    /// Creates an animated image from in-memory data.
    public init(
        data: Data,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic
    ) {
        self.init(source: AnimatedImageDecoder.decode(data: data), scale: scale, id: AnyHashable(data), playback: playback, transform: { $0 })
    }

    /// Creates an animated image from a named resource, enabling a type-safe,
    /// non-literal call site such as `AnimatedImage(.spinner)`.
    public init(
        _ resource: AnimatedImageResource,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic
    ) {
        self.init(source: animatedImageSource(name: resource.name, bundle: resource.bundle), scale: scale, id: AnyHashable(resource), playback: playback, transform: { $0 })
    }

    /// Sets the mode by which SwiftUI resizes the image to fit its space.
    ///
    /// Mirrors `Image/resizable(capInsets:resizingMode:)`. Compose with the usual
    /// layout modifiers (`aspectRatio`, `scaledToFit`, `frame`, …) exactly as you
    /// would for an `Image`.
    public func resizable(
        capInsets: EdgeInsets = EdgeInsets(),
        resizingMode: Image.ResizingMode = .stretch
    ) -> AnimatedImage<Image> {
        AnimatedImage<Image>(source: source, scale: scale, id: id, playback: playback) { image in
            image.resizable(capInsets: capInsets, resizingMode: resizingMode)
        }
    }
}

// MARK: - Transforming initializers

extension AnimatedImage {

    /// Creates an animated image using a resource in a bundle, styling each frame
    /// with a custom transform of the underlying `Image`.
    public init(
        _ name: String,
        bundle: Bundle = .main,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.init(source: animatedImageSource(name: name, bundle: bundle), scale: scale, id: AnyHashable(name), playback: playback, transform: content)
    }

    /// Creates an animated image from a file URL, styling each frame with a custom
    /// transform of the underlying `Image`.
    public init(
        contentsOf url: URL,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.init(source: AnimatedImageDecoder.decode(url: url), scale: scale, id: AnyHashable(url), playback: playback, transform: content)
    }

    /// Creates an animated image from in-memory data, styling each frame with a
    /// custom transform of the underlying `Image`.
    public init(
        data: Data,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.init(source: AnimatedImageDecoder.decode(data: data), scale: scale, id: AnyHashable(data), playback: playback, transform: content)
    }

    /// Creates an animated image from a named resource, styling each frame with a
    /// custom transform of the underlying `Image`.
    public init(
        _ resource: AnimatedImageResource,
        scale: CGFloat = 1,
        playback: AnimatedImagePlayback = .automatic,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.init(source: animatedImageSource(name: resource.name, bundle: resource.bundle), scale: scale, id: AnyHashable(resource), playback: playback, transform: content)
    }
}

// MARK: - Resource resolution

/// Resolves a named animation, preferring a loose resource file in the bundle and
/// falling back to an asset-catalog **data set** of the same name — so
/// `AnimatedImage("Confetti")` works whether the GIF ships as a file or as a data
/// set, just like `Image(_:)` finds an image set by name.
private func animatedImageSource(name: String, bundle: Bundle) -> AnimatedImageSource? {
    // Share one decoded source (and its frame cache) across every view that refers
    // to the same named resource, so a large animation is only decoded once.
    let cacheKey = "name:\(bundle.bundlePath)/\(name)"
    if let cached = AnimatedImageSourceCache.shared.source(forKey: cacheKey) {
        return cached
    }

    let source: AnimatedImageSource?
    if let url = animatedImageResourceURL(name: name, bundle: bundle) {
        source = AnimatedImageDecoder.decode(url: url)
    } else {
        #if canImport(UIKit) || canImport(AppKit)
        source = NSDataAsset(name: name, bundle: bundle).flatMap { AnimatedImageDecoder.decode(data: $0.data) }
        #else
        source = nil
        #endif
    }

    if let source {
        AnimatedImageSourceCache.shared.insert(source, forKey: cacheKey)
    }
    return source
}

private func animatedImageResourceURL(name: String, bundle: Bundle) -> URL? {
    let nsName = name as NSString
    let providedExtension = nsName.pathExtension
    let baseName = nsName.deletingPathExtension

    if !providedExtension.isEmpty,
       let url = bundle.url(forResource: baseName, withExtension: providedExtension) {
        return url
    }

    for fileExtension in ["gif", "GIF", "png", "apng", "webp"] {
        if let url = bundle.url(forResource: name, withExtension: fileExtension) {
            return url
        }
    }

    return bundle.url(forResource: name, withExtension: nil)
}
