import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import CoreTransferable
import Photos
import PhotosUI
import UIKit
#endif

struct ContentView: View {
    @StateObject private var viewModel = ViralCaptionsViewModel()
    @State private var showingVideoImporter = false
    @State private var showingSRTImporter = false
    @State private var selectedTab: AppTab = .create
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppAppearance.light.rawValue
    #if os(iOS)
    @State private var selectedVideoItem: PhotosPickerItem?
    #endif

    private var appearanceMode: AppAppearance {
        AppAppearance(rawValue: appearanceModeRaw) ?? .light
    }

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        appContent
            .alert(item: $viewModel.alert) { message in
                Alert(
                    title: Text(message.title),
                    message: Text(message.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        #else
        appContent
            .photosPicker(
                isPresented: $showingVideoImporter,
                selection: $selectedVideoItem,
                matching: .videos,
                photoLibrary: .shared()
            )
            .onChange(of: selectedVideoItem) { _, item in
                importPickedVideo(item)
            }
            .fileImporter(
                isPresented: $showingSRTImporter,
                allowedContentTypes: [.srt, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result, mediaType: .srt)
            }
            .alert(item: $viewModel.alert) { message in
                Alert(
                    title: Text(message.title),
                    message: Text(message.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        #endif
    }

    private var appContent: some View {
        TabView(selection: $selectedTab) {
            CreateWorkspace(
                viewModel: viewModel,
                onPickVideo: pickVideo,
                onPickSRT: pickSRT,
                onSaveOutput: saveOutput
            )
            .tabItem {
                Label("Create", systemImage: "wand.and.stars")
            }
            .tag(AppTab.create)

            NavigationStack {
                SettingsWorkspace(
                    viewModel: viewModel,
                    appearanceModeRaw: $appearanceModeRaw
                )
                .navigationTitle("Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
        .preferredColorScheme(appearanceMode.colorScheme)
    }

    private enum ImportMediaType {
        case video
        case srt
    }

    private func handleImport(_ result: Result<[URL], Error>, mediaType: ImportMediaType) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            switch mediaType {
            case .video:
                viewModel.importVideo(from: url)
            case .srt:
                viewModel.importSRT(from: url)
            }
        case .failure(let error):
            viewModel.alert = AppMessage(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func pickVideo() {
        #if os(macOS)
        openPanel(
            title: "Choose video",
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        ) { url in
            viewModel.importVideo(from: url)
        }
        #else
        showingVideoImporter = true
        #endif
    }

    private func pickSRT() {
        #if os(macOS)
        openPanel(title: "Choose SRT", allowedContentTypes: [.srt, .plainText]) { url in
            viewModel.importSRT(from: url)
        }
        #else
        showingSRTImporter = true
        #endif
    }

    private func saveOutput() {
        guard let outputURL = viewModel.outputURL else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Save MP4"
        panel.nameFieldStringValue = outputURL.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                viewModel.saveOutputCopy(to: destination)
            }
        }
        #else
        saveOutputToPhotos(outputURL)
        #endif
    }

    #if os(iOS)
    private func saveOutputToPhotos(_ outputURL: URL) {
        Task {
            do {
                let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                let authorized = status == .authorized || status == .limited
                let nextStatus = authorized ? status : await requestPhotoAddAuthorization()
                guard nextStatus == .authorized || nextStatus == .limited else {
                    await MainActor.run {
                        viewModel.alert = AppMessage(
                            title: "Photos access needed",
                            message: "Allow Photos access to save the rendered MP4 to your library."
                        )
                    }
                    return
                }

                try await writeVideoToPhotos(outputURL)

                await MainActor.run {
                    viewModel.alert = AppMessage(title: "MP4 saved", message: "The rendered video was saved to Photos.")
                }
            } catch {
                await MainActor.run {
                    viewModel.alert = AppMessage(title: "Could not save to Photos", message: error.localizedDescription)
                }
            }
        }
    }

    private func requestPhotoAddAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func writeVideoToPhotos(_ outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private func openPanel(
        title: String,
        allowedContentTypes: [UTType],
        onSelect: @escaping @MainActor (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                onSelect(url)
            }
        }
    }
    #endif

    #if os(iOS)
    private func importPickedVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        viewModel.beginVideoImport()
        Task {
            do {
                guard let movie = try await item.loadTransferable(type: PickedVideo.self) else {
                    await MainActor.run {
                        selectedVideoItem = nil
                        viewModel.failVideoImport(message: "Could not read the selected video.")
                    }
                    return
                }

                await MainActor.run {
                    selectedVideoItem = nil
                    viewModel.importVideo(from: movie.url)
                }
            } catch {
                await MainActor.run {
                    selectedVideoItem = nil
                    viewModel.failVideoImport(message: error.localizedDescription)
                }
            }
        }
    }
    #endif
}

#if os(iOS)
private struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fileExtension = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideo(url: destination)
        }
    }
}
#endif

private enum AppTab: Hashable {
    case create
    case settings
}

private enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .system:
            return "System"
        }
    }

