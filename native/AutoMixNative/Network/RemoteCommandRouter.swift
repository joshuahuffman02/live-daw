import Foundation

// The control surface the remote console can drive. AppModel conforms to this
// (see MonitorBridge); tests drive a spy. Channel-index methods distinguish an
// invalid index from a native-control rejection so the router can answer honestly.
protocol RemoteControlTarget: AnyObject {
    func remoteSetSafe(_ on: Bool)
    func remoteSetScene(_ scene: String) -> Bool
    func remoteSetMute(idx: Int, on: Bool) -> RemoteChannelMutationResult
    func remoteSetFaderOverride(idx: Int, on: Bool, db: Double) -> RemoteChannelMutationResult
    func remoteSetPanOverride(idx: Int, on: Bool, pan: Double) -> RemoteChannelMutationResult
    func remoteClearOverride(idx: Int) -> RemoteChannelMutationResult
}

enum RemoteChannelMutationResult: Equatable, Sendable {
    case applied
    case channelOutOfRange
    case nativeControlRejected
}

enum RemoteCommandRouter {
    static func apply(_ command: RemoteCommand, to target: RemoteControlTarget) -> CommandResult {
        switch command {
        case .setSafe(let on):
            target.remoteSetSafe(on)
            return CommandResult(ok: true)

        case .setFreeze:
            return CommandResult(
                ok: false,
                message: "FREEZE is local-only; use the Mac"
            )

        case .setScene(let scene):
            return target.remoteSetScene(scene)
                ? CommandResult(ok: true)
                : CommandResult(ok: false, message: "unknown scene \(scene)")

        case .setMute(let idx, let on):
            return channelResult(
                target.remoteSetMute(idx: idx, on: on),
                idx: idx
            )

        case .setFaderOverride(let idx, let on, let db):
            let clamped = db.clamped(to: ChannelMapping.faderDbOverrideRange)
            return channelResult(
                target.remoteSetFaderOverride(idx: idx, on: on, db: clamped),
                idx: idx
            )

        case .setPanOverride(let idx, let on, let pan):
            let clamped = pan.clamped(to: ChannelMapping.panOverrideRange)
            return channelResult(
                target.remoteSetPanOverride(idx: idx, on: on, pan: clamped),
                idx: idx
            )

        case .clearOverride(let idx):
            return channelResult(
                target.remoteClearOverride(idx: idx),
                idx: idx
            )
        }
    }

    private static func channelResult(
        _ result: RemoteChannelMutationResult,
        idx: Int
    ) -> CommandResult {
        switch result {
        case .applied:
            return CommandResult(ok: true)
        case .channelOutOfRange:
            return CommandResult(
                ok: false,
                message: "channel \(idx) out of range"
            )
        case .nativeControlRejected:
            return CommandResult(
                ok: false,
                message: "channel \(idx) control was not applied; check the Mac"
            )
        }
    }
}

enum RemoteCommandExecutor {
    static func execute(
        _ command: RemoteCommand,
        to target: RemoteControlTarget,
        nowMs: Int64,
        deadlineMs: Int64
    ) -> CommandResult {
        guard RemoteCommandExecutionWindow.canExecute(
            nowMs: nowMs,
            deadlineMs: deadlineMs
        ) else {
            return CommandResult(
                ok: false,
                message: "control expired before execution"
            )
        }
        return RemoteCommandRouter.apply(command, to: target)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
