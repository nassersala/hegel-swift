import Testing
import HegelTesting
import AsyncAlgorithms
import AsyncSequenceValidation

extension AsyncProperties {
    /// `Model.cancellation` for every operator, 10k scripts each, with a
    /// consumer that keeps demanding after its task is cancelled.
    @Suite struct CancellationLaws {
        static let one = Script.cancelling(sources: 1...1)
        static let two = Script.cancelling(sources: 2...2)
        static let upToThree = Script.cancelling(sources: 1...3)
        static let intervals = Gen<Int64>.int(in: 0...4).map { Int($0) }

        @Test(.propertyTesting) func merge() {
            expectAll(Self.upToThree, testCases: budget, database: "") { s in
                try Model.cancellation(s, try Harness.merge(s, persistent: true))
            }
        }
        @Test(.propertyTesting) func zip() {
            expectAll(Self.two, testCases: budget, database: "") { s in
                try Model.cancellation(s, try Harness.zip(s, persistent: true))
            }
        }
        @Test(.propertyTesting) func combineLatest() {
            expectAll(Self.two, testCases: budget, database: "") { s in
                try Model.cancellation(s, try Harness.combineLatest(s, persistent: true))
            }
        }
        @Test(.propertyTesting) func buffer() {
            expectAll(Hegel.zip(Self.one, TimedLaws.policies), testCases: budget, database: "") { s, policy in
                try Model.cancellation(s, try Harness.buffer(s, policy: policy, persistent: true))
            }
        }
        @Test(.propertyTesting) func throttle() {
            expectAll(Hegel.zip(Self.one, Self.intervals, .bool), testCases: budget, database: "") { s, k, latest in
                try Model.cancellation(s, try Harness.throttle(s, steps: k, latest: latest, persistent: true))
            }
        }
        @Test(.propertyTesting) func debounce() {
            expectAll(Hegel.zip(Self.one, Self.intervals), testCases: budget, database: "") { s, k in
                try Model.cancellation(s, try Harness.debounce(s, steps: k, persistent: true))
            }
        }
        @Test(.propertyTesting) func chunks() {
            expectAll(Hegel.zip(Self.two, SweepLaws.counts), testCases: budget, database: "") { s, count in
                try Model.cancellation(s, try Harness.chunks(s, count: count, persistent: true))
            }
        }
    }
}
