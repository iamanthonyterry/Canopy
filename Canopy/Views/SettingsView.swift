import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var mountResult: String?
    @State private var testingMount = false
    @State private var selectedStoreID: UUID? = nil   // nil = Custom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.canopyTitle).foregroundStyle(Color.canopyInk).padding(.horizontal)
                //cloudStoreSection
                emailSection
                AlertSettingsView()
                RemoteControlSettingsView()
                DataBackupView()
                //systemSection
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
        .background(Color.canopyPaper)
    }
    
    // MARK: - Email
    private var emailSection: some View {
        EmailNotificationsView()
    }

    // MARK: - Helpers
    private func testMount() {
        testingMount = true; mountResult = nil
        let path = appState.syncLocation.mountPath
        Task.detached(priority: .userInitiated) {
            let mounted = FileManager.default.fileExists(atPath: path)
            await MainActor.run {
                testingMount = false
                mountResult = mounted
                    ? "✅ Mounted at \(path)"
                    : "⚠️ Not mounted — will auto-mount on sync"
            }
        }
    }
}
