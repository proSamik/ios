import AVFoundation
import AVKit
import BetterAuth
import Combine
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import CoreTransferable
import Photos
import PhotosUI
import RevenueCatUI
import UIKit
#endif

struct ContentView: View {
    @StateObject private var viewModel = ViralCaptionsViewModel()
    @State private var showingVideoImporter = false
    @State private var showingSRTImporter = false
    @State private var selectedTab: AppTab = .create
    @State private var isShowingResultScreen = false
    @State private var isSavingToLibrary = false
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppAppearance.light.rawValue
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboarding = false
    #if os(iOS)
    @State private var selectedVideoItem: PhotosPickerItem?
    @StateObject private var revenueCat = RevenueCatStore()
    @State private var isShowingRevenueCatPaywall = false
    #endif

    private var appearanceMode: AppAppearance {
        AppAppearance(rawValue: appearanceModeRaw) ?? .light
    }

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        rootContent
            .alert(item: $viewModel.alert) { message in
                Alert(
                    title: Text(message.title),
                    message: Text(message.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        #else
        rootContent
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
            .onChange(of: viewModel.outputRemoteURL) { _, remoteURL in
                // Clearing the previous URL is part of opening another cached
                // history item and must not dismiss the result overlay.
                if remoteURL != nil {
                    isShowingResultScreen = true
                }
            }
            .alert(item: $viewModel.alert) { message in
                Alert(
                    title: Text(message.title),
                    message: Text(message.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .fullScreenCover(isPresented: $isShowingRevenueCatPaywall) {
                hostedRevenueCatPaywall
            }
            .task(id: viewModel.auth.session?.user.id) {
                guard viewModel.auth.isAuthenticated,
                      let userID = viewModel.auth.session?.user.id
                else { return }
                viewModel.activateLocalAccount(userID)
                await viewModel.bootstrapMobileAccount()
                await revenueCat.configure(
                    userID: userID,
                    email: viewModel.auth.session?.user.email,
                    displayName: viewModel.auth.session?.user.name
                )
            }
            .onChange(of: viewModel.lowCreditsPaywallRequestID) { _, requestID in
                guard requestID != nil else { return }
                Task { await presentFirstPassPaywallForLowCredits() }
            }
            .onChange(of: viewModel.passRequiredPaywallRequestID) { _, requestID in
                guard requestID != nil else { return }
                Task { await presentRequiredPassPaywall() }
            }
            .onChange(of: viewModel.auth.isAuthenticated) { _, isAuthenticated in
                if !isAuthenticated {
                    viewModel.activateLocalAccount(nil)
                    revenueCat.reset()
                    isShowingRevenueCatPaywall = false
                    isShowingResultScreen = false
                }
            }
        #endif
    }

    @ViewBuilder
    private var rootContent: some View {
        Group {
            if !viewModel.auth.hasRestoredSession {
                AppLaunchView()
            } else if !hasCompletedOnboarding {
                OnboardingFlowView(isComplete: $hasCompletedOnboarding)
            } else if !viewModel.auth.isAuthenticated {
                LoginGateView(auth: viewModel.auth)
            } else {
                appContent
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
    }

    #if os(iOS)
    private var hostedRevenueCatPaywall: some View {
        Group {
            if let offering = revenueCat.offering {
                PaywallView(offering: offering, displayCloseButton: true)
                    .onPurchaseCompleted { _ in
                        revenueCat.markPurchaseCompleted()
                        isShowingRevenueCatPaywall = false
                        Task { await viewModel.resumePreparedResultAfterPurchase() }
                    }
                    .onRestoreCompleted { _ in
                        Task {
                            await revenueCat.refresh()
                            isShowingRevenueCatPaywall = false
                            await viewModel.resumePreparedResultAfterPurchase()
                        }
                    }
            } else {
                BillingAccessLoadingView()
                    .task { await revenueCat.refresh() }
            }
        }
    }

    private func ensureBillingAccess() async -> Bool {
        guard let userID = viewModel.auth.session?.user.id else { return false }
        if revenueCat.hasPremium { return true }

        do {
            let access = try await viewModel.billingAccess()
            if access.hasPolarAccess || access.hasRevenueCatAccess { return true }

            guard access.shouldShowRevenueCat else {
                viewModel.alert = AppMessage(
                    title: "Access unavailable",
                    message: access.message ?? "We could not verify your pass status."
                )
                return false
            }

            revenueCat.lockAccess()
            await revenueCat.configure(userID: userID)
            guard revenueCat.offering != nil else {
                viewModel.alert = AppMessage(
                    title: "Passes unavailable",
                    message: revenueCat.errorMessage ?? "The pass options could not be loaded. Please try again."
                )
                return false
            }
            isShowingRevenueCatPaywall = true
            return false
        } catch {
            viewModel.alert = AppMessage(title: "Could not check access", message: error.localizedDescription)
            return false
        }
    }

    private func presentFirstPassPaywallForLowCredits() async {
        guard let userID = viewModel.auth.session?.user.id else { return }
        do {
            let access = try await viewModel.billingAccess()
            guard access.shouldShowRevenueCat && !access.hasPreviousPass else { return }

            revenueCat.lockAccess()
            await revenueCat.configure(userID: userID)
            guard revenueCat.offering != nil else { return }
            viewModel.alert = nil
            try? await Task.sleep(for: .milliseconds(300))
            isShowingRevenueCatPaywall = true
        } catch {
            // Keep the original insufficient-credit alert visible on failure.
        }
    }

    private func presentRequiredPassPaywall() async {
        guard let userID = viewModel.auth.session?.user.id else { return }
        revenueCat.lockAccess()
        await revenueCat.configure(userID: userID)
        guard revenueCat.offering != nil else {
            viewModel.alert = AppMessage(
                title: "Passes unavailable",
                message: revenueCat.errorMessage ?? "Pass options could not be loaded. Please try again."
            )
            return
        }
        viewModel.alert = nil
        try? await Task.sleep(for: .milliseconds(250))
        isShowingRevenueCatPaywall = true
    }
    #endif

    private func requestProtectedAccess() async -> Bool {
        #if os(iOS)
        return await ensureBillingAccess()
        #else
        return true
        #endif
    }

    private var appContent: some View {
        TabView(selection: $selectedTab) {
            CreateWorkspace(
                viewModel: viewModel,
                onPickVideo: pickVideo,
                onPickSRT: pickSRT,
                onSaveOutput: saveURL,
                requestAccess: requestProtectedAccess,
                onOpenHistory: downloadHistory
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
            if isSavingToLibrary {
                SavingToLibraryOverlay()
                    .transition(.opacity)
            } else if viewModel.isTranscribing {
                TranscriptionProgressOverlay(viewModel: viewModel)
                    .transition(.opacity)
            } else if viewModel.isSRTEditorPresented {
                SRTEditorOverlay(viewModel: viewModel)
                    .transition(.opacity)
            } else if viewModel.isRendering {
                RenderProgressOverlay(viewModel: viewModel)
                    .transition(.opacity)
            } else if isShowingResultScreen {
                OutputReadyOverlay(
                    viewModel: viewModel,
                    onClose: { isShowingResultScreen = false },
                    onDownload: saveURL,
                    requestAccess: requestProtectedAccess
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
        isShowingResultScreen = true
        Task {
            await Task.yield()
            guard await viewModel.openHistoryItem(item) else {
                await MainActor.run { isShowingResultScreen = false }
                return
            }
        }
    }

    #if os(iOS)
    private func saveOutputToPhotos(_ outputURL: URL) {
        guard !isSavingToLibrary else { return }
        isSavingToLibrary = true
        Task {
            defer { isSavingToLibrary = false }
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
                    viewModel.importVideo(from: movie.url, alreadyLocal: true)
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
private enum BillingGateState: Equatable {
    case idle
    case checking
    case access
    case revenueCat
    case unavailable(String)
}

private struct BillingAccessLoadingView: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image("SubclipLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                ProgressView()
                Text("Checking your access…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BillingAccessUnavailableView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Verify Access", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}
#endif

private struct SavingToLibraryOverlay: View {
    var body: some View {
        ZStack {
            Brand.softSurface.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Brand.navy)
                Text("Saving to Photos…")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                Text("This should only take a moment.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saving video to Photos")
    }
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onPickVideo: () -> Void
    var onPickSRT: () -> Void
    var onSaveOutput: (URL) -> Void
    var requestAccess: () async -> Bool
    var onOpenHistory: (LocalUploadQueueItem) -> Void
    @State private var step: CreateStep = .upload

    var body: some View {
        GeometryReader { proxy in
            let isPortraitPad = proxy.size.width >= 700 && proxy.size.height > proxy.size.width
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        if showsStepProgressHeader {
                            StepProgressHeader(step: step, canOpenLaterSteps: viewModel.selectedVideo != nil) { nextStep in
                                guard nextStep == .upload || viewModel.selectedVideo != nil else { return }
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    step = nextStep
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))

                            if horizontalSizeClass == .compact {
                                StepNavigationBar(
                                    step: step,
                                    canContinue: canContinue,
                                    continueTitle: continueTitle,
                                    onBack: moveBack,
                                    onContinue: moveForward
                                )
                                .frame(maxWidth: stepContentMaxWidth(for: proxy.size.width))
                            }
                        }

                        Group {
                            switch step {
                            case .upload:
                                VStack(spacing: 18) {
                                    MediaCard(
                                        viewModel: viewModel,
                                        onPickVideo: onPickVideo
                                    )
                                    if !viewModel.uploadQueue.isEmpty {
                                        LocalQueueCard(viewModel: viewModel, onOpen: onOpenHistory)
                                    }
                                }
                            case .style:
                                TemplateCard(viewModel: viewModel, layout: proxy.size.width >= 940 ? .compactGrid : .grid)
                            case .settings:
                                VStack(spacing: 18) {
                                    if viewModel.needsAuthentication {
                                        AuthenticationCard(viewModel: viewModel, auth: viewModel.auth)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    } else {
                                        ExportPreparationCard(
                                            viewModel: viewModel,
                                            onPickSRT: onPickSRT
                                        )
                                        RenderCard(viewModel: viewModel)
                                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        CoreRenderOptionsCard(
                                            viewModel: viewModel,
                                            onPickSRT: onPickSRT,
                                            forceExpanded: false
                                        )
                                    }

                                    if viewModel.hasResult {
                                        ResultCard(
                                            viewModel: viewModel,
                                            onSaveOutput: onSaveOutput,
                                            requestAccess: requestAccess
                                        )
                                    }
                                }
                                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.needsAuthentication)
                            }
                        }
                        .frame(maxWidth: stepContentMaxWidth(for: proxy.size.width))
                        .frame(minHeight: stepContentMinHeight(for: proxy.size), alignment: .center)

                        if showsStepNavigation {
                            StepNavigationBar(
                                step: step,
                                canContinue: canContinue,
                                continueTitle: continueTitle,
                                onBack: moveBack,
                                onContinue: moveForward
                            )
                            .frame(maxWidth: stepContentMaxWidth(for: proxy.size.width))
                        }
                    }
                    .id("create-workspace-top")
                    .onChange(of: viewModel.selectedVideo?.id) { _, videoId in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            step = videoId == nil ? .upload : .style
                        }
                    }
                    .onChange(of: viewModel.outputRemoteURL) { _, remoteURL in
                        guard remoteURL != nil else { return }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            step = .upload
                        }
                    }
                    .frame(maxWidth: 1180)
                    .frame(
                        minHeight: isPortraitPad ? max(0, proxy.size.height - 96) : nil,
                        alignment: .center
                    )
                    .padding(.horizontal, proxy.size.width < 520 ? 14 : 24)
                    .padding(.vertical, isPortraitPad ? 24 : (proxy.size.width < 520 ? 16 : 26))
                    .padding(.bottom, isPortraitPad ? 24 : 110)
                    .frame(maxWidth: .infinity)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showsStepProgressHeader)
                }
                .onChange(of: step) { _, _ in
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.24)) {
                            scrollProxy.scrollTo("create-workspace-top", anchor: .top)
                        }
                    }
                }
                .background(AppBackground())
            }
        }
    }

    private var showsStepProgressHeader: Bool {
        viewModel.selectedVideo != nil
    }

    private var canContinue: Bool {
        switch step {
        case .upload:
            return viewModel.selectedVideo != nil
        case .style:
            return viewModel.selectedVideo != nil
        case .settings:
            return false
        }
    }

    private var continueTitle: String {
        switch step {
        case .upload:
            return "Choose Style"
        case .style:
            return "Export"
        case .settings:
            return ""
        }
    }

    private var showsStepNavigation: Bool {
        switch step {
        case .upload:
            return viewModel.selectedVideo != nil
        case .style:
            return true
        case .settings:
            return false
        }
    }

    private func moveBack() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            switch step {
            case .upload:
                break
            case .style:
                step = .upload
            case .settings:
                step = .style
            }
        }
    }

    private func moveForward() {
        guard canContinue else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            switch step {
            case .upload:
                step = .style
            case .style:
                step = .settings
            case .settings:
                break
            }
        }
    }

    private func stepContentMaxWidth(for width: CGFloat) -> CGFloat {
        if width >= 940 {
            return step == .style ? 1120 : 820
        }
        return .infinity
    }

    private func stepContentMinHeight(for size: CGSize) -> CGFloat {
        guard step == .upload, viewModel.selectedVideo == nil else { return 0 }
        return max(320, size.height - 220)
    }
}

private enum CreateStep: Int, CaseIterable, Identifiable {
    case upload = 1
    case style = 2
    case settings = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .upload:
            return "Upload"
        case .style:
            return "Style"
        case .settings:
            return "Export"
        }
    }

    var icon: String {
        switch self {
        case .upload:
            return "film.fill"
        case .style:
            return "sparkles"
        case .settings:
            return "square.and.arrow.up"
        }
    }
}

