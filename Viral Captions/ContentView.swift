import AVFoundation
import AVKit
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
    @State private var isShowingResultScreen = false
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
            .onAppear {
                preflightPhotoPermission()
            }
            .onChange(of: viewModel.resultPreviewURL) { _, previewURL in
                isShowingResultScreen = previewURL != nil
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
                onSaveOutput: saveURL
            )
            .tabItem {
                Label("Create", systemImage: "wand.and.stars")
            }
            .tag(AppTab.create)

            NavigationStack {
                SettingsWorkspace(
                    viewModel: viewModel,
                    appearanceModeRaw: $appearanceModeRaw,
                    onDownloadHistory: downloadHistory
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
        .overlay {
            if viewModel.isTranscribing {
                TranscriptionProgressOverlay(viewModel: viewModel)
                    .transition(.opacity)
            } else if viewModel.isSRTEditorPresented {
                SRTEditorOverlay(viewModel: viewModel)
                    .transition(.opacity)
            } else if viewModel.isRendering {
                RenderProgressOverlay(viewModel: viewModel)
                    .transition(.opacity)
            } else if isShowingResultScreen, viewModel.resultPreviewURL != nil {
                OutputReadyOverlay(
                    viewModel: viewModel,
                    onClose: { isShowingResultScreen = false },
                    onDownload: saveURL
                )
                .transition(.opacity)
            }
        }
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
        Task {
            guard let outputURL = await viewModel.downloadCurrentOutput() else { return }
            await MainActor.run {
                saveURL(outputURL)
            }
        }
    }

    private func saveURL(_ outputURL: URL) {
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

    private func downloadHistory(_ item: LocalUploadQueueItem) {
        Task {
            guard await viewModel.openHistoryItem(item) else { return }
            await MainActor.run {
                isShowingResultScreen = true
            }
        }
    }

    #if os(iOS)
    private func preflightPhotoPermission() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .notDetermined else { return }
        Task {
            _ = await requestPhotoAddAuthorization()
        }
    }

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
    var onSaveOutput: (URL) -> Void

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
                                if viewModel.hasResult {
                                    ResultCard(
                                        viewModel: viewModel,
                                        onSaveOutput: onSaveOutput
                                    )
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
                            if viewModel.hasResult {
                                ResultCard(
                                    viewModel: viewModel,
                                    onSaveOutput: onSaveOutput
                                )
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
    var onDownloadHistory: (LocalUploadQueueItem) -> Void

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
                                LocalQueueCard(viewModel: viewModel, onOpen: onDownloadHistory)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 18) {
                            APIKeyCard(viewModel: viewModel)
                            ThemeSettingsCard(selectionRaw: $appearanceModeRaw)
                            LocalQueueCard(viewModel: viewModel, onOpen: onDownloadHistory)
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

    private var labelColor: Color {
        prominent ? .white : Brand.ink
    }

    private var progressColor: Color {
        prominent ? .white : Brand.navy
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(labelColor)
                } else {
                    Image(systemName: "plus")
                }

                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity)

            if isLoading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(progressColor)
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
                        .padding(.horizontal, 8)
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
    @State private var isShowingFullPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                TemplatePreviewVideo(template: template, playbackEnabled: playbackEnabled)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            isShowingFullPreview = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Brand.ink)
                                .frame(width: 30, height: 30)
                                .nativeGlassPanel(cornerRadius: 15, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Preview \(template.name) full screen")
                    }
                    Spacer()
                }
                .padding(.top, 14)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

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
            .frame(width: 150, height: 267)
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
                    .stroke(Brand.navy, lineWidth: 2.5)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
        .shadow(color: selected ? Brand.navy.opacity(0.20) : .clear, radius: 10, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: action)
        #if os(iOS)
        .fullScreenCover(isPresented: $isShowingFullPreview) {
            if let url = template.previewVideoURL {
                FullScreenVideoPlayer(url: url, isPresented: $isShowingFullPreview)
            }
        }
        #else
        .sheet(isPresented: $isShowingFullPreview) {
            if let url = template.previewVideoURL {
                FullScreenVideoPlayer(url: url, isPresented: $isShowingFullPreview)
                    .frame(minWidth: 420, minHeight: 680)
            }
        }
        #endif
    }
}

