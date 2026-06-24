import AVKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import CoreTransferable
import PhotosUI
import UIKit
#endif

struct ContentView: View {
    @StateObject private var viewModel = ViralCaptionsViewModel()
    @State private var showingVideoImporter = false
    @State private var showingSRTImporter = false
    #if os(iOS)
    @State private var selectedVideoItem: PhotosPickerItem?
    #endif

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
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        HeaderView()

                        if proxy.size.width >= 940 {
                            HStack(alignment: .top, spacing: 18) {
                                VStack(spacing: 18) {
                                    APIKeyCard(viewModel: viewModel)
                                    MediaCard(
                                        viewModel: viewModel,
                                        onPickVideo: pickVideo,
                                        onPickSRT: pickSRT
                                    )
                                    TemplateCard(viewModel: viewModel)
                                }
                                .frame(maxWidth: 460)

                                VStack(spacing: 18) {
                                    OptionsCard(viewModel: viewModel)
                                    RenderCard(viewModel: viewModel)
                                    ResultCard(viewModel: viewModel)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 18) {
                                APIKeyCard(viewModel: viewModel)
                                MediaCard(
                                    viewModel: viewModel,
                                    onPickVideo: pickVideo,
                                    onPickSRT: pickSRT
                                )
                                TemplateCard(viewModel: viewModel)
                                OptionsCard(viewModel: viewModel)
                                RenderCard(viewModel: viewModel)
                                ResultCard(viewModel: viewModel)
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
            .navigationTitle("Viral Captions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .tint(Brand.navy)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        Button(action: pickVideo) {
                            Label("Choose video", systemImage: "plus")
                        }
                        .buttonStyle(.glass)

                        Button(action: pickSRT) {
                            Label("SRT", systemImage: "text.badge.plus")
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button(action: pickVideo) {
                            Label("Choose video", systemImage: "plus")
                        }

                        Button(action: pickSRT) {
                            Label("SRT", systemImage: "text.badge.plus")
                        }
                    }
                }
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
        Task {
            do {
                guard let movie = try await item.loadTransferable(type: PickedVideo.self) else {
                    await MainActor.run {
                        viewModel.alert = AppMessage(title: "Video import failed", message: "Could not read the selected video.")
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
                    viewModel.alert = AppMessage(title: "Video import failed", message: error.localizedDescription)
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

private struct AppBackground: View {
    var body: some View {
        Brand.softSurface.ignoresSafeArea()
    }
}

private struct HeaderView: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.navy)
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("SUBCLIP")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(Brand.navy)
                    Text("API")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.cyan)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background {
                        LiquidGlassCapsuleSurface(
                            fill: Brand.surface,
                            tint: Brand.cyan,
                            fillOpacity: 0.9,
                            strokeOpacity: 0.9,
                            shadowOpacity: 0
                        )
                    }
                    .liquidGlassCapsule(tint: Brand.cyan)
                }
                Text("Viral Captions")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                    .minimumScaleFactor(0.8)
                Text("Upload, render, preview, and share captioned MP4s.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.slate)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct APIKeyCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "API Key", systemImage: "key.fill")
                SecureField("Subclip API key", text: $viewModel.apiKey)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                LiquidGlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            viewModel.saveAPIKey()
                        } label: {
                            Label("Save key", systemImage: "checkmark.seal.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button {
                            viewModel.clearAPIKey()
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityLabel("Remove saved API key")
                    }
                }

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
    var onPickSRT: () -> Void

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "Media", systemImage: "film.fill")

                VideoPreview(url: viewModel.selectedVideo?.url)
                    .frame(height: viewModel.selectedVideo == nil ? 180 : 260)

                if let video = viewModel.selectedVideo {
                    VStack(spacing: 8) {
                        MetricRow(title: video.fileName, value: video.metadata.durationLabel, icon: "clock")
                        HStack(spacing: 8) {
                            MetricPill(text: video.metadata.sizeLabel, systemImage: "externaldrive")
                            MetricPill(text: video.metadata.dimensionsLabel, systemImage: "rectangle.inset.filled")
                            MetricPill(text: video.metadata.contentType, systemImage: "doc")
                        }
                    }
                }

                LiquidGlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button(action: onPickVideo) {
                            Label(viewModel.selectedVideo == nil ? "Choose video" : "Replace video", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button(action: onPickSRT) {
                            Label("SRT", systemImage: "text.badge.plus")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }

                if let srt = viewModel.selectedSRT {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(Brand.navy)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(srt.fileName)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(srt.sizeLabel)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Brand.muted)
                        }
                        Spacer(minLength: 0)
                        Button {
                            viewModel.removeSRT()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background {
                        LiquidGlassSurface(cornerRadius: 8, tint: Brand.navy)
                    }
                    .liquidGlass(cornerRadius: 8, tint: Brand.navy)
                }
            }
        }
    }
}