private struct StepProgressHeader: View {
    let step: CreateStep
    let canOpenLaterSteps: Bool
    var onSelect: (CreateStep) -> Void

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(CreateStep.allCases) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        HStack(spacing: 7) {
                            Text("\(item.rawValue)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .frame(width: 22, height: 22)
                                .background(step == item ? Brand.navy : Color.primary.opacity(0.08), in: Circle())
                                .foregroundStyle(step == item ? .white : Brand.muted)
                            Text(item.title)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .nativeGlassButton(prominent: step == item)
                    .disabled(item != .upload && !canOpenLaterSteps)
                }
            }
        }
    }
}

private struct StepNavigationBar: View {
    let step: CreateStep
    let canContinue: Bool
    let continueTitle: String
    var onBack: () -> Void
    var onContinue: () -> Void

    var body: some View {
        LiquidGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if step != .upload {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .nativeGlassButton()
                }

                if step != .settings {
                    Button(action: onContinue) {
                        Label(continueTitle, systemImage: "chevron.right")
                            .frame(maxWidth: .infinity)
                    }
                    .nativeGlassButton(prominent: canContinue)
                    .disabled(!canContinue)
                }
            }
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
                                AuthenticationCard(viewModel: viewModel, auth: viewModel.auth)
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
                            AuthenticationCard(viewModel: viewModel, auth: viewModel.auth)
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

private struct AuthenticationCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    @ObservedObject var auth: BetterAuthStore
    @FocusState private var focusedField: Field?
    @State private var isShowingDeleteAccount = false
    @State private var isPasswordVisible = false

