import ActivityKit
import Foundation

/// Starts / updates / ends the Live Activity for a session's turn.
/// Requests with `pushType: .token` so the bridge can update the Island in the
/// background via ActivityKit push (`apns-push-type: liveactivity`).
@MainActor
final class LiveActivityManager {
    private var activity: Activity<TethrXActivityAttributes>?
    private var tokenTask: Task<Void, Never>?

    /// Called when a fresh ActivityKit push token arrives — wire to bridge register.
    var onPushToken: ((String) -> Void)?

    func start(sessionName: String, phase: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil {
            update(phase: phase, detail: detail)
            return
        }
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        do {
            activity = try Activity.request(
                attributes: TethrXActivityAttributes(sessionName: sessionName),
                content: .init(state: state, staleDate: nil),
                pushType: .token
            )
            watchPushToken()
        } catch {
            // Fallback without push if the system rejects pushType
            activity = try? Activity.request(
                attributes: TethrXActivityAttributes(sessionName: sessionName),
                content: .init(state: state, staleDate: nil)
            )
        }
    }

    private func watchPushToken() {
        tokenTask?.cancel()
        guard let activity else { return }
        tokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { break }
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { self?.onPushToken?(hex) }
            }
        }
    }

    func update(phase: String, detail: String) {
        guard let activity else { return }
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end(phase: String, detail: String) {
        tokenTask?.cancel()
        tokenTask = nil
        guard let activity else { return }
        self.activity = nil
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4)) }
    }
}