    var icon: String {
        switch self {
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        case .system:
            return "circle.lefthalf.filled"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return nil
        }
    }
}

private struct CreateWorkspace: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onPickVideo: () -> Void
    var onPickSRT: () -> Void
    var onSaveOutput: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    if proxy.size.width >= 940 {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 18) {
                                MediaCard(
                                    viewModel: viewModel,
                                    onPickVideo: onPickVideo
                                )
                                TemplateCard(viewModel: viewModel)
                            }
                            .frame(maxWidth: 500)

                            VStack(spacing: 18) {
                                if viewModel.selectedVideo != nil {
                                    CoreRenderOptionsCard(viewModel: viewModel, onPickSRT: onPickSRT)
                                    RenderCard(viewModel: viewModel)
                                }
                                if viewModel.outputURL != nil {
                                    ResultCard(viewModel: viewModel, onSaveOutput: onSaveOutput)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 18) {
                            MediaCard(
                                viewModel: viewModel,
                                onPickVideo: onPickVideo
                            )
                            TemplateCard(viewModel: viewModel)
                            if viewModel.selectedVideo != nil {
                                CoreRenderOptionsCard(viewModel: viewModel, onPickSRT: onPickSRT)
                                RenderCard(viewModel: viewModel)
                            }
                            if viewModel.outputURL != nil {
                                ResultCard(viewModel: viewModel, onSaveOutput: onSaveOutput)
                            }
                        }
                    }
                }
                .frame(maxWidth: 1180)
                .padding(.horizontal, proxy.size.width < 520 ? 14 : 24)
                .padding(.vertical, proxy.size.width < 520 ? 16 : 26)
                .frame(maxWidth: .infinity)
            }
            .background(AppBackground())
        }
    }
}

private struct SettingsWorkspace: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    @Binding var appearanceModeRaw: String

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    if proxy.size.width >= 940 {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 18) {
                                APIKeyCard(viewModel: viewModel)
                                ThemeSettingsCard(selectionRaw: $appearanceModeRaw)
                            }
                            .frame(maxWidth: 520)

                            VStack(spacing: 18) {
                                LocalQueueCard(viewModel: viewModel)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 18) {
                            APIKeyCard(viewModel: viewModel)
                            ThemeSettingsCard(selectionRaw: $appearanceModeRaw)
                            LocalQueueCard(viewModel: viewModel)
                        }
                    }
                }
                .frame(maxWidth: 1180)
                .padding(.horizontal, proxy.size.width < 520 ? 14 : 24)
                .padding(.vertical, proxy.size.width < 520 ? 16 : 26)
                .frame(maxWidth: .infinity)
            }
            .background(AppBackground())
        }
    }
}

private struct AppBackground: View {
    var body: some View {
        Brand.softSurface.ignoresSafeArea()
    }
}

