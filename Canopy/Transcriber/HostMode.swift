import AppKit
import ChurchKitCore
import Combine

/// Transcriber ships two ways: on its own (Sparkle updates it, "Open at login" is its own switch) and
/// nested inside Canopy at Contents/Library/LoginItems, where Canopy updates it and starts it at login.
nonisolated enum HostMode {
    static let isNested = Bundle.main.bundleURL.path.contains("/Contents/Library/LoginItems/")
}

/// Publishes the helper's state to the shared status file so Canopy can show it. Written when something
/// changes and every 30 seconds while alive; removed when the app quits.
@MainActor
final class StatusPublisher {
    private weak var model: AppModel?
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        // The audio level changes many times a second, so look at most once a second and write only real changes.
        model.objectWillChange.throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.write(onlyIfChanged: true) }.store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: HelperStatus.heartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.write(); self?.model?.checkHandoff() }
        }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in HelperStatus.clear() }.store(in: &cancellables)
        write()
    }

    private var last: HelperStatus?

    private func write(onlyIfChanged: Bool = false) {
        guard let model else { return }
        let status = HelperStatus(
            running: model.running, listening: model.listening, connectedTo: model.settings.connectedTo,
            warning: model.feedWarning,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
        if onlyIfChanged, let last,
           (last.running, last.listening, last.connectedTo, last.warning) == (status.running, status.listening, status.connectedTo, status.warning) { return }
        last = status
        status.write()
    }
}
