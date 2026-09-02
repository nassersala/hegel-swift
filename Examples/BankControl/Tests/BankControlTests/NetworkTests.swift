import Testing
@testable import BankControl

@Suite struct NetworkTests {
    let env = Envelope(
        from: .teller(TellerID(1)), to: .ledger,
        message: .request(Request(id: RequestID(teller: TellerID(1), sequence: 0),
                                  operation: .balance(AccountID(1)))))

    @Test func perfectNetworkDeliversOnceAfterOneTick() {
        var rng = SeededGenerator(seed: 1)
        var net = Network(faults: .perfect)
        net.send(env, at: 0, using: &rng)
        #expect(net.deliver(at: 0).isEmpty)
        #expect(net.deliver(at: 1) == [env])
        #expect(net.deliver(at: 2).isEmpty)
        #expect(net.isIdle)
    }

    @Test func dropEverythingDeliversNothing() {
        var rng = SeededGenerator(seed: 1)
        var net = Network(faults: Faults(drop: 1))
        for _ in 0..<20 { net.send(env, at: 0, using: &rng) }
        #expect(net.isIdle)
        #expect(net.dropped == 20)
    }

    @Test func duplicateEverythingDeliversTwice() {
        var rng = SeededGenerator(seed: 1)
        var net = Network(faults: Faults(duplicate: 1))
        net.send(env, at: 0, using: &rng)
        #expect(net.deliver(at: 1) == [env, env])
    }

    @Test func delayedCopiesAreDeliveredInTimeOrder() {
        var rng = SeededGenerator(seed: 7)
        var net = Network(faults: Faults(delay: 1...5))
        for _ in 0..<50 { net.send(env, at: 0, using: &rng) }
        var seen = 0
        var previous = -1
        for now in 0...5 {
            let batch = net.deliver(at: now)
            seen += batch.count
            #expect(batch.isEmpty || now > previous)
            if !batch.isEmpty { previous = now }
        }
        #expect(seen == 50)
        #expect(net.isIdle)
    }

    @Test func sameSeedSameFate() {
        func run(seed: UInt64) -> [Int] {
            var rng = SeededGenerator(seed: seed)
            var net = Network(faults: .hostile)
            for _ in 0..<30 { net.send(env, at: 0, using: &rng) }
            return net.inFlight.map(\.deliverAt)
        }
        #expect(run(seed: 42) == run(seed: 42))
        #expect(run(seed: 42) != run(seed: 43))
    }
}
