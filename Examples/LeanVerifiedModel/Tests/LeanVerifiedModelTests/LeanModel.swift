import COtp
import LoginUI

/// The abstract state as the C boundary carries it, evaluated by the
/// Lean-compiled `step`. The counter is a real number, not a state per count.
struct LeanModel: Sendable, CustomStringConvertible, Equatable {
    var screen: UInt8
    var attempts: UInt32

    /// Computed, not stored: `otp_init` also initialises the calling
    /// thread for Lean, and tests run on several threads.
    static var initial: LeanModel {
        otp_init()
        return LeanModel(packed: otp_initial_state())
    }

    init(packed: UInt64) {
        screen = UInt8((packed >> 8) & 0xff)
        attempts = UInt32(packed >> 16)
    }

    func enabled(_ s: Stimulus) -> Bool { otp_enabled(screen, attempts, s.rawValue) == 1 }

    mutating func step(_ s: Stimulus) -> Response {
        let packed = otp_step(screen, attempts, s.rawValue)
        self = LeanModel(packed: packed)
        return Response(rawValue: UInt8(packed & 0xff))!
    }

    var description: String { "\(["phone", "code", "locked", "home"][Int(screen)])/\(attempts)" }
}

struct Drift: Error, CustomStringConvertible {
    let sut: String
    let model: LeanModel
    var description: String { "screen \(sut) vs model \(model)" }
}
