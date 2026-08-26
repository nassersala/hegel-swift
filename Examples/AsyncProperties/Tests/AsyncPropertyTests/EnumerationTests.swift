import Testing
import AsyncSequenceValidation

extension AsyncProperties {
    /// Every single-source script up to three events and three demands,
    /// through model and runtime. No randomness: this is the floor the
    /// random laws stand on.
    @Suite struct Enumeration {
        static func sequences<T>(_ alphabet: [T], upTo n: Int) -> [[T]] {
            var out: [[T]] = [[]]
            var layer: [[T]] = [[]]
            for _ in 0..<n {
                layer = layer.flatMap { prefix in alphabet.map { prefix + [$0] } }
                out += layer
            }
            return out
        }

        static let sources: [[Script.Event]] = sequences([Script.Event.value, .delay(1)], upTo: 3)
            .flatMap { body in [body, body + [.finish], body + [.failure]] }
        static let consumers: [[Script.Demand]] = sequences([Script.Demand.next, .wait(1)], upTo: 3)
        static var scripts: [Script] { sources.flatMap { s in consumers.map { Script(sources: [s], consumer: $0) } } }

        @Test func mergeOfOne() throws {
            for script in Self.scripts { try Model.mergeExact(script, try Harness.merge(script)) }
        }

        @Test func buffer() throws {
            for policy in [BufferPolicy.unbounded, .bounded(0), .bounded(1), .bufferingOldest(1), .bufferingLatest(1)] {
                for script in Self.scripts {
                    try expectTrace(Sim.buffer(script, policy: policy), try Harness.buffer(script, policy: policy))
                }
            }
        }

        @Test func throttle() throws {
            for k in 0...2 {
                for latest in [true, false] {
                    for script in Self.scripts {
                        try expectTrace(Sim.throttle(script, steps: k, latest: latest), try Harness.throttle(script, steps: k, latest: latest))
                    }
                }
            }
        }

        /// Finishing sources, continuous consumer (the two documented
        /// debounce restrictions).
        @Test func debounce() throws {
            for k in 0...2 {
                for source in Self.sources where source.last == .finish {
                    let script = Script(sources: [source], consumer: Array(repeating: .next, count: source.count + 2))
                    try expectTrace(Sim.debounce(script, steps: k), try Harness.debounce(script, steps: k))
                }
            }
        }
    }
}
