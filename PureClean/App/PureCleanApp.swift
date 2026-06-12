import SwiftUI

@main
struct PureCleanApp: App {
    @StateObject private var store = StoreManager()
    @StateObject private var appState = AppState()
    @StateObject private var l10n = L10n.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(appState)
                .environmentObject(l10n)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    await store.start()
                    // Pro 自动清理：启动即扫（仍需用户预览确认，绝不静默删除照片）
                    if store.isPro && appState.autoCleanEnabled {
                        await appState.runScan(isPro: true)
                    }
                }
        }
    }
}

/// 流程路由：扫描 → 预览 → 一键清理 → 完成
struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch appState.phase {
            case .idle:
                HomeView()
            case .scanning(let progress):
                ScanProgressView(progress: progress)
            case .preview:
                PreviewView()
            case .cleaning:
                CleaningView()
            case .done(let freed):
                ResultView(freedBytes: freed)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.phase)
    }
}
