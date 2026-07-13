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
    // RevenueCat's public Apple SDK key. This is safe to ship in the app.
    // App Store Connect keys and RevenueCat secret keys must remain server-side.
    private static let applePublicSDKKey = "appl_dDGhBfEHRRYGBUhOrBzpudOMIdJ"
    private var configuredUserID: String?

    func configure(userID: String, email: String? = nil, displayName: String? = nil) async {
        guard !userID.isEmpty else { return }

        if configuredUserID != userID {
            #if DEBUG
            Purchases.logLevel = .debug
            #endif

            if !Purchases.isConfigured {
                Purchases.configure(withAPIKey: Self.applePublicSDKKey, appUserID: userID)
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

        await syncSubscriberAttributes(userID: userID, email: email, displayName: displayName)

        await refresh()
    }

    private func syncSubscriberAttributes(userID: String, email: String?, displayName: String?) async {
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedEmail, !normalizedEmail.isEmpty {
            Purchases.shared.attribution.setEmail(normalizedEmail)
        }
        if let normalizedName, !normalizedName.isEmpty {
            Purchases.shared.attribution.setDisplayName(normalizedName)
        }

        let bundle = Bundle.main
        Purchases.shared.attribution.setAttributes([
            "better_auth_user_id": userID,
            "platform": "ios",
            "account_source": "subclip_ios",
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "locale": Locale.current.identifier,
        ])

        do {
            _ = try await Purchases.shared.syncAttributesAndOfferingsIfNeeded()
        } catch {
            // Attribute delivery is retried by RevenueCat automatically. Keep
            // purchases available if this non-critical sync is temporarily down.
            print("RevenueCat attribute sync deferred: \(error.localizedDescription)")
        }
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