private struct APIKeyCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    @FocusState private var apiKeyFocused: Bool

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "API Key", systemImage: "key.fill")
                SecureField(
                    "Subclip API key",
                    text: $viewModel.apiKey,
                    prompt: Text("Subclip API key").foregroundColor(.secondary)
                )
                    .focused($apiKeyFocused)
                    .brandedInputField()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        apiKeyFocused = false
                    }
                    #endif

                LiquidGlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            apiKeyFocused = false
                            #if os(iOS)
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil,
                                from: nil,
                                for: nil
                            )
                            #endif
                            viewModel.saveAPIKey()
                        } label: {
                            Label("Save key", systemImage: "checkmark.seal.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .nativeGlassButton()

                        Button {
                            viewModel.clearAPIKey()
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 34, height: 34)
                        }
                        .nativeGlassButton()
                        .accessibilityLabel("Remove saved API key")
                    }
                }

                Link(destination: URL(string: "https://subclip.app/account/api")!) {
                    Label("Get API key from Subclip", systemImage: "key.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .nativeGlassButton()

                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Brand.navy)
                    Text("Stored locally in Keychain.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Brand.muted)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct MediaCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onPickVideo: () -> Void

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "Media", systemImage: "film.fill")

                if let video = viewModel.selectedVideo {
                    ZStack {
                        SelectedVideoSummary(video: video)
                        if viewModel.isImportingVideo {
                            VideoImportOverlay(progress: viewModel.videoImportProgress)
                        }
                    }
                }

                LiquidGlassGroup(spacing: 10) {
                    VStack(spacing: 10) {
                        Button {
                            guard !viewModel.isImportingVideo else { return }
                            onPickVideo()
                        } label: {
                            VideoPickerButtonLabel(
                                title: videoButtonTitle,
                                isLoading: viewModel.isImportingVideo,
                                progress: viewModel.videoImportProgress,
                                prominent: viewModel.selectedVideo == nil
                            )
                        }
                        .nativeGlassButton(prominent: viewModel.selectedVideo == nil)

                        if viewModel.selectedVideo != nil {
                            Button {
                                viewModel.render()
                            } label: {
                                Label(viewModel.isRendering ? viewModel.phase.label : "Add Captions", systemImage: "wand.and.stars")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(Brand.ink)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                            }
                            .nativeGlassButton()
                            .disabled(!viewModel.canRender)
                        }
                    }
                }
            }
        }
    }

    private var videoButtonTitle: String {
        if viewModel.isImportingVideo { return "Loading video" }
        return viewModel.selectedVideo == nil ? "Choose video" : "Replace video"
    }
}

private struct VideoPickerButtonLabel: View {
    let title: String
    let isLoading: Bool
    let progress: Double
    let prominent: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(prominent ? .white : Brand.ink)
                } else {
                    Image(systemName: "plus")
                }

                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .foregroundStyle(prominent ? .white : Brand.ink)
            .frame(maxWidth: .infinity)

            if isLoading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(prominent ? .white : Brand.navy)
                    .frame(maxWidth: 220)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct SelectedVideoSummary: View {
    let video: SelectedVideo

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VideoPreview(url: video.url)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(width: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text("Video selected")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                Text("Ready to add captions.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.slate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Brand.navy)
        }
        .padding(10)
        .nativeGlassPanel(cornerRadius: 8)
    }
}

private struct VideoImportOverlay: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading video")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Brand.ink)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 180)
        }
        .padding(18)
        .nativeGlassPanel(cornerRadius: 8)
    }
}

private struct TemplateCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Choose Style", systemImage: "sparkles")

                ScrollView(.horizontal, showsIndicators: false) {
                    LiquidGlassGroup(spacing: 10) {
                        LazyHStack(spacing: 10) {
                            ForEach(CaptionTemplate.all) { template in
                                TemplateButton(
                                    template: template,
                                    selected: template.id == viewModel.selectedTemplateId,
                                    playbackEnabled: !viewModel.isRendering
                                ) {
                                    viewModel.selectedTemplateId = template.id
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct TemplateButton: View {
    let template: CaptionTemplate
    let selected: Bool
    let playbackEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    TemplatePreviewVideo(template: template, playbackEnabled: playbackEnabled)

                    Text(template.name)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .nativeGlassPanel(cornerRadius: 6)
                        .padding(8)
                }
                .frame(width: 150, height: 224)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Brand.line, lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                    Text(template.description)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 150, alignment: .leading)
            .padding(10)
            .nativeGlassPanel(cornerRadius: 8, interactive: true)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.primary.opacity(0.35), lineWidth: 1.5)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct TemplatePreviewVideo: View {
    let template: CaptionTemplate
    let playbackEnabled: Bool
    @State private var player: AVPlayer?
    @State private var isHovering = false

    private var shouldPlay: Bool {
        playbackEnabled && isHovering
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Brand.surface)

            AsyncImage(url: template.previewThumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Image(systemName: "film")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Brand.navy)
                case .empty:
                    ProgressView()
                        .controlSize(.small)
                @unknown default:
                    EmptyView()
                }
            }

            if shouldPlay, let player {
                PlayerLayerView(player: player, videoGravity: .resizeAspectFill)
                    .transition(.opacity.animation(.easeOut(duration: 0.16)))
            }
        }
        .clipped()
        .onAppear {
            updatePlayback()
        }
        .onDisappear {
            stopPlayback()
        }
        .onChange(of: template.id) { _, _ in
            stopPlayback()
            updatePlayback()
        }
        .onChange(of: playbackEnabled) { _, _ in
            updatePlayback()
        }
        .onChange(of: shouldPlay) { _, _ in
            updatePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard shouldPlay else { return }
            guard let currentItem = player?.currentItem,
                  notification.object as? AVPlayerItem === currentItem else {
                return
            }
            currentItem.seek(to: .zero, completionHandler: nil)
            player?.play()
        }
        #if os(macOS)
        .onHover { hovering in
            isHovering = hovering
        }
        #endif
    }

    private func updatePlayback() {
        guard shouldPlay, let url = template.previewVideoURL else {
            stopPlayback()
            return
        }

        if player == nil {
            let nextPlayer = AVPlayer(url: url)
            nextPlayer.isMuted = true
            nextPlayer.actionAtItemEnd = .none
            player = nextPlayer
        }
        player?.play()
    }

    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