private struct TemplatePreviewVideo: View {
    let template: CaptionTemplate
    let playbackEnabled: Bool
    @State private var player: AVPlayer?

    private var shouldPlay: Bool {
        playbackEnabled
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

            if let player {
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
    @ObservedObject var viewModel: ViralCaptionsViewModel

    private let rows: [[CaptionPlacement]] = [
        [.none, .bottom],
        [.top, .middle]
    ]

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row) { placement in
                            OptionChip(
                                title: placement.label,
                                systemImage: icon(for: placement),
                                selected: placement == viewModel.placement
                            ) {
                                viewModel.selectPlacement(placement)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func icon(for placement: CaptionPlacement) -> String {
        switch placement {
        case .none:
            return "location.slash"
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
        .buttonStyle(.plain)
        .nativeGlassCapsule(interactive: true)
        .overlay {
            if selected {
                Capsule()
                    .stroke(.primary.opacity(0.24), lineWidth: 1.25)
            }
        }
        .frame(minWidth: 86, maxWidth: .infinity)
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

                    Text("Advanced Settings")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    Spacer(minLength: 0)

                    Button {
                        isExpanded.toggle()
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
                            PlacementControl(viewModel: viewModel)
                        }

                        Toggle(
                            isOn: Binding(
                                get: { viewModel.faceTrack },
                                set: { viewModel.setFaceTrack($0) }
                            )
                        ) {
                            Label("Face tracking", systemImage: "face.smiling")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Advanced")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Brand.slate)
                            LocalTranscriptionControl(viewModel: viewModel)
                            SRTAttachmentControl(viewModel: viewModel, onPickSRT: onPickSRT)
                        }
                    }
                    .transition(.identity)
                }
            }
        }
        .animation(nil, value: isExpanded)
        .task(id: viewModel.selectedLanguage) {
            await viewModel.refreshLocalTranscriptionSupport()
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
        case .none:
            return "location.slash"
        case .top:
            return "align.vertical.top.fill"
        case .middle:
            return "align.vertical.center.fill"
        case .bottom:
            return "align.vertical.bottom.fill"
        }
    }
}

private struct LocalTranscriptionControl: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    var body: some View {
        if viewModel.localTranscriptionSupported {
            Button {
                viewModel.transcribeSelectedVideo()
            } label: {
                Label(viewModel.isTranscribing ? "Transcribing" : "Transcribe audio", systemImage: "waveform")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .nativeGlassButton()
            .disabled(viewModel.selectedVideo == nil || viewModel.isTranscribing)
        }
    }
}

private struct SRTAttachmentControl: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onPickSRT: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let srt = viewModel.selectedSRT {
                VStack(alignment: .leading, spacing: 10) {
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

                    Button {
                        viewModel.openSRTEditor()
                    } label: {
                        Label("Edit SRT", systemImage: "square.and.pencil")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                    }
                    .nativeGlassButton()
                }
                .padding(10)
                .nativeGlassPanel(cornerRadius: 8)
            }

            Button(action: onPickSRT) {
                Label(viewModel.selectedSRT == nil ? "Attach SRT" : "Replace SRT", systemImage: "text.badge.plus")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .nativeGlassButton()
        }
    }
}

private struct LocalQueueCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onOpen: (LocalUploadQueueItem) -> Void

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    CardHeader(title: "History", systemImage: "clock.arrow.circlepath")
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
                    Text("Completed caption renders will appear here for quick download.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Brand.slate)
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.uploadQueue) { item in
                            LocalQueueRow(item: item, onOpen: { onOpen(item) })
                        }
                    }
                }
            }
        }
    }
}

private struct LocalQueueRow: View {
    let item: LocalUploadQueueItem
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
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
                    if let creditsLabel = item.creditsLabel {
                        MetricPill(text: creditsLabel, systemImage: "sparkles.tv")
                    }
                    if let timeRemaining = item.downloadTimeRemainingLabel {
                        MetricPill(text: timeRemaining, systemImage: "timer")
                    }
                    if let outputFileName = item.outputFileName {
                        MetricPill(text: outputFileName, systemImage: "square.and.arrow.down")
                    }
                }

                if item.isDownloadAvailable {
                    Label("Open result", systemImage: "play.rectangle.fill")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .nativeGlassCapsule(interactive: true)
                }
            }
            .padding(10)
            .nativeGlassPanel(cornerRadius: 8, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!item.isDownloadAvailable)
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

                if viewModel.phase == .failed {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Could not add captions")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Brand.ink)
                            Spacer(minLength: 0)
                        }

                        Text(viewModel.statusMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .nativeGlassPanel(cornerRadius: 8)
                }
            }
        }
    }
}

