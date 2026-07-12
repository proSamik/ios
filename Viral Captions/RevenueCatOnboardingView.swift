#if os(iOS)
import RevenueCat
import SwiftUI

struct RevenueCatOnboardingView: View {
    @ObservedObject var store: RevenueCatStore
    let onSignOut: () -> Void

    @State private var selectedPackageID: String?

    private var packages: [Package] {
        store.offering?.availablePackages.sorted { lhs, rhs in
            rank(lhs.identifier) < rank(rhs.identifier)
        } ?? []
    }

    private var selectedPackage: Package? {
        packages.first { $0.identifier == selectedPackageID } ?? packages.first
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.96, green: 0.98, blue: 1), Color(red: 0.90, green: 0.96, blue: 1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    header
                    benefits
                    plans
                    purchaseButton
                    footer
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 22)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            if store.isLoading {
                Color.black.opacity(0.12).ignoresSafeArea()
                ProgressView("Connecting securely…")
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .onChange(of: packages.map(\.identifier)) { _, identifiers in
            if selectedPackageID == nil {
                selectedPackageID = identifiers.first
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("SubclipLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .blue.opacity(0.18), radius: 22, y: 10)

            Text("Create without limits")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text("Choose a monthly plan to render polished, captioned videos on iPhone and iPad.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var benefits: some View {
        HStack(spacing: 8) {
            benefit("sparkles", "AI captions")
            benefit("bolt.fill", "Fast renders")
            benefit("arrow.down.circle.fill", "HD exports")
        }
        .padding(10)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func benefit(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var plans: some View {
        if packages.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text(store.errorMessage ?? "Loading available plans…")
                    .font(.footnote)
                    .foregroundStyle(store.errorMessage == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                if store.errorMessage != nil {
                    Button("Try Again") { Task { await store.refresh() } }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
        } else {
            VStack(spacing: 12) {
                ForEach(packages, id: \.identifier) { package in
                    planCard(package)
                }
            }
        }
    }

    private func planCard(_ package: Package) -> some View {
        let selected = selectedPackage?.identifier == package.identifier
        let studio = package.identifier.contains("studio")
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                selectedPackageID = package.identifier
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(studio ? "Studio" : "Creator")
                            .font(.headline)
                        if studio {
                            Text("BEST VALUE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                    Text(studio ? "3,000 AI credits every month" : "600 AI credits every month")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(package.storeProduct.localizedPriceString)
                        .font(.headline)
                    Text("per month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(17)
            .background(.white.opacity(selected ? 0.94 : 0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.black.opacity(0.08), lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(studio ? "Studio" : "Creator"), \(package.storeProduct.localizedPriceString) per month")
    }

    private var purchaseButton: some View {
        VStack(spacing: 10) {
            Button {
                guard let selectedPackage else { return }
                Task { _ = await store.purchase(selectedPackage) }
            } label: {
                HStack {
                    Spacer()
                    Text("Continue")
                    Image(systemName: "arrow.right")
                    Spacer()
                }
                .font(.headline)
                .padding(.vertical, 17)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .disabled(selectedPackage == nil || store.isLoading)

            if let error = store.errorMessage, !packages.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 13) {
            Button("Restore Purchases") { Task { _ = await store.restore() } }
                .font(.subheadline.weight(.semibold))

            Text("Payment is charged to your Apple ID. Your subscription renews automatically unless cancelled at least 24 hours before the end of the current period.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 18) {
                Link("Terms", destination: URL(string: "https://www.subclip.app/terms")!)
                Link("Privacy", destination: URL(string: "https://www.subclip.app/privacy")!)
                Button("Sign Out", action: onSignOut)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    private func rank(_ identifier: String) -> Int {
        identifier.contains("creator") ? 0 : 1
    }
}
#endif