#if os(macOS)
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView()
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PreviewPlayerView, context: Context) {
        nsView.playerLayer.videoGravity = videoGravity
        nsView.playerLayer.player = player
    }

    static func dismantleNSView(_ nsView: PreviewPlayerView, coordinator: ()) {
        nsView.playerLayer.player?.pause()
        nsView.playerLayer.player = nil
    }
}

private final class PreviewPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        playerLayer.frame = bounds
    }
}
#else
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView()
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PreviewPlayerView, context: Context) {
        uiView.playerLayer.videoGravity = videoGravity
        uiView.playerLayer.player = player
    }

    static func dismantleUIView(_ uiView: PreviewPlayerView, coordinator: ()) {
        uiView.playerLayer.player?.pause()
        uiView.playerLayer.player = nil
    }
}

private final class PreviewPlayerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as? AVPlayerLayer ?? AVPlayerLayer()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        nil
    }
}
#endif

private struct LanguageMenu: View {
    @Binding var selection: String

    private var selectedOption: LanguageOption {
        LanguageOption.all.first(where: { $0.id == selection }) ?? LanguageOption.all[0]
    }

    var body: some View {
        Menu {
            ForEach(LanguageOption.all) { option in
                Button {
                    selection = option.id
                } label: {
                    HStack {
                        Text("\(option.name) (\(option.id))")
                        if option.id == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(selectedOption.name) (\(selectedOption.id))")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Brand.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .nativeGlassButton()
    }
}

private struct AspectRatioControl: View {
    @Binding var selection: OutputAspectRatio

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(OutputAspectRatio.allCases) { ratio in
                    OptionChip(
                        title: ratio.rawValue,
                        systemImage: aspectIcon(for: ratio),
                        selected: ratio == selection
                    ) {
                        selection = ratio
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func aspectIcon(for ratio: OutputAspectRatio) -> String {
        switch ratio {
        case .vertical:
            return "rectangle.portrait"
        case .landscape:
            return "rectangle"
        case .square:
            return "square"
        }
    }
}

private struct PlacementControl: View {
    @Binding var selection: CaptionPlacement

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(CaptionPlacement.allCases) { placement in
                    OptionChip(
                        title: placement.label,
                        systemImage: icon(for: placement),
                        selected: placement == selection
                    ) {
                        selection = placement
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func icon(for placement: CaptionPlacement) -> String {
        switch placement {
        case .top:
            return "align.vertical.top.fill"
        case .middle:
            return "align.vertical.center.fill"
        case .bottom:
            return "align.vertical.bottom.fill"
        }
    }
}

private struct OptionChip: View {
    let title: String
    let systemImage: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if selected {
                chipLabel
                    .foregroundStyle(.primary)
            } else {
                chipLabel
                    .foregroundStyle(.secondary)
            }
        }
        .nativeGlassButton()
        .overlay {
            if selected {
                Capsule()
                    .stroke(.primary.opacity(0.24), lineWidth: 1.25)
            }
        }
        .frame(minWidth: 86, maxWidth: 132)
    }

    private var chipLabel: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
    }
}

private struct CoreRenderOptionsCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onPickSRT: () -> Void
    @State private var isExpanded = false

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Brand.navy)
                        .frame(width: 30, height: 30)
                        .nativeGlassPanel(cornerRadius: 7)

                    Text("Render Settings")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .frame(width: 34, height: 34)
                    }
                    .nativeGlassButton()
                    .accessibilityLabel(isExpanded ? "Collapse render settings" : "Expand render settings")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    MetricPill(text: languageSummary, systemImage: "textformat")
                    MetricPill(text: viewModel.aspectRatio.rawValue, systemImage: aspectIcon)
                    MetricPill(text: viewModel.placement.label, systemImage: placementIcon)
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Language")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Brand.slate)
                            LanguageMenu(selection: $viewModel.selectedLanguage)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Aspect Ratio")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Brand.slate)
                            AspectRatioControl(selection: $viewModel.aspectRatio)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Placement")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Brand.slate)
                            PlacementControl(selection: $viewModel.placement)
                        }

                        Toggle(
                            isOn: Binding(
                                get: { viewModel.faceTrackApplies && viewModel.faceTrack },
                                set: { viewModel.faceTrack = $0 }
                            )
                        ) {
                            Label("Face tracking", systemImage: "face.smiling")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                        }
                        .disabled(!viewModel.faceTrackApplies)
                        .opacity(viewModel.faceTrackApplies ? 1 : 0.55)

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Advanced")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Brand.slate)
                            SRTAttachmentControl(viewModel: viewModel, onPickSRT: onPickSRT)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var languageSummary: String {
        let option = LanguageOption.all.first(where: { $0.id == viewModel.selectedLanguage }) ?? LanguageOption.all[0]
        return option.id == "auto" ? "Auto" : option.name
    }

    private var aspectIcon: String {
        switch viewModel.aspectRatio {
        case .vertical:
            return "rectangle.portrait"
        case .landscape:
            return "rectangle"
        case .square:
            return "square"
        }
    }

    private var placementIcon: String {
        switch viewModel.placement {
        case .top:
            return "align.vertical.top.fill"
        case .middle:
            return "align.vertical.center.fill"
        case .bottom:
            return "align.vertical.bottom.fill"
        }
    }
}

private struct SRTAttachmentControl: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onPickSRT: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onPickSRT) {
                Label(viewModel.selectedSRT == nil ? "Attach SRT" : "Replace SRT", systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .nativeGlassButton()

            if let srt = viewModel.selectedSRT {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(Brand.navy)
                    Text(srt.fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        viewModel.removeSRT()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 30, height: 30)
                    }
                    .nativeGlassButton()
                    .accessibilityLabel("Remove SRT")
                }
                .padding(10)
                .nativeGlassPanel(cornerRadius: 8)
            }
        }
    }
}