    private enum Field {
        case name, email, password, verificationCode
    }

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Subclip Account", systemImage: "person.crop.circle.fill")

                if let session = auth.session {
                    signedInContent(session: session)
                } else {
                    signedOutContent
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Brand.navy)
                    Text("Your encrypted session is stored in Keychain.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Brand.muted)
                    Spacer(minLength: 0)
                }
            }
        }
        .task(id: auth.isAuthenticated) {
            if auth.isAuthenticated && viewModel.quotaInfo == nil {
                await viewModel.refreshQuota()
            }
        }
        .sheet(isPresented: $isShowingDeleteAccount) {
            if let accountEmail = auth.session?.user.email {
                AccountDeletionSheet(auth: auth, accountEmail: accountEmail) {
                    viewModel.clearUploadQueue()
                    viewModel.resetResult()
                    viewModel.quotaInfo = nil
                }
            }
        }
    }

    private func signedInContent(session: Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Brand.navy)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.user.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    Text(session.user.email)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Brand.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .nativeGlassPanel(cornerRadius: 10)

            if let quota = viewModel.quotaInfo {
                HStack(spacing: 8) {
                    Image(systemName: quota.aiCredits.allowed ? "sparkles" : "exclamationmark.triangle.fill")
                        .foregroundStyle(quota.aiCredits.allowed ? Brand.navy : .orange)
                    Text(quotaSummary(for: quota))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .nativeGlassPanel(cornerRadius: 8)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.refreshQuota() }
                } label: {
                    Label(
                        viewModel.isCheckingQuota ? "Checking credits" : "Refresh credits",
                        systemImage: viewModel.isCheckingQuota ? "clock.arrow.circlepath" : "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .nativeGlassButton()
                .disabled(viewModel.isCheckingQuota)

                Button {
                    Task {
                        await auth.signOut()
                        viewModel.quotaInfo = nil
                    }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .nativeGlassButton()
            }

            Divider()
                .padding(.vertical, 2)

            Button(role: .destructive) {
                auth.message = nil
                isShowingDeleteAccount = true
            } label: {
                Label("Delete Account", systemImage: "trash.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHint("Permanently deletes your Subclip account and subscription benefits")
        }
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Account action", selection: $auth.mode) {
                ForEach(BetterAuthStore.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

                    if auth.mode == .signUp && !auth.needsVerification {
                TextField("Name", text: $auth.name)
                    .focused($focusedField, equals: .name)
                    .textContentType(.name)
                    .brandedInputField()
            }

            TextField("Email", text: $auth.email)
                .focused($focusedField, equals: .email)
                .textContentType(.emailAddress)
                .brandedInputField()
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            if auth.needsVerification {
                verificationContent
            } else {
                passwordContent
            }

            if let message = auth.message {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.muted)
            }
        }
    }

    private var verificationContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("6-digit verification code", text: $auth.verificationCode)
                .focused($focusedField, equals: .verificationCode)
                .textContentType(.oneTimeCode)
                .brandedInputField()
                #if os(iOS)
                .keyboardType(.asciiCapableNumberPad)
                #endif
                .onChange(of: auth.verificationCode) { _, newValue in
                    auth.verificationCode = normalizedOTP(newValue)
                }

            Button {
                Task {
                    focusedField = nil
                    await verifyEmailFromCard()
                }
            } label: {
                Label(auth.isLoading ? "Verifying" : "Verify Email", systemImage: "checkmark.seal.fill")
                    .frame(maxWidth: .infinity)
            }
            .nativeGlassButton(prominent: true)
            .disabled(auth.isLoading || auth.verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).count != 6)

            Button("Send a new code") {
                Task {
                    focusedField = nil
                    try? await Task.sleep(for: .milliseconds(350))
                    await auth.resendVerificationCode()
                }
            }
            .nativeGlassButton()
            .disabled(auth.isLoading)
        }
    }

    private var passwordContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if isPasswordVisible {
                        TextField("Password", text: $auth.password)
                    } else {
                        SecureField("Password", text: $auth.password)
                    }
                }
                .focused($focusedField, equals: .password)
                .textContentType(auth.mode == .signUp ? .newPassword : .password)

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(Brand.muted)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
            }
            .brandedInputField()

            Button {
                focusedField = nil
                Task { await auth.submit() }
            } label: {
                Label(
                    auth.isLoading ? "Please wait" : auth.mode.rawValue,
                    systemImage: auth.mode == .signIn ? "person.fill.checkmark" : "person.crop.circle.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .nativeGlassButton(prominent: true)
            .disabled(auth.isLoading || auth.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || auth.password.isEmpty)
        }
    }

    private func quotaSummary(for quota: QuotaResponse) -> String {
        let balance = quota.aiCredits.balance.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "Unknown"
        return "AI credits available: \(balance)."
    }

    private func verifyEmailFromCard() async {
        await MainActor.run {
            focusedField = nil
        }
        // Keep the verification field alive until SwiftUI has completed the
        // focus transition and detached the system keyboard.
        try? await Task.sleep(for: .milliseconds(450))
        await auth.verifyEmail()
    }

    private func normalizedOTP(_ value: String) -> String {
        String(value.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII }
            .prefix(6)
            .map(Character.init))
    }

}

