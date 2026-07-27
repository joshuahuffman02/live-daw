import Foundation
import XCTest
@testable import AutoMix_Native

final class RehearsalStartGateTests: XCTestCase {
    private func check(_ name: String, _ passed: Bool, blocking: Bool = true) -> HD96PreflightCheck {
        HD96PreflightCheck(name: name, expected: "", observed: "", passed: passed, blocking: blocking)
    }

    // A rig wired up for rehearsal: real input + output present and technically valid,
    // but NOT 96 kHz, output not "isolated", channel count != expected, no roles yet.
    private func rehearsalRig() -> HD96PreflightReport {
        HD96PreflightReport(checks: [
            check("Input Device", true),
            check("Sample Rate", false),         // 48 kHz, say
            check("Input Channels", false),      // 24 detected vs 64 expected
            check("Stream Output", true),
            check("Output Isolation", false),    // built-in speakers, not a stream route
            check("Input Map Coverage", false),  // default map doesn't match 24
            check("Source Roles", false),        // not assigned yet
            check("Core Audio Format", true),    // DVS gives float
            check("Route Clock", true)           // in/out rates match
        ])
    }

    func testStrictGateBlocksTheRehearsalRig() {
        let gate = HD96EngineStartGate.make(from: rehearsalRig())
        XCTAssertFalse(gate.isAllowed)
    }

    func testRehearsalGateAllowsTheRehearsalRig() {
        let gate = HD96EngineStartGate.make(from: rehearsalRig(), rehearsal: true)
        XCTAssertTrue(gate.isAllowed, "rehearsal should drop the policy gates: \(gate.failureMessage)")
    }

    func testRehearsalGateStillBlocksOnMissingOutput() {
        var checks = rehearsalRig().checks
        checks = checks.map { $0.name == "Stream Output" ? check("Stream Output", false) : $0 }
        let gate = HD96EngineStartGate.make(from: HD96PreflightReport(checks: checks), rehearsal: true)
        XCTAssertFalse(gate.isAllowed, "rehearsal still needs a usable output device")
    }

    func testRehearsalGateStillBlocksOnUnsupportedFormat() {
        var checks = rehearsalRig().checks
        checks = checks.map { $0.name == "Core Audio Format" ? check("Core Audio Format", false) : $0 }
        let gate = HD96EngineStartGate.make(from: HD96PreflightReport(checks: checks), rehearsal: true)
        XCTAssertFalse(gate.isAllowed, "rehearsal still needs float-format buffers")
    }

    func testRehearsalGateStillBlocksOnClockMismatch() {
        var checks = rehearsalRig().checks
        checks = checks.map { $0.name == "Route Clock" ? check("Route Clock", false) : $0 }
        let gate = HD96EngineStartGate.make(from: HD96PreflightReport(checks: checks), rehearsal: true)
        XCTAssertFalse(gate.isAllowed, "rehearsal still needs in/out clocks to match")
    }

    func testRehearsalGateStillBlocksOnMissingInputDevice() {
        var checks = rehearsalRig().checks
        checks = checks.map { $0.name == "Input Device" ? check("Input Device", false) : $0 }
        let gate = HD96EngineStartGate.make(from: HD96PreflightReport(checks: checks), rehearsal: true)
        XCTAssertFalse(gate.isAllowed)
    }
}
