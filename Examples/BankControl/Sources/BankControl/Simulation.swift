/// The bank as one value stepping through discrete time. Each tick delivers
/// what the network has due, lets the ledger answer, lets tellers see
/// replies, then runs any scripted submissions for the tick and lets the
/// tellers send and resend.
public struct Simulation: Sendable {
    public struct Action: Hashable, Sendable {
        public let at: Int
        public let teller: TellerID
        public let operation: Operation
        public init(at: Int, teller: TellerID, operation: Operation) {
            self.at = at
            self.teller = teller
            self.operation = operation
        }
    }

    public private(set) var now = 0
    public private(set) var ledger: Ledger
    public private(set) var tellers: [TellerID: Teller]
    public private(set) var network: Network
    public private(set) var script: [Action]
    private var rng: SeededGenerator

    public init(
        ledger: Ledger,
        tellers: [Teller],
        faults: Faults,
        script: [Action],
        seed: UInt64
    ) {
        self.ledger = ledger
        self.tellers = Dictionary(uniqueKeysWithValues: tellers.map { ($0.id, $0) })
        self.network = Network(faults: faults)
        self.script = script.sorted { ($0.at, $0.teller) < ($1.at, $1.teller) }
        self.rng = SeededGenerator(seed: seed)
    }

    public mutating func step() {
        // 1. Deliver. Requests reach the ledger; replies reach tellers.
        for envelope in network.deliver(at: now) {
            switch (envelope.to, envelope.message) {
            case (.ledger, .request(let request)):
                let reply = ledger.handle(request)
                network.send(
                    Envelope(from: .ledger, to: envelope.from, message: .reply(reply)),
                    at: now, using: &rng)
            case (.teller(let id), .reply(let reply)):
                tellers[id]?.receive(reply)
            default:
                preconditionFailure("misrouted \(envelope)")
            }
        }
        // 2. Scripted submissions for this tick.
        while let next = script.first, next.at <= now {
            script.removeFirst()
            tellers[next.teller]?.submit(next.operation)
        }
        // 3. Tellers send and resend.
        for id in tellers.keys.sorted() {
            for request in tellers[id]!.tick(now: now) {
                network.send(
                    Envelope(from: .teller(id), to: .ledger, message: .request(request)),
                    at: now, using: &rng)
            }
        }
        now += 1
    }

    /// Nothing scripted, nothing in flight, nothing pending.
    public var isQuiescent: Bool {
        script.isEmpty && network.isIdle && tellers.values.allSatisfy(\.isIdle)
    }

    /// Step until quiescent or `limit` ticks have passed. Returns whether
    /// quiescence was reached. `observe` sees the state after every step.
    @discardableResult
    public mutating func run(limit: Int, observe: (Simulation) -> Void = { _ in }) -> Bool {
        while !isQuiescent && now < limit {
            step()
            observe(self)
        }
        return isQuiescent
    }
}