private struct AccountDeletionSheet: View {
    @ObservedObject var auth: BetterAuthStore
    let accountEmail: String
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmationEmail = ""
    @FocusState private var isEmailFocused: Bool

    private var emailMatches: Bool {
        confirmationEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(accountEmail) == .orderedSame
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.10))
                                .frame(width: 76, height: 76)
                            Image(systemName: "trash.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        Text("Permanently delete account?")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                            .multilineTextAlignment(.center)
                        Text("This cannot be undone.")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.red)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        deletionNotice("Your remaining credits and account benefits will be revoked.")
                        deletionNotice("Active subscriptions will be canceled immediately.")
                        deletionNotice("Projects, render history, sessions and linked sign-in accounts will be removed.")
                        deletionNotice("Polar may retain anonymized payment records where legally required.")
                    }
                    .padding(16)
                    .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Type \(accountEmail) to confirm")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Brand.ink)
                        TextField("Account email", text: $confirmationEmail)
                            .focused($isEmailFocused)
                            .textContentType(.emailAddress)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 15)
                            .frame(height: 54)
                            .background(Brand.softSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(emailMatches ? Color.red.opacity(0.65) : Brand.line, lineWidth: emailMatches ? 1.5 : 1)
                            }
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                    }

                    if let message = auth.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                    }

                    Button(role: .destructive) {
                        Task {
                            if await auth.deleteAccount(confirmationEmail: confirmationEmail) {
                                onDeleted()
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if auth.isLoading { ProgressView().tint(.white) }
                            Image(systemName: auth.isLoading ? "hourglass" : "trash.fill")
                            Text(auth.isLoading ? "Deleting Account…" : "Delete My Account")
                        }
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!emailMatches || auth.isLoading)
                    .opacity(emailMatches ? 1 : 0.45)
                }
                .padding(28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Brand.softSurface.ignoresSafeArea())
            .navigationTitle("Delete Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(auth.isLoading)
                }
            }
            .interactiveDismissDisabled(auth.isLoading)
            .onAppear { isEmailFocused = true }
        }
    }

    private func deletionNotice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.ink)
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
                    SelectedVideoSummary(video: video)
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
    var layout: TemplateLayout = .carousel
    @State private var previewItem: TemplatePreviewItem?

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Choose Style", systemImage: "sparkles")

                if layout.isGrid {
                    LiquidGlassGroup(spacing: 12) {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            templateButtons
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LiquidGlassGroup(spacing: 10) {
                            LazyHStack(spacing: 10) {
                                templateButtons
                            }
                            .padding(.horizontal, 8)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $previewItem) { item in
            FullScreenVideoPlayer(
                url: item.url,
                isPresented: Binding(
                    get: { previewItem != nil },
                    set: { isPresented in
                        if !isPresented {
                            previewItem = nil
                        }
                    }
                )
            )
        }
        #else
        .sheet(item: $previewItem) { item in
            FullScreenVideoPlayer(
                url: item.url,
                isPresented: Binding(
                    get: { previewItem != nil },
                    set: { isPresented in
                        if !isPresented {
                            previewItem = nil
                        }
                    }
                )
            )
                    .frame(minWidth: 720, minHeight: 520)
        }
        #endif
    }

    private var gridColumns: [GridItem] {
        switch layout {
        case .carousel:
            return []
        case .grid:
            return [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]
        case .compactGrid:
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
        }
    }

    @ViewBuilder
    private var templateButtons: some View {
        ForEach(CaptionTemplate.all) { template in
            TemplateButton(
                template: template,
                selected: template.id == viewModel.selectedTemplateId,
                playbackEnabled: !viewModel.isRendering,
                layout: layout
            ) {
                viewModel.selectedTemplateId = template.id
            } onPreview: { url in
                previewItem = TemplatePreviewItem(url: url)
            }
        }
    }
}

