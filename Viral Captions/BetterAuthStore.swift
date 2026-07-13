import BetterAuth
import BetterAuthEmailOTP
import Combine
import Foundation

@MainActor
final class BetterAuthStore: ObservableObject {
    private static let pendingIOSWelcomeEmailKey = "pendingIOSWelcomeCreditsEmail"
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case signUp = "Create Account"

        var id: String { rawValue }
    }

    let client: BetterAuthClient

    @Published var mode: Mode = .signIn
    @Published var name = ""
    @Published var email = ""
    @Published var password = ""
    @Published var verificationCode = ""
    @Published private(set) var isLoading = false
    @Published private(set) var hasRestoredSession = false
    @Published private(set) var needsVerification = false
    @Published var message: String?

    private var clientObservation: AnyCancellable?

    init() {
        client = BetterAuthClient(
            baseURL: URL(string: "https://www.subclip.app")!,
            scheme: "subclip://",
            plugins: [EmailOTPPlugin()]
        )
        clientObservation = client.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var session: Session? { client.session.data }
    var isAuthenticated: Bool { session != nil }

    func restoreSession() async {
        guard !hasRestoredSession, !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasRestoredSession = true
        }
        // CookieStorage loads the persisted BetterAuth cookie from Keychain
        // during client initialization. Do not race/cancel the first session
        // request after two seconds: that caused valid restored cookies to be
        // followed by `Session updated: nil` on slower rebuild launches.
        guard client.getCookie() != nil else { return }
        for attempt in 0..<3 {
            await client.session.refreshSession()
            if client.session.data != nil { break }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }

    func submit() async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            message = "Enter your email and password."
            return
        }

        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            switch mode {
            case .signIn:
                _ = try await client.signIn.email(
                    with: .init(email: normalizedEmail, password: password, rememberMe: true)
                )
                await waitForSessionRefresh(expectAuthenticatedSession: true)
                needsVerification = false
            case .signUp:
                let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedName.isEmpty else {
                    message = "Enter your name."
                    return
                }
                let response = try await client.signUp.email(
                    with: .init(
                        email: normalizedEmail,
                        password: password,
                        name: normalizedName,
                        rememberMe: true
                    )
                )
                UserDefaults.standard.set(
                    normalizedEmail,
                    forKey: Self.pendingIOSWelcomeEmailKey
                )
                needsVerification = response.data.token == nil || !response.data.user.emailVerified
                if needsVerification {
                    message = "We sent a 6-digit verification code to \(normalizedEmail)."
                } else {
                    await waitForSessionRefresh(expectAuthenticatedSession: true)
                }
            }
        } catch {
            if let apiError = error as? BetterAuthApiError,
               apiError.code == "ALREADY_REGISTERED" ||
               apiError.code == "USER_ALREADY_EXISTS" ||
               apiError.localizedDescription.localizedCaseInsensitiveContains("already registered") ||
               apiError.localizedDescription.localizedCaseInsensitiveContains("already exists") {
                needsVerification = false
                verificationCode = ""
                UserDefaults.standard.removeObject(forKey: Self.pendingIOSWelcomeEmailKey)
                message = "Already registered"
                return
            }
            if let apiError = error as? BetterAuthApiError,
               apiError.code == "EMAIL_NOT_VERIFIED" {
                needsVerification = true
                try? await sendVerificationCode(to: normalizedEmail)
                message = "Verify your email with the 6-digit code we sent."
                return
            }
            message = error.localizedDescription
        }
    }

    var shouldClaimIOSWelcomeCredits: Bool {
        guard let sessionEmail = session?.user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let pendingEmail = UserDefaults.standard.string(forKey: Self.pendingIOSWelcomeEmailKey)
        else { return false }
        return sessionEmail == pendingEmail
    }

    func markIOSWelcomeCreditsClaimed() {
        UserDefaults.standard.removeObject(forKey: Self.pendingIOSWelcomeEmailKey)
    }

    func verifyEmail() async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Better Auth's email-OTP API explicitly expects a JSON string. Keep it
        // as a string so codes such as "012345" do not lose their leading zero,
        // while stripping spaces/dashes introduced by OTP autofill or pasting.
        let code = verificationCode.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII }
            .map(String.init)
            .joined()
        guard code.count == 6 else {
            message = "Enter the 6-digit verification code."
            return
        }

        verificationCode = code

        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let response = try await client.emailOtp.verifyEmail(
                with: .init(email: normalizedEmail, otp: code)
            )

            if !response.data.status {
                message = "Invalid verification code. Please try again."
                return
            }

            verificationCode = ""
            needsVerification = false
            await waitForSessionRefresh(expectAuthenticatedSession: true, maxIterations: 8)

            if !isAuthenticated {
                mode = .signIn
                password = ""
                message = "Email verified. Sign in to continue."
            } else {
                message = nil
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func resendVerificationCode() async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            try await sendVerificationCode(to: normalizedEmail)
            message = "A new verification code was sent."
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func requestPasswordReset(for resetEmail: String) async -> Bool {
        let normalizedEmail = resetEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEmail.contains("@") else {
            message = "Enter a valid email address."
            return false
        }

        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            _ = try await client.requestPasswordReset(
                with: .init(
                    email: normalizedEmail,
                    redirectTo: "https://www.subclip.app/reset-password"
                )
            )
            message = "If that account exists, a reset link has been sent."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteAccount(confirmationEmail: String) async -> Bool {
        guard let accountEmail = session?.user.email else {
            message = "Sign in again before deleting your account."
            return false
        }
        let normalizedConfirmation = confirmationEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedConfirmation == accountEmail.lowercased() else {
            message = "The email address does not match this account."
            return false
        }
        guard let cookie = client.getCookie() else {
            message = "Your session expired. Sign in again before deleting your account."
            return false
        }

        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: URL(string: "https://www.subclip.app/api/v1/account")!)
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("subclip://", forHTTPHeaderField: "Origin")
            request.setValue("\(cookie.name)=\(cookie.value)", forHTTPHeaderField: "Cookie")
            request.httpBody = try JSONEncoder().encode(
                DeleteAccountRequest(confirmationEmail: normalizedConfirmation)
            )
            request.timeoutInterval = 90

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DeleteAccountFailure(message: "The server did not return a valid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let serverError = try? JSONDecoder().decode(DeleteAccountErrorResponse.self, from: data)
                throw DeleteAccountFailure(
                    message: serverError?.message ?? "Your account could not be deleted. Please try again."
                )
            }

            // Explicitly clear the local BetterAuth cookie/session after the
            // server confirms deletion. The remote account no longer exists,
            // so sign-out is best-effort and must not change deletion success.
            _ = try? await client.signOut()
            await waitForSessionRefresh(expectAuthenticatedSession: false, maxIterations: 8)
            password = ""
            verificationCode = ""
            needsVerification = false
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            _ = try await client.signOut()
            await waitForSessionRefresh(expectAuthenticatedSession: false)
            password = ""
            verificationCode = ""
            needsVerification = false
        } catch {
            message = error.localizedDescription
        }
    }

    private func sendVerificationCode(to email: String) async throws {
        _ = try await client.emailOtp.sendVerificationOtp(
            with: .init(email: email, type: .emailVerification)
        )
    }

    private func waitForSessionRefresh(
        expectAuthenticatedSession: Bool,
        maxIterations: Int = 6
    ) async {
        for _ in 0..<maxIterations {
            let hasSession = client.session.data != nil
            if expectAuthenticatedSession ? hasSession : !hasSession {
                break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

private struct DeleteAccountRequest: Encodable {
    let confirmationEmail: String
}

private struct DeleteAccountErrorResponse: Decodable {
    let message: String
}

private struct DeleteAccountFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
