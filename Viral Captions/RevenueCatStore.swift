#if os(iOS)
import Combine
import Foundation
import RevenueCat

@MainActor
final class RevenueCatStore: ObservableObject {
    @Published private(set) var offering: Offering?
    @Published private(set) var hasPremium = false
    @Published private(set) var isLoading = false
    @Published private(set) var isConfigured = false
    @Published var errorMessage: String?

    private static let entitlementID = "premium"
    private var configuredUserID: String?

    func configure(userID: String) async {
        guard !userID.isEmpty else { return }

        if configuredUserID != userID {
            #if DEBUG
            Purchases.logLevel = .debug
            let apiKey = "test_XGQynQKFINvKcmyjliZSgklSroc"
            #else
            let apiKey = "appl_dDGhBfEHRRYGBUhOrBzpudOMIdJ"
            #endif

            if !Purchases.isConfigured {
                Purchases.configure(withAPIKey: apiKey, appUserID: userID)
            } else {
                do {
                    _ = try await Purchases.shared.logIn(userID)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            configuredUserID = userID
            isConfigured = true
        }

        await refresh()
    }

    func refresh() async {
        guard Purchases.isConfigured else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let customerInfo = Purchases.shared.customerInfo()
            async let offerings = Purchases.shared.offerings()
            let (info, availableOfferings) = try await (customerInfo, offerings)
            apply(info)
            offering = availableOfferings.current
            if offering == nil {
                errorMessage = "Subscriptions are temporarily unavailable. Please try again shortly."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purchase(_ package: Package) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            apply(result.customerInfo)
            return hasPremium
        } catch ErrorCode.purchaseCancelledError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func restore() async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            if !hasPremium {
                errorMessage = "No active Subclip subscription was found for this Apple ID."
            }
            return hasPremium
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reset() {
        offering = nil
        hasPremium = false
        errorMessage = nil
        configuredUserID = nil
        isConfigured = false
    }

    private func apply(_ info: CustomerInfo) {
        hasPremium = info.entitlements[Self.entitlementID]?.isActive == true
    }
}
#endif