private struct TemplatePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private enum TemplateLayout: Equatable {
    case carousel
    case grid
    case compactGrid
}

private struct TemplateButton: View {
    let template: CaptionTemplate
    let selected: Bool
    let playbackEnabled: Bool
    let layout: TemplateLayout
    var action: () -> Void
    var onPreview: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                TemplatePreviewVideo(
                    template: template,
                    playbackEnabled: playbackEnabled && selected
                )

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Brand.ink)
                            .frame(width: 30, height: 30)
                            .nativeGlassPanel(cornerRadius: 15, interactive: true)
                            .contentShape(Circle())
                            .highPriorityGesture(
                                TapGesture().onEnded {
                                    if let url = template.previewVideoURL {
                                        onPreview(url)
                                    }
                                }
                            )
                            .accessibilityElement()
                            .accessibilityLabel("Preview \(template.name) full screen")
                            .accessibilityAddTraits(.isButton)
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
            .modifier(TemplatePreviewFrame(layout: layout))
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

                if layout != .compactGrid {
                    Text(template.description)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: layout.cardMaxWidth, alignment: .leading)
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
    }
}

private struct TemplatePreviewFrame: ViewModifier {
    let layout: TemplateLayout

    func body(content: Content) -> some View {
        switch layout {
        case .carousel:
            content
                .frame(width: 150, height: 267)
        case .grid:
            content
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
        case .compactGrid:
            content
                .aspectRatio(9.0 / 14.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }
}

private extension TemplateLayout {
    var isGrid: Bool {
        switch self {
        case .grid, .compactGrid:
            return true
        case .carousel:
            return false
        }
    }

    var cardMaxWidth: CGFloat {
        switch self {
        case .carousel:
            return 150
        case .grid:
            return .infinity
        case .compactGrid:
            return 160
        }
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
    @Namespace private var selectionNamespace

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(OutputAspectRatio.allCases) { ratio in
                    OptionChip(
                        title: ratio.rawValue,
                        systemImage: aspectIcon(for: ratio),
                        selected: ratio == selection,
                        selectionNamespace: selectionNamespace,
                        selectionID: "aspect-ratio"
                    ) {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            selection = ratio
                        }
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
    @Namespace private var selectionNamespace

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
                                selected: placement == viewModel.placement,
                                selectionNamespace: selectionNamespace,
                                selectionID: "placement"
                            ) {
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                                    viewModel.selectPlacement(placement)
                                }
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
    let selectionNamespace: Namespace.ID
    let selectionID: String
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(baseFill)

                if selected {
                    Capsule()
                        .fill(selectedFill)
                        .matchedGeometryEffect(id: selectionID, in: selectionNamespace)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.13), radius: 12, x: 0, y: 5)
                }

                chipLabel
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(selected ? Brand.navy.opacity(0.34) : .white.opacity(colorScheme == .dark ? 0.08 : 0.72), lineWidth: selected ? 1.35 : 1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .frame(minWidth: 86, maxWidth: .infinity)
        .zIndex(selected ? 10 : 0)
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

    private var baseFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.82)
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.96)
    }
}

