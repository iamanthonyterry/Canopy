import SwiftUI
import Combine

/// Sections of the app that can be switched on or off from Settings.
/// Dashboard, Starred, Export Queue, History and Settings are always on.
enum AppFeature: String, CaseIterable, Identifiable {
    case workflows
    case inventory
    case socialShare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workflows:   return "Workflows"
        case .inventory:   return "Inventory"
        case .socialShare: return "Social Share"
        }
    }

    var icon: String {
        switch self {
        case .workflows:   return "flowchart"
        case .inventory:   return "shippingbox"
        case .socialShare: return "paperplane"
        }
    }

    var summary: String {
        switch self {
        case .workflows:   return "Build and run offload, convert and export workflows."
        case .inventory:   return "Track devices, rooms, patches and the system map."
        case .socialShare: return "Share clips to social channels. Coming soon."
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .workflows:   return true
        case .inventory, .socialShare: return false
        }
    }
}

/// Persisted on/off state for each `AppFeature`.
@MainActor
final class AppFeatures: ObservableObject {
    static let shared = AppFeatures()

    private let defaults = UserDefaults.standard
    private func key(_ feature: AppFeature) -> String { "feature.\(feature.rawValue).enabled" }

    func isEnabled(_ feature: AppFeature) -> Bool {
        defaults.object(forKey: key(feature)) as? Bool ?? feature.defaultEnabled
    }

    func setEnabled(_ feature: AppFeature, _ on: Bool) {
        objectWillChange.send()
        defaults.set(on, forKey: key(feature))
    }

    func binding(for feature: AppFeature) -> Binding<Bool> {
        Binding(get: { self.isEnabled(feature) }, set: { self.setEnabled(feature, $0) })
    }
}