private struct TranscriptionProgressOverlay: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var percent: Int {
        Int((viewModel.transcriptionProgress * 100).rounded())
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Brand.softSurface
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Brand.ink
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.66) : Brand.slate
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                backgroundColor.ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer(minLength: proxy.size.height * 0.16)

                    VStack(spacing: 10) {
                        Text("\(percent)%")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(primaryTextColor)
                        Text(viewModel.transcriptionStatus.isEmpty ? "Transcribing audio" : viewModel.transcriptionStatus)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(secondaryTextColor)
                            .multilineTextAlignment(.center)
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .fill(Brand.surface.opacity(0.72))
                        Image(systemName: "waveform")
                            .font(.system(size: 54, weight: .bold))
                            .foregroundStyle(Brand.navy)
                        RoundedRectProgressShape(progress: viewModel.transcriptionProgress, cornerRadius: 34, inset: 4)
                            .stroke(Brand.navy, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    }
                    .frame(
                        width: min(proxy.size.width * 0.68, 360),
                        height: min(proxy.size.height * 0.30, 280)
                    )

                    Text("Generating a local SRT from this video's audio.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Spacer(minLength: proxy.size.height * 0.08)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button {
                    viewModel.cancelTranscription()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(primaryTextColor)
                        .frame(width: 48, height: 48)
                        .background(Brand.surface.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
                .padding(.trailing, 18)
            }
        }
    }
}

private struct SRTEditorOverlay: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Brand.softSurface
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Brand.ink
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backgroundColor.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.navy)
                        .frame(width: 36, height: 36)
                        .nativeGlassPanel(cornerRadius: 8)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Edit SRT")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(primaryTextColor)
                        Text(viewModel.selectedSRT?.fileName ?? "captions.srt")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                TextEditor(text: $viewModel.srtDraft)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .nativeGlassPanel(cornerRadius: 8, interactive: true)

                Button {
                    viewModel.saveSRTDraft()
                } label: {
                    Label("Save SRT", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .nativeGlassButton(prominent: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 82)
            .padding(.bottom, 24)

            Button {
                viewModel.isSRTEditorPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(primaryTextColor)
                    .frame(width: 48, height: 48)
                    .background(Brand.surface.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
    }
}

private struct RenderProgressOverlay: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var percent: Int {
        Int((viewModel.progress * 100).rounded())
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Brand.softSurface
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Brand.ink
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.66) : Brand.slate
    }

    private var detailText: String {
        switch viewModel.phase {
        case .creatingUpload:
            return "Preparing your video."
        case .uploadingVideo, .uploadingSRT:
            return "Uploading media."
        case .startingJob, .polling:
            return "Adding captions on Subclip."
        case .downloading:
            return "Downloading the final MP4."
        default:
            return "Working on your video."
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                backgroundColor
                    .ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer(minLength: proxy.size.height * 0.08)

                    VStack(spacing: 10) {
                        Text("\(percent)%")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(primaryTextColor)
                        Text(viewModel.phase.label)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(secondaryTextColor)
                    }

                    RenderProgressPreview(
                        url: viewModel.selectedVideo?.url,
                        progress: viewModel.progress,
                        autoplay: false
                    )
                    .frame(size: overlayPreviewSize(in: proxy.size, aspectRatio: viewModel.aspectRatio.previewAspect))

                    Text(detailText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Spacer(minLength: proxy.size.height * 0.06)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button {
                    viewModel.cancelRender()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(primaryTextColor)
                        .frame(width: 48, height: 48)
                        .background(Brand.surface.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
                .padding(.trailing, 18)
            }
        }
    }
}

private struct RenderProgressPreview: View {
    let url: URL?
    let progress: Double
    var autoplay = false
    var showsProgressBorder = true
    @State private var player: AVPlayer?

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        ZStack {
            if showsProgressBorder {
                RoundedRectProgressShape(progress: 1, cornerRadius: 34, inset: 4)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 8)
            }

            if let player {
                PlayerLayerView(player: player, videoGravity: .resizeAspectFill)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(showsProgressBorder ? 18 : 0)
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Brand.surface)
                    .padding(showsProgressBorder ? 18 : 0)
            }

            if showsProgressBorder {
                RoundedRectProgressShape(progress: clampedProgress, cornerRadius: 34, inset: 4)
                    .stroke(Brand.navy, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    .animation(.easeInOut(duration: 0.25), value: clampedProgress)
            }
        }
        .onAppear {
            configurePlayer()
        }
        .onChange(of: url) { _, _ in
            configurePlayer()
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let currentItem = player?.currentItem,
                  notification.object as? AVPlayerItem === currentItem else {
                return
            }
            currentItem.seek(to: .zero, completionHandler: nil)
            player?.play()
        }
    }

    private func configurePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        guard let url else {
            player = nil
            return
        }
        let nextPlayer = AVPlayer(url: url)
        nextPlayer.isMuted = true
        nextPlayer.actionAtItemEnd = .none
        if autoplay {
            nextPlayer.play()
        }
        player = nextPlayer
    }
}