private struct CoreRenderOptionsCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onPickSRT: () -> Void
    var forceExpanded = false
    @State private var isExpanded = false

    private var showsExpandedContent: Bool {
        forceExpanded || isExpanded
    }

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

                    if !forceExpanded {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .frame(width: 34, height: 34)
                        }
                        .nativeGlassButton()
                        .accessibilityLabel(isExpanded ? "Collapse render settings" : "Expand render settings")
                    }
                }

                if !showsExpandedContent {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        MetricPill(text: languageSummary, systemImage: "textformat")
                        MetricPill(text: viewModel.aspectRatio.rawValue, systemImage: aspectIcon)
                        MetricPill(text: viewModel.placement.label, systemImage: placementIcon)
                    }
                }

                if showsExpandedContent {
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

                    }
                    .transition(.identity)
                }
            }
        }
        .animation(nil, value: showsExpandedContent)
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
    @State private var openingProjectID: String?

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
                            LocalQueueRow(
                                item: item,
                                isOpening: openingProjectID == item.projectId,
                                onOpen: {
                                    guard openingProjectID == nil else { return }
                                    openingProjectID = item.projectId
                                    onOpen(item)
                                }
                            )
                        }
                    }
                }
            }
        }
        .onChange(of: viewModel.outputRemoteURL) { _, remoteURL in
            if remoteURL != nil {
                openingProjectID = nil
            }
        }
        .onChange(of: viewModel.outputURL) { _, localURL in
            if localURL != nil {
                openingProjectID = nil
            }
        }
        .onChange(of: viewModel.isOpeningHistoryPreview) { _, isOpening in
            if !isOpening {
                openingProjectID = nil
            }
        }
        .onChange(of: viewModel.alert?.id) { _, alertID in
            if alertID != nil {
                openingProjectID = nil
            }
        }
    }
}