private struct LocalQueueCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    CardHeader(title: "Local Queue", systemImage: "tray.full.fill")
                    if !viewModel.uploadQueue.isEmpty {
                        Button {
                            viewModel.clearUploadQueue()
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 32, height: 32)
                        }
                        .nativeGlassButton()
                        .accessibilityLabel("Clear local queue")
                    }
                }

                if viewModel.uploadQueue.isEmpty {
                    Text("Uploaded videos will appear here after a render starts.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Brand.slate)
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.uploadQueue) { item in
                            LocalQueueRow(item: item)
                        }
                    }
                }
            }
        }
    }
}

private struct LocalQueueRow: View {
    let item: LocalUploadQueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundStyle(Brand.navy)
                Text(item.fileName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(item.status)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                MetricPill(text: item.aspectRatio, systemImage: "rectangle.on.rectangle")
                MetricPill(text: item.templateId, systemImage: "sparkles")
                if let outputFileName = item.outputFileName {
                    MetricPill(text: outputFileName, systemImage: "square.and.arrow.down")
                }
            }
        }
        .padding(10)
        .nativeGlassPanel(cornerRadius: 8)
    }
}

private struct ThemeSettingsCard: View {
    @Binding var selectionRaw: String

    private var selection: AppAppearance {
        AppAppearance(rawValue: selectionRaw) ?? .light
    }

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "Appearance", systemImage: "circle.lefthalf.filled")

                LiquidGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Button {
                                selectionRaw = appearance.rawValue
                            } label: {
                                Label(appearance.label, systemImage: appearance.icon)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .nativeGlassButton(prominent: selection == appearance)
                        }
                    }
                }
            }
        }
    }
}

