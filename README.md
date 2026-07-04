# AnimatedImage
AnimatedImage is a tiny SwiftUI package for displaying animated images (GIF, APNG, and animated WebP) with an API that mirrors SwiftUI's own `Image` and `AsyncImage`.  
Use `AnimatedImage` to load a local animation from a bundle resource, file URL, or in-memory `Data`, and `AsyncAnimatedImage` to load one over the network. Playback is driven by a `TimelineView`, and frames are decoded lazily so even a large animation stays memory-friendly.

## Features and Futures
I would like the framework to have the following features
- [x] `Image`-shaped API for local animations (bundle resource, file URL, `Data`)
- [x] `AsyncImage`-shaped API for remote animations
- [x] Full resizing & aspect-ratio control via a `content` closure over each frame
- [x] `TimelineView`-driven playback that honors per-frame durations and pauses off-screen
- [x] Lazy, bounded-cache frame decoding for large animations
- [x] Playback control: loop forever, play once, loop *N* times, or play/pause via `Binding<Bool>`
- [x] Formats: GIF, APNG, and animated WebP

## Requirements

| Platform | Minimum |
| --- | --- |
| iOS | 17 |
| macOS | 14 |
| tvOS | 17 |
| watchOS | 10 |
| visionOS | 1 |

## Usage

### Local images
```swift
import AnimatedImage

// A bundle resource named "loading.gif" (the extension is optional).
AnimatedImage("loading")

// From a file URL or in-memory Data.
AnimatedImage(contentsOf: fileURL)
AnimatedImage(data: gifData)
```

The name initializer also resolves an asset-catalog **data set** of the same name, so a GIF shipped as a data set works with no extra ceremony:
```swift
AnimatedImage("Confetti")   // a "Confetti" data set in an asset catalog
```

For a type-safe, non-literal call site (like `Image(.sample)`), declare a shortcut on `AnimatedImageResource`. Xcode only auto-generates symbols for image and color sets, so you add data-set shortcuts yourself:
```swift
extension AnimatedImageResource {
    static let confetti = AnimatedImageResource(name: "Confetti")
}

AnimatedImage(.confetti)
```

### Resizing & aspect ratio
Like `Image`, `AnimatedImage` is not resizable by default. Call `resizable()` and compose the usual layout modifiers:
```swift
AnimatedImage("loading")
    .resizable()
    .scaledToFit()
    .frame(width: 120, height: 120)
```

For full control, use the `content` closure — it receives each frame as an `Image`, so every image modifier is available:
```swift
AnimatedImage("loading") { image in
    image
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
}
```

### Playback control
Configure playback with the `playback:` parameter:
```swift
AnimatedImage("spinner", playback: .forever)          // loop indefinitely
AnimatedImage("celebrate", playback: .once)           // play once, then hold
AnimatedImage("wave", playback: .init(loop: .count(3)))
```

Drive play/pause with a `Binding<Bool>`. It is two-way: `false` pauses on the current frame and `true` resumes; for a finite animation the view flips it to `false` when playback finishes, and setting it back to `true` replays from the top:
```swift
struct DemoView: View {
    @State private var isPlaying = true

    var body: some View {
        VStack {
            AnimatedImage("spinner", playback: .init(loop: .forever, isPlaying: $isPlaying))
                .resizable()
                .scaledToFit()

            Toggle("Playing", isOn: $isPlaying)
        }
    }
}
```

### Remote images
`AsyncAnimatedImage` mirrors `AsyncImage`:
```swift
// Simplest form — shown at its native size, like AsyncImage(url:).
AsyncAnimatedImage(url: URL(string: "https://example.com/loading.gif"))

// Custom content + placeholder.
AsyncAnimatedImage(url: url) { image in
    image.resizable().scaledToFit()
} placeholder: {
    ProgressView()
}

// Full phase control — switch over the loading phase, like AsyncImage.
AsyncAnimatedImage(url: url) { phase in
    switch phase {
    case .empty:
        ProgressView()
    case .success(let image):
        image.resizable().scaledToFit()
    case .failure:
        Image(systemName: "wifi.slash")
    }
}
```

`AsyncAnimatedImage` streams the download and shows the **first frame as a still as soon as its bytes arrive**, then swaps in the full animation once the download finishes — so a large remote GIF appears quickly instead of blocking on the whole file. Decoded animations are also cached in memory by URL, so an `AsyncAnimatedImage` that reappears reuses the already-decoded source instead of downloading and decoding again (entries are evicted under memory pressure). This is on top of the HTTP-level caching performed by the underlying `URLSession`.

## Installation
You can add it to your project using the Swift Package Manager. To add AnimatedImage to your Xcode project, select File > Add Package Dependencies... and find the repository URL:  
`https://github.com/KC-2001MS/AnimatedImage.git`.

## Contributions
See [CONTRIBUTING.md](https://github.com/KC-2001MS/AnimatedImage/blob/main/CONTRIBUTING.md) if you want to make a contribution.

## Documents
Documentation on the AnimatedImage framework can be found [here](https://iroiro.dev/AnimatedImage/documentation/animatedimage/).

## License
This library is released under Apache-2.0 license. See [LICENSE](https://github.com/KC-2001MS/AnimatedImage/blob/main/LICENSE) for details.

## Supporting
If you would like to make a donation to this project, please click here. The money you give will be used to improve my programming skills and maintain the application.  
<a href="https://www.buymeacoffee.com/iroiro" target="_blank">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" >
</a>  
[Pay by PayPal](https://paypal.me/iroiroWork?country.x=JP&locale.x=ja_JP)

## Author
[Keisuke Chinone](https://github.com/KC-2001MS)
