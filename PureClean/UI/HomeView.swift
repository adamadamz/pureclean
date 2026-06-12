import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager
    @EnvironmentObject var l10n: L10n
    @State private var showSettings = false
    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("PureClean")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if store.isPro {
                    Text("PRO")
                        .font(.system(size: 11, weight: .heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent.opacity(0.2)))
                        .foregroundStyle(Theme.accent)
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            StorageRing(storage: appState.storage)
                .frame(height: 190)
                .padding(.top, 8)

            VStack(spacing: 12) {
                FeatureRow(icon: "internaldrive", title: l10n.t("home.cache"),
                           subtitle: l10n.t("home.cache.sub"))
                FeatureRow(icon: "trash", title: l10n.t("home.junk"),
                           subtitle: l10n.t("home.junk.sub"))
                FeatureRow(icon: "photo.on.rectangle.angled", title: l10n.t("home.photos"),
                           subtitle: l10n.t("home.photos.sub"))
            }

            Spacer()

            Text(l10n.t("home.privacy"))
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button(l10n.t("home.scan")) {
                Task { await appState.runScan(isPro: store.isPro) }
            }
            .buttonStyle(PrimaryButtonStyle())

            if !store.isPro {
                Button(l10n.t("home.upgrade")) { showPaywall = true }
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(20)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}

/// 存储占用环形图
struct StorageRing: View {
    @EnvironmentObject var l10n: L10n
    let storage: DeviceStorage

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.card, lineWidth: 14)
            Circle()
                .trim(from: 0, to: storage.usedFraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text(formatBytes(storage.usedBytes))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(l10n.t("home.used", formatBytes(storage.totalBytes)))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(8)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .card()
    }
}