private func overlayPreviewSize(
    in container: CGSize,
    aspectRatio: CGFloat,
    maxWidthFraction: CGFloat = 0.68,
    maxWidth: CGFloat = 360,
    maxHeightFraction: CGFloat = 0.58,
    maxHeight: CGFloat = 640
) -> CGSize {
    let safeAspect = max(0.2, min(4, aspectRatio))
    let availableWidth = min(container.width * maxWidthFraction, maxWidth)
    let availableHeight = min(container.height * maxHeightFraction, maxHeight)
    let width = min(availableWidth, availableHeight * safeAspect)
    return CGSize(width: width, height: width / safeAspect)
}

private extension View {
    func frame(size: CGSize) -> some View {
        frame(width: size.width, height: size.height)
    }
}

private struct RoundedRectProgressShape: Shape {
    var progress: Double
    var cornerRadius: CGFloat
    var inset: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(1, max(0, progress))
        guard clamped > 0, rect.width > 0, rect.height > 0 else {
            return Path()
        }

        let drawingRect = rect.insetBy(dx: inset, dy: inset)
        guard drawingRect.width > 0, drawingRect.height > 0 else {
            return Path()
        }

        let radius = min(max(0, cornerRadius - inset), min(drawingRect.width, drawingRect.height) / 2)
        let minX = drawingRect.minX
        let midX = drawingRect.midX
        let maxX = drawingRect.maxX
        let minY = drawingRect.minY
        let maxY = drawingRect.maxY

        var outline = Path()
        outline.move(to: CGPoint(x: midX, y: minY))
        outline.addLine(to: CGPoint(x: maxX - radius, y: minY))
        outline.addArc(
            center: CGPoint(x: maxX - radius, y: minY + radius),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        outline.addLine(to: CGPoint(x: maxX, y: maxY - radius))
        outline.addArc(
            center: CGPoint(x: maxX - radius, y: maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        outline.addLine(to: CGPoint(x: minX + radius, y: maxY))
        outline.addArc(
            center: CGPoint(x: minX + radius, y: maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        outline.addLine(to: CGPoint(x: minX, y: minY + radius))
        outline.addArc(
            center: CGPoint(x: minX + radius, y: minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        outline.addLine(to: CGPoint(x: midX, y: minY))

        return outline.trimmedPath(from: 0, to: CGFloat(clamped))
    }
}

private struct OutputReadyOverlay: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onClose: () -> Void
    var onDownload: (URL) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : Brand.softSurface
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Brand.ink
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.70) : Brand.slate
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                backgroundColor.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        if let previewURL = viewModel.resultPreviewURL {
                            RenderProgressPreview(
                                url: previewURL,
                                progress: 1,
                                autoplay: true,
                                showsProgressBorder: false
                            )
                                .frame(
                                    size: overlayPreviewSize(
                                        in: proxy.size,
                                        aspectRatio: (viewModel.resultAspectRatio ?? viewModel.aspectRatio).previewAspect,
                                        maxHeightFraction: 0.54,
                                        maxHeight: 590
                                    )
                                )

                            ShareDestinationGrid(viewModel: viewModel, onSaveOutput: onDownload)
                                .padding(.horizontal, 24)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 92)
                    .padding(.bottom, 36)
                }
                .task(id: viewModel.resultPreviewURL) {
                    viewModel.cacheCurrentOutput()
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(primaryTextColor)
                        .frame(width: 52, height: 52)
                        .background(Brand.surface.opacity(0.74), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 20)
                .padding(.trailing, 20)
            }
        }
    }
}

private struct ResultCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onSaveOutput: (URL) -> Void

