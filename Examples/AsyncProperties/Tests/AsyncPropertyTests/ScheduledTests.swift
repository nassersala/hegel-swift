import Testing
import HegelTesting
import AsyncAlgorithms
import AsyncSequenceValidation

extension AsyncProperties {
    /// E2 applied to the operators: the order of a batch of ready jobs
    /// is a drawn `TieSchedule`. Ties are allowed everywhere; the laws
    /// are the acceptance models (sets of legal traces) and cancellation.
    @Suite struct ScheduledLaws {
        static let pair = Script.gen(sources: 2...2, endings: .any, allowCancel: false, enoughDemand: false)
        static let upToThree = Script.gen(sources: 1...3, endings: .any, allowCancel: false, enoughDemand: false)

        @Test(.propertyTesting) func merge() {
            expectAll(Hegel.zip(Self.upToThree, TieSchedule.gen), testCases: budget, database: "") { script, schedule in
                try Model.merge(script, try Harness.merge(script, schedule: schedule))
            }
        }

        @Test(.propertyTesting) func zip() {
            expectAll(Hegel.zip(Self.pair, TieSchedule.gen), testCases: budget, database: "") { script, schedule in
                try Model.zip(script, try Harness.zip(script, schedule: schedule))
            }
        }

        @Test(.propertyTesting) func combineLatest() {
            expectAll(Hegel.zip(Self.pair, TieSchedule.gen), testCases: budget, database: "") { script, schedule in
                try Model.combineLatest(script, try Harness.combineLatest(script, schedule: schedule))
            }
        }

        @Test(.propertyTesting) func cancellationEverywhere() {
            let ops: Gen<Int64> = .int(in: 0...6)
            expectAll(Hegel.zip(Script.cancelling(sources: 2...2), TieSchedule.gen, ops), testCases: budget, database: "") { s, schedule, op in
                let trace: Trace
                switch op {
                case 0: trace = try Harness.merge(s, persistent: true, schedule: schedule)
                case 1: trace = try Harness.zip(s, persistent: true, schedule: schedule)
                case 2: trace = try Harness.combineLatest(s, persistent: true, schedule: schedule)
                case 3: trace = try Harness.chunks(s, count: 2, persistent: true, schedule: schedule)
                case 4: trace = try Harness.buffer(s, policy: .bounded(1), persistent: true, schedule: schedule)
                case 5: trace = try Harness.debounce(s, steps: 1, persistent: true, schedule: schedule)
                default: trace = try Harness.throttle(s, steps: 1, latest: true, persistent: true, schedule: schedule)
                }
                try Model.cancellation(s, trace)
            }
        }

        /// Continuous consumer: with demand gaps debounce emits superseded
        /// values by design (`debounceSlowConsumerEmitsSupersededValue`),
        /// which this law would flag regardless of schedule.
        static let finishingSingle = Script.source(endings: .finish).map { events in
            Script(sources: [events], consumer: Array(repeating: .next, count: events.count + 2))
        }
        static let anySingle = Script.gen(sources: 1...1, endings: .any, allowCancel: false, enoughDemand: true)
        static let intervals = Gen<Int64>.int(in: 0...4).map { Int($0) }

        @Test(.propertyTesting) func debounceLosesNothing() {
            expectAll(Hegel.zip(Self.finishingSingle, Self.intervals, TieSchedule.gen), testCases: budget, database: "") { script, k, schedule in
                try Model.debounceAccepts(script, steps: k, try Harness.debounce(script, steps: k, schedule: schedule))
            }
        }

        @Test(.propertyTesting) func bufferLosesNothing() {
            let policies: Gen<BufferPolicy> = Gen<Int64>.int(in: 0...3).map { $0 == 0 ? .unbounded : .bounded(Int($0)) }
            expectAll(Hegel.zip(Self.anySingle, policies, TieSchedule.gen), testCases: budget, database: "") { script, policy, schedule in
                try Model.bufferNoLoss(script, try Harness.buffer(script, policy: policy, schedule: schedule))
            }
        }

        @Test(.propertyTesting) func chunksReassemble() {
            let pairs = Script.gen(sources: 2...2, endings: .any, allowCancel: false, enoughDemand: true)
            expectAll(Hegel.zip(pairs, SweepLaws.counts, TieSchedule.gen), testCases: budget, database: "") { script, count, schedule in
                try Model.chunksAccept(script, count: count, try Harness.chunks(script, count: count, schedule: schedule))
            }
        }

        /// Over the generated distribution: how many runs meet a choice
        /// point at all, and how many distinct traces one script yields.
        @Test func distributionInstrumentation() throws {
            var runs = 0, withChoice = 0, widths: [Int] = []
            try forAll(Hegel.zip(Self.pair, TieSchedule.gen), testCases: 500, database: "") { script, schedule in
                let t = try Harness.combineLatest(script, schedule: schedule)
                runs += 1
                if t.choicePoints > 0 { withChoice += 1 }
                widths.append(t.maxReadyWidth)
            }
            print("scheduled distribution: \(withChoice)/\(runs) runs met a choice point; max ready width \(widths.max() ?? 0); mean \(Double(widths.reduce(0, +)) / Double(max(runs, 1)))")
            #expect(withChoice > runs / 2)
        }

        /// Instrumentation, as the spec asks before claiming exploration:
        /// on a script with ties, drawn schedules must reach choice points
        /// and produce more than one distinct trace.
        @Test func schedulesChangeOutcomes() throws {
            let script = Script(sources: [[.value, .delay(1), .failure], [.value, .value, .value, .finish]], consumer: [.wait(1), .next, .next])
            #expect(script.inputDiagrams == ["a-^", "ABC|"] && script.outputDiagram == "-xx")
            var traces = Set<String>(), choice = 0, width = 0
            try forAll(TieSchedule.gen, testCases: 300, database: "") { schedule in
                let t = try Harness.combineLatest(script, schedule: schedule)
                traces.insert(t.description)
                choice = max(choice, t.choicePoints)
                width = max(width, t.maxReadyWidth)
            }
            print("scheduled combineLatest on a-^/ABC|: traces \(traces.sorted()), choice points ≤ \(choice), max width \(width)")
            #expect(traces.count >= 2)
            #expect(traces.contains("aA@1 aB@2 ^@3") && traces.contains("aA@1 aB@2 aC@3 …@3"))
        }
    }
}
