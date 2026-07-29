import Foundation

// Conformance that lets the remote console drive the same control-rate paths the
// desktop UI uses. Methods are nonisolated to satisfy the non-isolated protocol, but
// only ever invoked on the main actor (MonitorBridge hops there first), so
// assumeIsolated is safe. No audio-thread work happens here.
extension AppModel: RemoteControlTarget {
    nonisolated func remoteSetSafe(_ on: Bool) {
        MainActor.assumeIsolated { self.safeBypass = on }
    }

    nonisolated func remoteSetScene(_ scene: String) -> Bool {
        MainActor.assumeIsolated {
            guard let mixScene = MixScene(rawValue: scene) else { return false }
            self.selectedScene = mixScene
            return true
        }
    }

    nonisolated func remoteSetMute(
        idx: Int,
        on: Bool
    ) -> RemoteChannelMutationResult {
        mutateChannel(idx) { $0.setMuted(on) }
    }

    nonisolated func remoteSetFaderOverride(
        idx: Int,
        on: Bool,
        db: Double
    ) -> RemoteChannelMutationResult {
        mutateChannel(idx) {
            $0.muted = false
            $0.faderOverrideEnabled = on
            $0.faderDb = db
        }
    }

    nonisolated func remoteSetPanOverride(
        idx: Int,
        on: Bool,
        pan: Double
    ) -> RemoteChannelMutationResult {
        mutateChannel(idx) {
            $0.panOverrideEnabled = on
            $0.pan = pan
        }
    }

    nonisolated func remoteClearOverride(
        idx: Int
    ) -> RemoteChannelMutationResult {
        mutateChannel(idx) { $0.clearOverrides() }
    }

    private nonisolated func mutateChannel(
        _ idx: Int,
        _ change: @Sendable (inout ChannelMapping) -> Void
    ) -> RemoteChannelMutationResult {
        MainActor.assumeIsolated {
            guard let pos = self.channelMappings.firstIndex(where: { $0.index == idx }) else {
                return .channelOutOfRange
            }
            change(&self.channelMappings[pos])
            return self.channelDidChange(self.channelMappings[pos])
                ? .applied
                : .nativeControlRejected
        }
    }
}
