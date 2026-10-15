import SwiftUI
import AppKit
import Combine

// MARK: - System-wide Workflow Confirmation Popup
// `WorkflowConfirmationBanner` only helps while Canopy is the frontmost app.
// A `.requiresConfirmation` step holds its run until answered, so if the
// operator is in another app, another Space, or a full-screen window, the
// run just sits there. This floats a small panel above everything — on every
// Space, over full-screen apps, without stealing focus — for as long as any
// run is waiting on an answer.
@MainActor
final class WorkflowConfirmationPanelController {
    static let shared = WorkflowConfirmationPanelController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<WorkflowConfirmationPanelContent>?
    private var cancellable: AnyCancellable?
    private var knownPending: Set<UUID> = []

    private init() {}

    /// Call once at launch.
    func start(appState: AppState) {
        guard cancellable == nil else { return }
        // `@Published` fires before the new value lands, so hop to the next
        // main-queue turn before reading `pendingConfirmationStep`.
        cancellable = appState.$activeRuns
            .map { runs in
                Publishers.MergeMany(runs.map { $0.$pendingConfirmationStep.map { _ in () } })
                    .prepend(())
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] in
                guard let appState else { return }
                self?.refresh(appState.activeRuns)
            }
    }

    private func refresh(_ runs: [WorkflowRunSession]) {
        let pending = runs.filter { !$0.isFinished && $0.pendingConfirmationStep != nil }
        let ids = Set(pending.map(\.id))
        let newIDs = ids.subtracting(knownPending)
        let hasNew = !newIDs.isEmpty
        for id in knownPending.subtracting(ids) {
            NotificationService.clearConfirmationNeeded(runID: id)
        }
        for session in pending where newIDs.contains(session.id) {
            if let step = session.pendingConfirmationStep {
                NotificationService.sendConfirmationNeeded(
                    runID: session.id, workflow: session.workflow.name, step: step.kind.title)
            }
        }
        knownPending = ids

        guard !pending.isEmpty else {
            panel?.orderOut(nil)
            return
        }

        let panel = ensurePanel()
        let content = WorkflowConfirmationPanelContent(sessions: pending)
        if let hostingView {
            hostingView.rootView = content
        }
        if let size = hostingView?.fittingSize {
            panel.setContentSize(size)
        }
        position(panel)
        panel.orderFrontRegardless()
        if hasNew { NSSound(named: "Funk")?.play() }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: WorkflowConfirmationPanelContent(sessions: []))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButtonsHidden()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        self.hostingView = hosting
        self.panel = panel
        return panel
    }

    /// Top-center of whichever screen the pointer is on — that's where the
    /// operator is most likely looking.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.maxY - size.height - 16))
    }
}

private extension NSPanel {
    func standardWindowButtonsHidden() {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }
}

struct WorkflowConfirmationPanelContent: View {
    let sessions: [WorkflowRunSession]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                if let step = session.pendingConfirmationStep {
                    row(session: session, step: step)
                    if session.id != sessions.last?.id {
                        Rectangle().fill(Color.canopyRule).frame(height: 1)
                    }
                }
            }
        }
        .font(.canopyBody)
        .frame(width: 440)
        .background(Color.canopyPaperElevated)
    }

    private func row(session: WorkflowRunSession, step: WorkflowStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\"\(session.workflow.name)\" needs your OK")
                        .font(.canopyHeadline)
                    Text("Confirm \"\(step.kind.title)\"?")
                        .font(.canopySubheadline)
                    Text(step.action.summary)
                        .font(.canopyCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Stop") { session.resolveConfirmation(proceed: false) }
                    .buttonStyle(.canopySecondary)
                Button("Continue") { session.resolveConfirmation(proceed: true) }
                    .buttonStyle(.canopyPrimary)
            }
        }
        .padding(14)
    }
}
