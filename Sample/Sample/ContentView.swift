import SwiftUI
import AnimatedImage

// A type-safe shortcut for the "Sample" asset, enabling `AnimatedImage(.sample)`.
extension AnimatedImageResource {
    static let sample = AnimatedImageResource(name: "Sample")
}

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {

    /// A file URL produced at launch by writing the asset-catalog GIF out to a
    /// temporary file. It backs the `AnimatedImage(contentsOf:)` demo so that the
    /// file-URL path renders without shipping a separate loose file.
    @State private var localFileURL: URL?

    /// Play-once state for demo #7. Flips to `false` when the animation finishes;
    /// the replay button sets it back to `true`.
    @State private var isPlayingOnce = true

    /// Two-way play/pause state for the Binding demo (#8).
    @State private var isPlaying = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {

                    // MARK: 1. By name — like Image("…")
                    // Resolves a loose bundle resource or an asset-catalog data set of
                    // the same name, so this one call covers both. "Sample" here is a
                    // data set in Assets.xcassets.
                    DemoSection(
                        title: "1. 名前指定 (アセットカタログ / バンドル)",
                        code: #"AnimatedImage("Sample")"#
                    ) {
                        AnimatedImage("Sample")
                            .resizable()
                            .scaledToFit()
                    }

                    // MARK: 2. Type-safe resource — like Image(.sample)
                    // `AnimatedImageResource.sample` is declared at the top of this file,
                    // giving a non-literal, autocompletion-friendly call site.
                    DemoSection(
                        title: "2. リソース指定 (.sample)",
                        code: "AnimatedImage(.sample)"
                    ) {
                        AnimatedImage(.sample)
                            .resizable()
                            .scaledToFit()
                    }

                    // MARK: 3. File URL
                    DemoSection(
                        title: "3. ファイル URL",
                        code: "AnimatedImage(contentsOf: fileURL)"
                    ) {
                        if let localFileURL {
                            AnimatedImage(contentsOf: localFileURL)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }

                    // MARK: 4. Remote (simple) — mirrors AsyncImage(url:): the loaded
                    // image is shown at its native pixel size and is not resizable,
                    // so it is clipped to the card here.
                    DemoSection(
                        title: "4. リモート (シンプル・原寸表示)",
                        code: "AsyncAnimatedImage(url: url)  // 原寸・非resizable"
                    ) {
                        AsyncAnimatedImage(url: URL(string: "https://upload.wikimedia.org/wikipedia/commons/5/5e/%22Popcorn_cumulus%22_cloud_streets_in_the_Southeast_U_S_%28CIRA_2018-08-22%29.gif"))
                    }

                    // MARK: 5. Remote (custom content + placeholder)
                    DemoSection(
                        title: "5. リモート (プレースホルダ付き)",
                        code: "AsyncAnimatedImage(url:) { $0.resizable()… } placeholder: { ProgressView() }"
                    ) {
                        AsyncAnimatedImage(url: URL(string: "https://upload.wikimedia.org/wikipedia/commons/5/5e/%22Popcorn_cumulus%22_cloud_streets_in_the_Southeast_U_S_%28CIRA_2018-08-22%29.gif")) { image in
                            image
                                .resizable()
                                .scaledToFit()
                        } placeholder: {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }

                    // MARK: 6. Remote (phase switch) — like AsyncImage's phase closure
                    DemoSection(
                        title: "6. リモート (フェーズ切り替え)",
                        code: "AsyncAnimatedImage(url:) { phase in switch phase { … } }"
                    ) {
                        AsyncAnimatedImage(url: URL(string: "https://upload.wikimedia.org/wikipedia/commons/5/5e/%22Popcorn_cumulus%22_cloud_streets_in_the_Southeast_U_S_%28CIRA_2018-08-22%29.gif")) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                Label("読み込み失敗", systemImage: "wifi.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // MARK: 7. Modifier showcase (circular clip)
                    DemoSection(
                        title: "7. 修飾子の組み合わせ (円形クリップ)",
                        code: #"AnimatedImage("Sample").resizable().scaledToFill()…clipShape(.circle)"#
                    ) {
                        AnimatedImage("Sample")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 160, height: 160)
                            .clipShape(.circle)
                            .overlay(Circle().stroke(.tint, lineWidth: 3))
                            .frame(maxWidth: .infinity)
                    }

                    // MARK: 8. Play once + replay (via the Bool binding)
                    // `.once` plays a single time then freezes and flips `isPlayingOnce`
                    // to false; the button sets it true again to replay from the top.
                    DemoSection(
                        title: "8. 1回再生 + リプレイ (Binding)",
                        code: #"AnimatedImage("Sample", playback: .init(loop: .once, isPlaying: $playing))"#
                    ) {
                        VStack(spacing: 12) {
                            AnimatedImage("Sample", playback: .init(loop: .once, isPlaying: $isPlayingOnce))
                                .resizable()
                                .scaledToFit()
                            Button("もう一度再生", systemImage: "arrow.clockwise") {
                                isPlayingOnce = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isPlayingOnce)
                        }
                        .padding()
                    }

                    // MARK: 9. Play / pause via a Bool binding
                    // `isPlaying` drives playback both ways: toggling it pauses/resumes,
                    // and the view would set it false itself if the loop were finite.
                    DemoSection(
                        title: "9. 再生 / 一時停止 (Binding<Bool>)",
                        code: #"AnimatedImage("Sample", playback: .init(loop: .forever, isPlaying: $isPlaying))"#
                    ) {
                        VStack(spacing: 12) {
                            AnimatedImage("Sample", playback: .init(loop: .forever, isPlaying: $isPlaying))
                                .resizable()
                                .scaledToFit()
                            Toggle("再生中", isOn: $isPlaying)
                                .fixedSize()
                        }
                        .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("AnimatedImage")
        }
        .task {
            localFileURL = exportAssetToTemporaryFile()
        }
    }

    /// Writes the bundled "Sample" data-set GIF to a temporary file so the
    /// `AnimatedImage(contentsOf:)` demo has a real file URL to load.
    private func exportAssetToTemporaryFile() -> URL? {
        guard let data = NSDataAsset(name: "Sample")?.data else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sample.gif")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// A labeled card that frames one demonstration of the framework alongside the
/// snippet of code that produces it.
private struct DemoSection<Content: View>: View {
    let title: String
    let code: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            content
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 220)
                .clipShape(.rect(cornerRadius: 12))
                .background(Color(white: 0.95), in: .rect(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