    var body: some View {
        BrandCard {
            VStack(alignment: .center, spacing: 18) {
                CardHeader(title: "Ready to Share", systemImage: "square.and.arrow.up.fill")

                Text("Your captioned MP4 is ready.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.slate)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let previewURL = viewModel.resultPreviewURL {
                    VideoPreview(url: previewURL)
                        .aspectRatio(viewModel.aspectRatio.previewAspect, contentMode: .fit)
                        .frame(maxWidth: viewModel.aspectRatio.previewMaxWidth)
                        .frame(maxWidth: .infinity)

                    ShareDestinationGrid(viewModel: viewModel, onSaveOutput: onSaveOutput)
                }
            }
        }
    }
}

private struct ShareDestinationGrid: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onSaveOutput: (URL) -> Void
    @State private var isPreparingDownload = false
    @State private var isPreparingShare = false
    @State private var shareItem: ShareSheetItem?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            Button {
                prepareDownload()
            } label: {
                ShareDestinationTile(
                    title: isPreparingDownload ? "Preparing" : "Download",
                    systemImage: "arrow.down.to.line",
                    isLoading: isPreparingDownload
                )
            }
            .buttonStyle(.plain)
            .disabled(isPreparingDownload)

            Button {
                prepareShare()
            } label: {
                ShareDestinationTile(
                    title: isPreparingShare ? "Preparing" : "Share",
                    systemImage: "square.and.arrow.up",
                    isLoading: isPreparingShare
                )
            }
            .buttonStyle(.plain)
            .disabled(isPreparingShare)
        }
        #if os(iOS)
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(url: item.url, title: item.title)
        }
        #endif
    }

    private func prepareDownload() {
        guard !isPreparingDownload else { return }
        isPreparingDownload = true
        Task {
            let outputURL = await viewModel.downloadCurrentOutput()
            await MainActor.run {
                isPreparingDownload = false
                guard let outputURL else { return }
                onSaveOutput(outputURL)
            }
        }
    }

    private func prepareShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            let outputURL = await viewModel.downloadCurrentOutput()
            await MainActor.run {
                isPreparingShare = false
                guard let outputURL else { return }
                #if os(iOS)
                shareItem = ShareSheetItem(url: outputURL, title: viewModel.outputSuggestedFileName ?? outputURL.lastPathComponent)
                #else
                viewModel.alert = AppMessage(title: "MP4 ready", message: outputURL.path)
                #endif
            }
        }
    }
}

private struct ShareDestinationTile: View {
    let title: String
    let systemImage: String
    var isLoading = false

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(Brand.navy)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Brand.navy)
                }
            }
            .frame(width: 70, height: 70)
            .nativeGlassPanel(cornerRadius: 18, interactive: true)

            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

#if os(iOS)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    let title: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [VideoActivityItemSource(url: url, title: title)],
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

private final class VideoActivityItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        title
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.mpeg4Movie.identifier
    }
}
#endif

private struct VideoPreview: View {
    let url: URL?
    @State private var player: AVPlayer?
    @State private var isShowingFullPlayer = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.surface)

            if let player {
                PlayerLayerView(player: player, videoGravity: .resizeAspect)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            isShowingFullPlayer = true
                        } label: {
                            Image(systemName: "play.fill")
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
        #if os(iOS)
        .fullScreenCover(isPresented: $isShowingFullPlayer) {
            if let url {
                FullScreenVideoPlayer(url: url, isPresented: $isShowingFullPlayer)
            }
        }
        #else
        .sheet(isPresented: $isShowingFullPlayer) {
            if let url {
                FullScreenVideoPlayer(url: url, isPresented: $isShowingFullPlayer)
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
        #endif
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

    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

private struct FullScreenVideoPlayer: View {
    let url: URL
    @Binding var isPresented: Bool
    @State private var player = AVPlayer()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding()
        }
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.isMuted = false
            player.play()
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
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

#Preview {
    ContentView()
}
