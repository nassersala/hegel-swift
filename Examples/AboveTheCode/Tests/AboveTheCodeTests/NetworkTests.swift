import Testing
import HegelTesting
import AboveTheCode

/// Die Hard again, with the algorithm as the trace. The state is every
/// zero-one vector of length n, a rule is one comparator on all of them,
/// the false invariant is "not all sorted", and the shrunk counterexample
/// is a sorting network. Unlike Die Hard the witness certifies itself:
/// the goal is exact on a finite state, so by the zero-one principle any
/// trace that reaches it sorts every input of length n.
@Suite struct SortingNetworks {
    @Test func theTraceIsANetwork() throws {
        let network = try #require(try searchNetwork(n: 4, seed: 1))
        print("n = 4, seed 1: \(network.map(\.description).joined(separator: "; ")) — \(network.count) comparators")
        #expect(sortsAllZeroOne(network, n: 4))
        #expect(sortsAllPermutations(network, n: 4))
        // Five is the optimum for n = 4, so this is a theorem; the
        // prediction was ≤ 6, and the report below records what the
        // shrinker's local minimum actually is by seed.
        #expect(network.count >= 5)
    }

    /// Every comparator with i < j keeps sorted vectors sorted and never
    /// raises a vector's inversion count, and while any vector is unsorted
    /// some comparator strictly lowers it; so a long enough random walk
    /// reaches the goal almost surely. Prediction: 20 of 20 at the default
    /// 50 steps, seeded or not.
    @Test func reportHitRateAndSizeForN4() throws {
        var bySeed: [(UInt64, Int)] = []
        var sizes: [Int: Int] = [:]
        for seed in UInt64(1)...20 {
            let network = try #require(try searchNetwork(n: 4, seed: seed))
            #expect(sortsAllPermutations(network, n: 4))
            bySeed.append((seed, network.count))
            sizes[network.count, default: 0] += 1
        }
        var unseededHits = 0
        for _ in 0..<20 where try searchNetwork(n: 4) != nil { unseededHits += 1 }
        print("n = 4: unseeded hits \(unseededHits)/20; seeded sizes " +
              sizes.sorted { $0.key < $1.key }.map { "\($0.value)×\($0.key)" }.joined(separator: ", ") +
              "; by seed " + bySeed.map { "\($0.0):\($0.1)" }.joined(separator: " "))
        #expect(unseededHits >= 19)
    }

    /// n = 5: 32 vectors, 10 comparators, optimum 9. The walk is monotone,
    /// so discovery cost only shows under a step budget near the optimum.
    /// The score is the negative unsorted count, the one that moves. First
    /// run, 20 seeds, 200 cases: steps 9 random 0 targeted 1; 10: 1 vs 3;
    /// 12: 6 vs 11; 16: 20 vs 17; 50: 20 vs 20. Targeting helps at the
    /// optimum and costs three hits with slack; sizes 9 everywhere but
    /// four 10s at 50 steps.
    @Test func reportTargetingForN5() throws {
        var lines: [String] = []
        for steps in [Int64(10), 12, 16, 50] {
            var random = 0, targeted = 0
            var sizes: [Int] = []
            for seed in UInt64(1)...10 {
                if let net = try searchNetwork(n: 5, seed: seed, testCases: 100, steps: steps) {
                    random += 1
                    sizes.append(net.count)
                    #expect(sortsAllPermutations(net, n: 5))
                }
                if try searchNetwork(n: 5, seed: seed, testCases: 100, steps: steps, targeted: true) != nil { targeted += 1 }
            }
            lines.append("steps \(steps): random \(random)/10, targeted \(targeted)/10, sizes \(sizes.sorted())")
        }
        print("n = 5:\n  " + lines.joined(separator: "\n  "))
    }
}
