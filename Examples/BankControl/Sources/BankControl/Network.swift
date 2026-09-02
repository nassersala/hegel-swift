/// SplitMix64: a small seeded generator so a run is a function of its seed.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// How badly the network behaves. Probabilities are per send, so a message
/// that is duplicated may also see each copy delayed differently.
public struct Faults: Sendable {
    /// Probability a copy is dropped and never delivered.
    public var drop: Double
    /// Probability a sent message is delivered twice.
    public var duplicate: Double
    /// Each copy is delivered after a delay drawn uniformly from this range.
    public var delay: ClosedRange<Int>

    public init(drop: Double = 0, duplicate: Double = 0, delay: ClosedRange<Int> = 1...1) {
        precondition((0...1).contains(drop) && (0...1).contains(duplicate))
        precondition(delay.lowerBound >= 1, "a message takes at least one tick")
        self.drop = drop
        self.duplicate = duplicate
        self.delay = delay
    }

    public static let perfect = Faults()
    public static let hostile = Faults(drop: 0.3, duplicate: 0.3, delay: 1...8)
}

/// A simulated network. Sending decides a copy's fate up front; delivery
/// hands back the copies whose time has come, in a fixed order so the
/// whole simulation is deterministic.
public struct Network: Sendable {
    public struct InFlight: Hashable, Sendable {
        public let deliverAt: Int
        public let order: Int
        public let envelope: Envelope
    }

    public let faults: Faults
    public private(set) var inFlight: [InFlight] = []
    public private(set) var sent = 0
    public private(set) var dropped = 0
    public private(set) var duplicated = 0
    private var order = 0

    public init(faults: Faults) { self.faults = faults }

    public mutating func send(_ envelope: Envelope, at now: Int, using rng: inout some RandomNumberGenerator) {
        sent += 1
        var copies = 1
        if Double.random(in: 0..<1, using: &rng) < faults.duplicate {
            copies = 2
            duplicated += 1
        }
        for _ in 0..<copies {
            if Double.random(in: 0..<1, using: &rng) < faults.drop {
                dropped += 1
                continue
            }
            let delay = Int.random(in: faults.delay, using: &rng)
            inFlight.append(InFlight(deliverAt: now + delay, order: order, envelope: envelope))
            order += 1
        }
    }

    /// Remove and return every copy due at or before `now`, earliest first,
    /// ties broken by send order.
    public mutating func deliver(at now: Int) -> [Envelope] {
        let due = inFlight.filter { $0.deliverAt <= now }
            .sorted { ($0.deliverAt, $0.order) < ($1.deliverAt, $1.order) }
        inFlight.removeAll { $0.deliverAt <= now }
        return due.map(\.envelope)
    }

    public var isIdle: Bool { inFlight.isEmpty }
}