private struct RenderCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    private var renderLabelOpacity: Double {
        viewModel.canRender ? 1 : 0.45
    }

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "Add Captions", systemImage: "bolt.fill")

                Button {
                    viewModel.render()
                } label: {
                    HStack(spacing: 10) {
                        if viewModel.isRendering {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(viewModel.isRendering ? viewModel.phase.label : "Add Captions")
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.navy.opacity(renderLabelOpacity))
                    .frame(maxWidth: .infinity)
                }
                .nativeGlassButton()
                .disabled(!viewModel.canRender)

                if viewModel.phase != .idle || viewModel.projectId != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(viewModel.phase.label)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Brand.ink)
                            Spacer(minLength: 0)
                            Text("\(Int(viewModel.progress * 100))%")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Brand.navy)
                        }

                        ProgressView(value: viewModel.progress)

                        Text(viewModel.statusMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .nativeGlassPanel(cornerRadius: 8)
                }

                if viewModel.projectId != nil || viewModel.estimatedCredits != nil || viewModel.creditsUsed != nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        if let projectId = viewModel.projectId {
                            MiniStat(label: "Project", value: projectId)
                        }
                        if let estimatedCredits = viewModel.estimatedCredits {
                            MiniStat(label: "Estimated", value: "\(estimatedCredits.formatted(.number.precision(.fractionLength(2)))) credits")
                        }
                        if let creditsUsed = viewModel.creditsUsed {
                            MiniStat(label: "Used", value: "\(creditsUsed.formatted(.number.precision(.fractionLength(2)))) credits")
                        }
                    }
                }
            }
        }
    }
}

private struct ResultCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onSaveOutput: () -> Void

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "Result", systemImage: "square.and.arrow.down.fill")

                if viewModel.outputURL == nil {
                    VideoPreview(url: nil)
                        .frame(height: 180)
                } else {
                    VideoPreview(url: viewModel.outputURL)
                        .aspectRatio(viewModel.aspectRatio.previewAspect, contentMode: .fit)
                        .frame(maxWidth: viewModel.aspectRatio.previewMaxWidth)
                        .frame(maxWidth: .infinity)
                }

                if let outputURL = viewModel.outputURL {
                    HStack(spacing: 8) {
                        MetricPill(text: outputURL.lastPathComponent, systemImage: "video.fill")
                        if let outputFileSize = viewModel.outputFileSize {
                            MetricPill(
                                text: ByteCountFormatter.string(fromByteCount: outputFileSize, countStyle: .file),
                                systemImage: "externaldrive.fill"
                            )
                        }
                    }

                    LiquidGlassGroup(spacing: 10) {
                        HStack(spacing: 10) {
                            Button(action: onSaveOutput) {
                                Label("Save MP4", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .nativeGlassButton()

                            ShareLink(item: outputURL) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .nativeGlassButton()
                        }
                    }
                } else {
                    Text("The rendered MP4 will appear here.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Brand.muted)
                }
            }
        }
    }
}

private struct VideoPreview: View {
    let url: URL?
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.surface)

            if let player {
                PlayerLayerView(player: player, videoGravity: .resizeAspect)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            togglePlayback()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Brand.ink)
                                .frame(width: 36, height: 36)
                        }
                        .nativeGlassButton()
                        .padding(10)
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Brand.navy)
                    Text("No video selected")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Brand.line, lineWidth: 1)
        }
        .onAppear {
            configurePlayer()
        }
        .onChange(of: url) { _, _ in
            configurePlayer()
        }
        .onDisappear {
            stopPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let currentItem = player?.currentItem,
                  notification.object as? AVPlayerItem === currentItem else {
                return
            }
            currentItem.seek(to: .zero, completionHandler: nil)
            player?.pause()
            isPlaying = false
        }
    }

    private func configurePlayer() {
        stopPlayback()
        guard let url else {
            return
        }
        let nextPlayer = AVPlayer(url: url)
        nextPlayer.isMuted = true
        nextPlayer.actionAtItemEnd = .pause
        player = nextPlayer
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
    }
}

private struct CardHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Brand.navy)
                .frame(width: 30, height: 30)
                .nativeGlassPanel(cornerRadius: 7)

            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.ink)
            Spacer(minLength: 0)
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Brand.navy)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.slate)
        }
    }
}

private struct MetricPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Brand.slate)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .nativeGlassCapsule()
    }
}

private struct MiniStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Brand.muted)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .nativeGlassPanel(cornerRadius: 8)
    }
}

#Preview {
    ContentView()
}
