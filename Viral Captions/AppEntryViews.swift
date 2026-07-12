import BetterAuth
import SwiftUI

struct AppLaunchView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.softSurface, Brand.navy.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                SubclipAppMark(size: 76)
                Text("Viral Captions")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                ProgressView()
                    .controlSize(.regular)
                    .tint(Brand.navy)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading Viral Captions")
        }
    }
}

struct LoginGateView: View {
    @ObservedObject var auth: BetterAuthStore
    @FocusState private var focusedField: Field?
    @State private var isShowingPasswordReset = false
    @State private var isPasswordVisible = false

    private enum Field {
        case name, email, password, code
    }

    var body: some View {
        GeometryReader { proxy in
            let isPortraitPad = proxy.size.width >= 700 && proxy.size.height > proxy.size.width
            ZStack {
                entryBackground

                ScrollView {
                    VStack(spacing: isPortraitPad ? 38 : (proxy.size.height < 700 ? 20 : 30)) {
                        VStack(spacing: 14) {
                            SubclipAppMark(size: isPortraitPad ? 104 : (proxy.size.width < 390 ? 68 : 82))
                            Text("Create captions people stop for")
                                .font(.system(size: isPortraitPad ? 38 : (proxy.size.width < 390 ? 25 : 31), weight: .bold, design: .rounded))
                                .foregroundStyle(Brand.ink)
                                .multilineTextAlignment(.center)
                            Text("Sign in to render, save and manage your captioned videos securely.")
                                .font(.system(size: isPortraitPad ? 17 : 14, weight: .medium))
                                .foregroundStyle(Brand.muted)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: isPortraitPad ? 560 : 430)
                        }

                        VStack(spacing: 14) {
                            Picker("Account action", selection: $auth.mode) {
                                ForEach(BetterAuthStore.Mode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if auth.mode == .signUp && !auth.needsVerification {
                                entryField("Your name", text: $auth.name, field: .name)
                                    .textContentType(.name)
                            }

                            entryField("Email address", text: $auth.email, field: .email)
                                .textContentType(.emailAddress)
                                #if os(iOS)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                #endif

                            if auth.needsVerification {
                                verificationForm
                            } else {
                                passwordForm
                            }

                            if let message = auth.message {
                                Label(message, systemImage: auth.needsVerification ? "envelope.badge" : "info.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Brand.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(isPortraitPad ? 32 : (proxy.size.width < 390 ? 18 : 24))
                        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Brand.line, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.07), radius: 24, y: 12)
                        .frame(maxWidth: isPortraitPad ? 660 : 500)

                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: isPortraitPad
                            ? max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom - 48)
                            : nil,
                        alignment: .center
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, max(24, proxy.safeAreaInsets.top + 12))
                    .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 16))
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .sheet(isPresented: $isShowingPasswordReset) {
            PasswordResetSheet(auth: auth)
        }
    }

    private var entryBackground: some View {
        LinearGradient(
            colors: [Brand.softSurface, Brand.navy.opacity(0.09), Brand.cyan.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func entryField(
        _ title: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        TextField(title, text: text)
            .focused($focusedField, equals: field)
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 15)
            .frame(height: 52)
            .background(Brand.softSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(focusedField == field ? Brand.navy.opacity(0.65) : Brand.line, lineWidth: focusedField == field ? 1.5 : 1)
            }
    }

    private var passwordForm: some View {
        VStack(spacing: 14) {
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
                .font(.system(size: 16, weight: .medium))

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
                .padding(.leading, 15)
                .padding(.trailing, 8)
                .frame(height: 52)
                .background(Brand.softSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(focusedField == .password ? Brand.navy.opacity(0.65) : Brand.line, lineWidth: focusedField == .password ? 1.5 : 1)
                }
                .onSubmit(submit)

            if auth.mode == .signIn {
                Button("Forgot password?") {
                    focusedField = nil
                    isShowingPasswordReset = true
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.navy)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHint("Sends a password reset link to your email")
            }

            Button(action: submit) {
                HStack(spacing: 9) {
                    if auth.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: auth.mode == .signIn ? "arrow.right" : "person.badge.plus")
                    }
                    Text(auth.isLoading ? "Please wait…" : auth.mode.rawValue)
                }
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Brand.navy, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(auth.isLoading || auth.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || auth.password.isEmpty)
            .opacity(auth.isLoading ? 0.82 : 1)
        }
    }

    private var verificationForm: some View {
        VStack(spacing: 12) {
            TextField("6-digit verification code", text: $auth.verificationCode)
                .focused($focusedField, equals: .code)
                .textContentType(.oneTimeCode)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 15)
                .frame(height: 54)
                .background(Brand.softSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(focusedField == .code ? Brand.navy.opacity(0.65) : Brand.line, lineWidth: focusedField == .code ? 1.5 : 1)
                }
                #if os(iOS)
                .keyboardType(.asciiCapableNumberPad)
                #endif
                .onChange(of: auth.verificationCode) { _, newValue in
                    auth.verificationCode = normalizedOTP(newValue)
                }

                Button {
                    Task {
                        focusedField = nil
                        await verifyEmailFromGate()
                    }
                } label: {
                HStack {
                    if auth.isLoading { ProgressView().tint(.white) }
                    Text(auth.isLoading ? "Verifying…" : "Verify Email")
                }
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Brand.navy, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(auth.isLoading || auth.verificationCode.filter(\.isNumber).count != 6)

            Button("Send a new code") {
                Task {
                    focusedField = nil
                    try? await Task.sleep(for: .milliseconds(350))
                    await auth.resendVerificationCode()
                }
            }
            .font(.system(size: 13, weight: .bold))
            .buttonStyle(.plain)
            .foregroundStyle(Brand.navy)
            .disabled(auth.isLoading)
        }
    }

    private func submit() {
        guard !auth.isLoading else { return }
        focusedField = nil
        Task { await auth.submit() }
    }

    private func verifyEmailFromGate() async {
        await MainActor.run {
            focusedField = nil
        }
        // Give SwiftUI time to finish its focus transaction before a successful
        // verification replaces this form. This avoids tearing down the field
        // while the system keyboard is still attached to it.
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

private struct PasswordResetSheet: View {
    @ObservedObject var auth: BetterAuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var hasSentLink = false
    @FocusState private var isEmailFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    ZStack {
                        Circle()
                            .fill(Brand.navy.opacity(0.10))
                            .frame(width: 76, height: 76)
                        Image(systemName: hasSentLink ? "envelope.badge.fill" : "key.fill")
                            .font(.system(size: 31, weight: .semibold))
                            .foregroundStyle(Brand.navy)
                    }

                    VStack(spacing: 8) {
                        Text(hasSentLink ? "Check your email" : "Reset your password")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                        Text(
                            hasSentLink
                                ? "We sent a secure reset link to \(email). Open it to choose a new password."
                                : "Enter the email linked to your Subclip account. We’ll send you a secure reset link."
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                    }

                    if !hasSentLink {
                        TextField("Email address", text: $email)
                            .focused($isEmailFocused)
                            .textContentType(.emailAddress)
                            .font(.system(size: 16, weight: .medium))
                            .padding(.horizontal, 15)
                            .frame(height: 54)
                            .background(Brand.softSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(isEmailFocused ? Brand.navy.opacity(0.65) : Brand.line, lineWidth: isEmailFocused ? 1.5 : 1)
                            }
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif

                        Button {
                            Task {
                                hasSentLink = await auth.requestPasswordReset(for: email)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if auth.isLoading { ProgressView().tint(.white) }
                                Text(auth.isLoading ? "Sending…" : "Send Reset Link")
                            }
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Brand.navy, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(auth.isLoading || !email.contains("@"))
                    } else {
                        Button("Back to Sign In") { dismiss() }
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Brand.navy, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .buttonStyle(.plain)

                        Button("Resend link") { hasSentLink = false }
                            .font(.system(size: 13, weight: .bold))
                            .buttonStyle(.plain)
                            .foregroundStyle(Brand.navy)
                    }

                    if let message = auth.message, !hasSentLink {
                        Label(message, systemImage: "info.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Brand.softSurface.ignoresSafeArea())
            .navigationTitle("Forgot Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if email.isEmpty { email = auth.email }
                isEmailFocused = email.isEmpty
            }
        }
    }
}

struct OnboardingFlowView: View {
    @Binding var isComplete: Bool
    @State private var page = 0

    private let pages = [
        OnboardingPage(
            icon: "video.badge.waveform.fill",
            title: "One video. Finished captions.",
            detail: "Pick a video, choose a style and let Subclip handle the timing and render.",
            accent: Brand.navy
        ),
        OnboardingPage(
            icon: "captions.bubble.fill",
            title: "Designed for attention",
            detail: "Use polished caption templates, placement controls and face-aware framing made for social video.",
            accent: Brand.cyan
        ),
        OnboardingPage(
            icon: "arrow.down.circle.fill",
            title: "Ready when the render is",
            detail: "The finished MP4 downloads in the background, then saves or shares instantly from your device.",
            accent: Brand.navy
        )
    ]

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    SubclipAppMark(size: 42)
                    Spacer()
                    Button("Skip") { complete() }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Brand.muted)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.top, max(16, proxy.safeAreaInsets.top + 8))

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        OnboardingPageView(page: item)
                            .tag(index)
                            .padding(.horizontal, 24)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif

                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Brand.navy : Brand.line)
                            .frame(width: index == page ? 24 : 8, height: 8)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: page)

                Button {
                    if page == pages.count - 1 {
                        complete()
                    } else {
                        page += 1
                    }
                } label: {
                    HStack {
                        Text(page == pages.count - 1 ? "Start Creating" : "Continue")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Brand.navy, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, max(18, proxy.safeAreaInsets.bottom + 12))
            }
            .background(Brand.softSurface.ignoresSafeArea())
        }
    }

    private func complete() {
        withAnimation(.easeOut(duration: 0.18)) {
            isComplete = true
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let title: String
    let detail: String
    let accent: Color
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 20)
            ZStack {
                Circle()
                    .fill(page.accent.opacity(0.10))
                    .frame(width: 210, height: 210)
                Circle()
                    .stroke(page.accent.opacity(0.18), lineWidth: 1)
                    .frame(width: 172, height: 172)
                Image(systemName: page.icon)
                    .font(.system(size: 70, weight: .semibold))
                    .foregroundStyle(page.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: 13) {
                Text(page.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(page.detail)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SubclipAppMark: View {
    let size: CGFloat

    var body: some View {
        Image("SubclipLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .frame(width: size, height: size)
        .shadow(color: Brand.navy.opacity(0.20), radius: size * 0.16, y: size * 0.08)
        .accessibilityHidden(true)
    }
}