private struct TemplateCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Style", systemImage: "sparkles")

                ScrollView(.horizontal, showsIndicators: false) {
                    LiquidGlassGroup(spacing: 10) {
                        HStack(spacing: 10) {
                            ForEach(CaptionTemplate.all) { template in
                                TemplateButton(
                                    template: template,
                                    selected: template.id == viewModel.selectedTemplateId
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
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    TemplatePreviewVideo(template: template, isSelected: selected)

                    Text(template.name)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? .white : Brand.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background {
                            LiquidGlassSurface(
                                cornerRadius: 6,
                                fill: selected ? Brand.navy : Brand.surface,
                                tint: selected ? Brand.cyan : Brand.line,
                                fillOpacity: selected ? 0.95 : 0.9,
                                strokeOpacity: selected ? 0.4 : 0.8,
                                shadowOpacity: 0,
                                interactive: false
                            )
                        }
                        .liquidGlass(cornerRadius: 6, tint: selected ? Brand.cyan : Brand.line)
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
            .background {
                LiquidGlassSurface(
                    cornerRadius: 8,
                    fill: Brand.surface,
                    tint: selected ? Brand.cyan : Brand.line,
                    fillOpacity: 0.92,
                    strokeOpacity: selected ? 0.9 : 0.72,
                    shadowOpacity: selected ? 0.04 : 0.015,
                    interactive: true
                )
            }
            .liquidGlass(cornerRadius: 8, tint: selected ? Brand.cyan : Brand.line, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

private struct TemplatePreviewVideo: View {
    let template: CaptionTemplate
    let isSelected: Bool
    @State private var player: AVPlayer?
    @State private var isHovering = false

    private var shouldPlay: Bool {
        isSelected || isHovering
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
                        .tint(Brand.navy)
                @unknown default:
                    EmptyView()
                }
            }

            if shouldPlay, let player {
                PlayerLayerView(player: player)
                    .transition(.opacity.animation(.easeOut(duration: 0.16)))
            }
        }
        .clipped()
        .onAppear {
            updatePlayback()
        }
        .onDisappear {
            player?.pause()
        }
        .onChange(of: template.id) { _, _ in
            player = nil
            updatePlayback()
        }
        .onChange(of: shouldPlay) { _, _ in
            updatePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
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
            player?.pause()
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
}

#if os(macOS)
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PreviewPlayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class PreviewPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer = playerLayer
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#else
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PreviewPlayerView, context: Context) {
        uiView.playerLayer.player = player
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
        playerLayer.videoGravity = .resizeAspectFill
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
        .buttonStyle(SecondaryButtonStyle())
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
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? .white : Brand.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .background {
                    LiquidGlassSurface(
                        cornerRadius: 8,
                        fill: selected ? Brand.navy : Brand.surface,
                        tint: selected ? Brand.cyan : Brand.line,
                        fillOpacity: selected ? 0.95 : 0.9,
                        strokeOpacity: selected ? 0.42 : 0.72,
                        shadowOpacity: selected ? 0.035 : 0.01,
                        interactive: true
                    )
                }
                .liquidGlass(cornerRadius: 8, tint: selected ? Brand.cyan : Brand.line, interactive: true)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 86, maxWidth: 132)
    }
}

private struct OptionsCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "Render Settings", systemImage: "slider.horizontal.3")

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

                Toggle(isOn: $viewModel.faceTrack) {
                    Label("Face tracking", systemImage: "face.smiling")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                }
                .tint(Brand.navy)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Output File")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.slate)
                    TextField("captioned-video.mp4", text: $viewModel.outputFileName)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
            }
        }
    }
}

private struct RenderCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "Render", systemImage: "bolt.fill")

                if #available(iOS 26.0, macOS 26.0, *) {
                    Button {
                        viewModel.render()
                    } label: {
                        HStack(spacing: 10) {
                            if viewModel.isRendering {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(viewModel.isRendering ? viewModel.phase.label : "Render video")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.navy)
                    .disabled(!viewModel.canRender)
                } else {
                    Button {
                        viewModel.render()
                    } label: {
                        HStack(spacing: 10) {
                            if viewModel.isRendering {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(viewModel.isRendering ? viewModel.phase.label : "Render video")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(isDisabled: !viewModel.canRender))
                    .disabled(!viewModel.canRender)
                }

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
                        .tint(Brand.navy)

                    Text(viewModel.statusMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background {
                    LiquidGlassSurface(cornerRadius: 8, tint: Brand.navy)
                }
                .liquidGlass(cornerRadius: 8, tint: Brand.navy)

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

private struct ResultCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "Result", systemImage: "square.and.arrow.down.fill")

                VideoPreview(url: viewModel.outputURL)
                    .frame(height: viewModel.outputURL == nil ? 180 : 320)

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

                    ShareLink(item: outputURL) {
                        Label("Share or save MP4", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.surface)

            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    }

    private func configurePlayer() {
        guard let url else {
            player = nil
            return
        }
        player = AVPlayer(url: url)
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
                .background {
                    LiquidGlassSurface(
                        cornerRadius: 7,
                        fill: Brand.surface,
                        tint: Brand.navy,
                        fillOpacity: 0.86,
                        strokeOpacity: 0.12,
                        shadowOpacity: 0,
                        interactive: false
                    )
                }
                .liquidGlass(cornerRadius: 7, tint: Brand.navy)
            .frame(width: 30, height: 30)

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
            .background {
                LiquidGlassCapsuleSurface(
                    fill: Brand.surface,
                    tint: Brand.line,
                    fillOpacity: 0.9,
                    strokeOpacity: 0.74,
                    shadowOpacity: 0,
                    interactive: false
                )
            }
            .liquidGlassCapsule(tint: Brand.line)
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
        .background {
            LiquidGlassSurface(cornerRadius: 8, tint: Brand.navy)
        }
        .liquidGlass(cornerRadius: 8, tint: Brand.navy)
    }
}

#Preview {
    ContentView()
}
