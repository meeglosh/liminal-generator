import SwiftUI

struct TipJarSection: View {
    @EnvironmentObject private var store: TipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SUPPORT LIMINAL GENERATOR")
                .font(.spaceMono(size: 14, weight: .bold))
                .foregroundColor(.liminalCRTGreenDim)
                .accessibilityAddTraits(.isHeader)
            Text("Liminal Generator is free to use. If you enjoy it, an optional tip helps support development. Tips don’t unlock additional features.")
                .font(.system(size: 14))
                .foregroundColor(.liminalOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            if !store.canMakePayments {
                Text("In-app purchases are disabled on this device.")
                    .font(.system(size: 13))
                    .foregroundColor(.liminalOnSurfaceVariant)
            } else {
                ForEach(store.products, id: \.id) { product in
                    Button {
                        Task { await store.purchase(product) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(product.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if store.purchasingID == product.id {
                                ProgressView().tint(.liminalCRTGreenDim)
                            } else {
                                Text(product.displayPrice)
                                    .font(.spaceMono(size: 14, weight: .bold))
                            }
                        }
                        .foregroundColor(.liminalPrimary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)
                        .background(Color.liminalSurfaceContainerLow)
                        .overlay(Rectangle().stroke(Color.liminalOutlineVariant, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.purchasingID != nil || store.isLoading)
                    .accessibilityIdentifier(product.id)
                    .accessibilityHint("Optional one-time tip. Opens Apple’s purchase confirmation.")
                }
                if store.isLoading {
                    ProgressView("Loading tip amounts…")
                        .tint(.liminalCRTGreenDim)
                        .font(.system(size: 13))
                }
                if let error = store.loadError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.liminalOnSurfaceVariant)
                        .accessibilityIdentifier("tipLoadError")
                    Button("TRY AGAIN") { Task { await store.loadProducts() } }
                        .font(.spaceMono(size: 12, weight: .bold))
                        .foregroundColor(.liminalCRTGreenDim)
                        .disabled(store.isLoading || store.purchasingID != nil)
                }
                Text("One-time tips • No subscription")
                    .font(.system(size: 12))
                    .foregroundColor(.liminalOnSurfaceVariant)
            }
        }
        .padding(16)
        .overlay(Rectangle().stroke(Color.liminalOutlineVariant, lineWidth: 1))
        .task { await store.loadProducts() }
        .alert(item: $store.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }
}

/// Reuses the same tip options as About, without making users navigate credits.
struct TipJarSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                TipJarSection()
                    .padding(LiminalMetrics.marginMobile)
            }
            .background(Color.liminalBackground.ignoresSafeArea())
            .navigationTitle("BUY ME A COFFEE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.liminalBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { dismiss() }
                        .font(.spaceMono(size: 12, weight: .bold))
                        .foregroundColor(.liminalCRTGreenDim)
                        .accessibilityIdentifier("tipJarDoneButton")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