private struct LocalQueueRow: View {
    let item: LocalUploadQueueItem
    let isOpening: Bool
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

                if item.isResultReady {
                    HStack(spacing: 8) {
                        if isOpening {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Brand.navy)
                        } else {
                            Image(systemName: "play.rectangle.fill")
                        }
                        Text(isOpening ? "Preparing result…" : "Open result")
                    }
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
        .disabled(!item.isResultReady || isOpening)
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
                CardHeader(title: "Export Video", systemImage: "square.and.arrow.up.fill")

                if let credits = viewModel.previewEstimatedCredits {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Brand.navy)
                            .frame(width: 34, height: 34)
                            .nativeGlassPanel(cornerRadius: 10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Estimated AI credits")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Brand.muted)
                            Text("\(credits.formatted(.number.precision(.fractionLength(0...2)))) credits")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Brand.ink)
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Available")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Brand.muted)
                            Text(viewModel.quotaInfo?.aiCredits.balance?.formatted(.number.precision(.fractionLength(0...2))) ?? "—")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Brand.navy)
                        }
                    }
                    .padding(12)
                    .nativeGlassPanel(cornerRadius: 12)
                }

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
                        Text(viewModel.isRendering ? viewModel.phase.label : "Export Video")
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
        .task(id: viewModel.selectedVideo?.id) {
            if viewModel.auth.isAuthenticated {
                await viewModel.refreshQuota()
            }
        }
    }
}

private struct ExportPreparationCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onPickSRT: () -> Void

    var body: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Captions", systemImage: "captions.bubble.fill")

                Toggle(
                    isOn: Binding(
                        get: { viewModel.cloudTranscribe },
                        set: { viewModel.setCloudTranscribe($0) }
                    )
                ) {
                    Label("Cloud Transcribe", systemImage: "waveform")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                }
                .padding(12)
                .nativeGlassPanel(cornerRadius: 8, interactive: true)

                if !viewModel.cloudTranscribe {
                    VStack(alignment: .leading, spacing: 10) {
                        LocalTranscriptionControl(viewModel: viewModel)
                        SRTAttachmentControl(viewModel: viewModel, onPickSRT: onPickSRT)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.86), value: viewModel.cloudTranscribe)
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
    var allowsFullScreen = false
    var showsWatermark = false
    @State private var player: AVPlayer?
    @State private var playbackKickTask: Task<Void, Never>?
    @State private var isShowingFullPlayer = false
    @State private var isPlayerReady = false

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

            if url != nil && !isPlayerReady {
                VStack(spacing: 9) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading preview…")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.44), in: Capsule())
            }

            if showsProgressBorder {
                RoundedRectProgressShape(progress: clampedProgress, cornerRadius: 34, inset: 4)
                    .stroke(Brand.navy, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    .animation(.easeInOut(duration: 0.25), value: clampedProgress)
            }

            if showsWatermark {
                ResultWatermark()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(showsProgressBorder ? 28 : 12)
            }

            if allowsFullScreen, url != nil {
                Button {
                    isShowingFullPlayer = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.44), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View result full screen")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(showsProgressBorder ? 28 : 12)
            }
        }
        .onAppear {
            configurePlayer()
        }
        .onChange(of: url) { _, _ in
            configurePlayer()
        }
        .onDisappear {
            playbackKickTask?.cancel()
            playbackKickTask = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let currentItem = player?.currentItem,
                  notification.object as? AVPlayerItem === currentItem else {
                return
            }
            currentItem.seek(to: .zero) { _ in
                Task { @MainActor in
                    if autoplay {
                        player?.play()
                    }
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isShowingFullPlayer) {
            if let url {
                FullScreenVideoPlayer(url: url, isPresented: $isShowingFullPlayer, showsWatermark: showsWatermark)
            }
        }
        #else
        .sheet(isPresented: $isShowingFullPlayer) {
            if let url {
                FullScreenVideoPlayer(url: url, isPresented: $isShowingFullPlayer, showsWatermark: showsWatermark)
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
        #endif
    }

    private func configurePlayer() {
        playbackKickTask?.cancel()
        playbackKickTask = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlayerReady = false
        guard let url else {
            return
        }
        playbackKickTask = Task { @MainActor in
            let asset = AVURLAsset(url: url)
            guard (try? await asset.load(.isPlayable)) == true, !Task.isCancelled else { return }
            let nextPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            nextPlayer.isMuted = true
            nextPlayer.actionAtItemEnd = .none
            nextPlayer.automaticallyWaitsToMinimizeStalling = true
            player = nextPlayer
            isPlayerReady = true
            if autoplay {
                startAutoplay(for: nextPlayer)
            }
        }
    }

    private func startAutoplay(for activePlayer: AVPlayer) {
        playbackKickTask = Task { @MainActor in
            let delays: [UInt64] = [
                0,
                120_000_000,
                350_000_000,
                800_000_000,
                1_500_000_000
            ]

            for delay in delays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled, player === activePlayer else { return }
                guard activePlayer.currentItem?.status != .failed else { return }
                activePlayer.play()
            }
        }
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
    var requestAccess: () async -> Bool
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
                                showsProgressBorder: false,
                                allowsFullScreen: true,
                                showsWatermark: true
                            )
                                .frame(
                                    size: overlayPreviewSize(
                                        in: proxy.size,
                                        aspectRatio: (viewModel.resultAspectRatio ?? viewModel.aspectRatio).previewAspect,
                                        maxHeightFraction: 0.54,
                                        maxHeight: 590
                                    )
                                )

                            ShareDestinationGrid(
                                viewModel: viewModel,
                                onSaveOutput: onDownload,
                                requestAccess: requestAccess
                            )
                                .padding(.horizontal, 24)
                        } else {
                            OutputDownloadPreparation(viewModel: viewModel)
                                .frame(maxWidth: 440)
                                .padding(.horizontal, 24)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 92)
                    .padding(.bottom, 36)
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

private struct OutputDownloadPreparation: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel

    private var progress: Double {
        viewModel.outputDownloadProgress ?? 0
    }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(Brand.line, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Brand.navy, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Brand.navy)
            }
            .frame(width: 112, height: 112)

            VStack(spacing: 8) {
                Text("Your export is ready")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                Text(downloadStatusText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Brand.navy)
        }
        .padding(28)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Brand.line, lineWidth: 1)
        }
    }

    private var downloadStatusText: String {
        if viewModel.isOpeningHistoryPreview {
            return "Loading your video preview…"
        }
        if let value = viewModel.outputDownloadProgress {
            return "Downloading securely… \(Int((value * 100).rounded()))%"
        }
        return "Starting the secure download…"
    }
}

