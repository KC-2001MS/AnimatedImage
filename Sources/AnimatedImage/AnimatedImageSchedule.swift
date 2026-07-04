import Foundation
import SwiftUI

/// A `TimelineSchedule` that fires at each frame boundary of an animated image,
/// honoring per-frame durations and the loop count.
///
/// Combined with ``animatedImageFrameIndex(elapsed:durations:loopCount:)`` this
/// lets a `TimelineView` drive playback directly off the system clock — no
/// background task, no manual `sleep` loop — and pauses automatically when the
/// hosting view is off-screen or the app is in the background.
struct AnimatedImageSchedule: TimelineSchedule {

    /// The instant playback began. Elapsed time is measured from here.
    let start: Date
    /// Per-frame display durations, in seconds.
    let durations: [Double]
    /// The number of times to repeat. `0` means loop forever.
    let loopCount: Int

    func entries(from: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(start: start, from: from, durations: durations, loopCount: loopCount)
    }

    /// Lazily yields `from`, then every subsequent frame-boundary date. For a
    /// finite loop count it stops after the final frame, freezing on it.
    struct Entries: Sequence, IteratorProtocol {
        private let start: Date
        private let from: Date
        private let count: Int
        private let total: Double
        private let offsets: [Double]
        private let maxFrame: Int          // exclusive; `Int.max` when looping forever
        private var nextFrame: Int
        private var emittedInitial = false

        init(start: Date, from: Date, durations: [Double], loopCount: Int) {
            self.start = start
            self.from = from
            self.count = durations.count

            var running = 0.0
            var offs: [Double] = []
            offs.reserveCapacity(durations.count)
            for duration in durations {
                offs.append(running)
                running += duration
            }
            self.offsets = offs
            self.total = running
            self.maxFrame = loopCount == 0 ? Int.max : Swift.max(0, durations.count * loopCount)

            // Jump straight to the loop that `from` falls in so we don't iterate
            // through every past boundary when the app has been running a while.
            if running > 0, durations.count > 0 {
                let elapsed = Swift.max(0, from.timeIntervalSince(start))
                self.nextFrame = Int(elapsed / running) * durations.count
            } else {
                self.nextFrame = 0
            }
        }

        private func date(forGlobalFrame n: Int) -> Date {
            let loop = n / count
            let index = n % count
            return start.addingTimeInterval(Double(loop) * total + offsets[index])
        }

        mutating func next() -> Date? {
            // Emit `from` first so the view renders the correct frame immediately.
            if !emittedInitial {
                emittedInitial = true
                return from
            }
            guard total > 0, count > 0 else { return nil }
            while nextFrame < maxFrame {
                let candidate = date(forGlobalFrame: nextFrame)
                nextFrame += 1
                if candidate > from {
                    return candidate
                }
            }
            return nil
        }
    }
}

/// The frame index to display for a given elapsed time since playback started,
/// honoring variable per-frame durations and the loop count. A finite loop count
/// freezes on the last frame once the animation completes.
func animatedImageFrameIndex(elapsed: Double, durations: [Double], loopCount: Int) -> Int {
    let total = durations.reduce(0, +)
    guard total > 0, !durations.isEmpty else { return 0 }

    let clamped = max(0, elapsed)
    if loopCount != 0, clamped >= total * Double(loopCount) {
        return durations.count - 1
    }

    var offset = clamped.truncatingRemainder(dividingBy: total)
    for (index, duration) in durations.enumerated() {
        if offset < duration { return index }
        offset -= duration
    }
    return durations.count - 1
}
