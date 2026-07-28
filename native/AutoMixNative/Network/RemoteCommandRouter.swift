import Foundation

// The control surface the remote console can drive. AppModel conforms to this
// (see MonitorBridge); tests drive a spy. Channel-index methods return false when
// the index is out of range so the router can answer the phone honestly.
protocol RemoteControlTarget: AnyObject {
    func remoteSetSafe(_ on: Bool)
    func remoteSetScene(_ scene: String) -> Bool
    func remoteSetMute(idx: Int, on: Bool) -> Bool
    func remoteSetFaderOverride(idx: Int, on: Bool, db: Double) -> Bool
    func remoteSetPanOverride(idx: Int, on: Bool, pan: Double) -> Bool
    func remoteClearOverride(idx: Int) -> Bool
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
            return target.remoteSetMute(idx: idx, on: on)
                ? CommandResult(ok: true)
                : outOfRange(idx)

        case .setFaderOverride(let idx, let on, let db):
            let clamped = db.clamped(to: ChannelMapping.faderDbOverrideRange)
            return target.remoteSetFaderOverride(idx: idx, on: on, db: clamped)
                ? CommandResult(ok: true)
                : outOfRange(idx)

        case .setPanOverride(let idx, let on, let pan):
            let clamped = pan.clamped(to: ChannelMapping.panOverrideRange)
            return target.remoteSetPanOverride(idx: idx, on: on, pan: clamped)
                ? CommandResult(ok: true)
                : outOfRange(idx)

        case .clearOverride(let idx):
            return target.remoteClearOverride(idx: idx)
                ? CommandResult(ok: true)
                : outOfRange(idx)
        }
    }

    private static func outOfRange(_ idx: Int) -> CommandResult {
        CommandResult(ok: false, message: "channel \(idx) out of range")
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