private struct ResultCard: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onSaveOutput: (URL) -> Void
    var requestAccess: () async -> Bool

    var body: some View {
        BrandCard {
            VStack(alignment: .center, spacing: 18) {
                CardHeader(title: "Ready to Share", systemImage: "square.and.arrow.up.fill")

                Text("Your captioned MP4 is ready.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.slate)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let previewURL = viewModel.resultPreviewURL {
                    VideoPreview(url: previewURL, showsWatermark: true)
                        .aspectRatio(viewModel.aspectRatio.previewAspect, contentMode: .fit)
                        .frame(maxWidth: viewModel.aspectRatio.previewMaxWidth)
                        .frame(maxWidth: .infinity)

                    ShareDestinationGrid(
                        viewModel: viewModel,
                        onSaveOutput: onSaveOutput,
                        requestAccess: requestAccess
                    )
                }
            }
        }
    }
}

private struct ShareDestinationGrid: View {
    @ObservedObject var viewModel: ViralCaptionsViewModel
    var onSaveOutput: (URL) -> Void
    var requestAccess: () async -> Bool
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
            guard await requestAccess() else {
                await MainActor.run { isPreparingDownload = false }
                return
            }
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
            guard await requestAccess() else {
                await MainActor.run { isPreparingShare = false }
                return
            }
            await MainActor.run { viewModel.cacheCurrentOutput() }
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
    var showsWatermark = false
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
                    .overlay(alignment: .bottomLeading) {
                        if showsWatermark {
                            ResultWatermark()
                                .padding(10)
                        }
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
                FullScreenVideoPlayer(url: url, isPresented: $isShowingFullPlayer, showsWatermark: showsWatermark)
            }
        }
        #else
        .sheet(isPresented: $isShowingFullPlayer) {
            if let url {
                FullScreenVideoPlayer(url: url, isPresented: $isShowingFullPlayer, showsWatermark: showsWatermark)
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
    var showsWatermark = false
    @State private var player = AVPlayer()
    @State private var isPreparing = true
    @State private var preparationTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            if isPreparing {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Preparing preview…")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(.black.opacity(0.55), in: Capsule())
            }

            if showsWatermark {
                ResultWatermark()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(20)
            }

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
            isPreparing = true
            preparationTask?.cancel()
            preparationTask = Task { @MainActor in
                let asset = AVURLAsset(url: url)
                guard (try? await asset.load(.isPlayable)) == true, !Task.isCancelled else { return }
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                player.isMuted = false
                player.automaticallyWaitsToMinimizeStalling = true
                player.play()
            }
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            if status == .playing {
                isPreparing = false
            } else if status == .waitingToPlayAtSpecifiedRate {
                isPreparing = true
            }
        }
        .onDisappear {
            preparationTask?.cancel()
            preparationTask = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
}

private struct ResultWatermark: View {
    var body: some View {
        Text("subclip.app")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.28), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .allowsHitTesting(false)
            .accessibilityLabel("Subclip dot app watermark")
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
