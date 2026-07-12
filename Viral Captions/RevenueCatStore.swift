#if os(iOS)
import Combine
import Foundation
import RevenueCat

@MainActor
final class RevenueCatStore: ObservableObject {
    @Published private(set) var offering: Offering?
    @Published private(set) var hasPremium = false
    @Published private(set) var creditBalance: Double = 0
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
            async let virtualCurrencies = Purchases.shared.virtualCurrencies()
            let (info, availableOfferings, currencies) = try await (customerInfo, offerings, virtualCurrencies)
            apply(info, currencies: currencies)
            offering = availableOfferings.current
            if offering == nil {
                errorMessage = "Passes are temporarily unavailable. Please try again shortly."
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
            Purchases.shared.invalidateVirtualCurrenciesCache()
            let currencies = try await Purchases.shared.virtualCurrencies()
            apply(result.customerInfo, currencies: currencies)
            hasPremium = true
            return true
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
            Purchases.shared.invalidateVirtualCurrenciesCache()
            let currencies = try await Purchases.shared.virtualCurrencies()
            apply(info, currencies: currencies)
            let restoredProduct = info.entitlements[Self.entitlementID]?.productIdentifier
            hasPremium = restoredProduct == "app.subclip.viralcaptions.lifetimepass"
                || restoredProduct == "subclip_lifetime_pass"
            if !hasPremium {
                errorMessage = "No restorable Subclip pass was found for this Apple ID."
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
        creditBalance = 0
        errorMessage = nil
        configuredUserID = nil
        isConfigured = false
    }

    func lockAccess() {
        hasPremium = false
    }

    func markPurchaseCompleted() {
        hasPremium = true
        Task { await refresh() }
    }

    private func apply(_ info: CustomerInfo, currencies: VirtualCurrencies) {
        let creditUnits = ["DAYCRED", "WEEKCRED", "MONTHCRED", "LIFECRED"]
            .reduce(0) { total, code in total + (currencies[code]?.balance ?? 0) }
        creditBalance = Double(creditUnits) / 100
    }
}
#endif
