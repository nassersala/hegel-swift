/// An interleaving as data: deviations from a default policy, applied at
/// numbered choice points. Empty means "the boring schedule", so a
/// shrunk schedule is the fewest, earliest, smallest deviations that
/// still produce the failure — a story a human reads.
///
/// The default is depth-first: the most recently enqueued job runs next,
/// so a task runs to completion before its sibling starts unless a
/// deviation says otherwise.
public struct Schedule: Sendable, Equatable, CustomStringConvertible {
    public struct Deviation: Sendable, Equatable {
        /// Which choice point (0-based count of choice points so far).
        public var choice: Int
        /// Which ready job to run instead, modulo the ready count.
        public var index: Int
        public init(choice: Int, index: Int) {
            self.choice = choice
            self.index = index
        }
    }
    public var deviations: [Deviation]

    public init(deviations: [Deviation] = []) {
        self.deviations = deviations
    }

    public var policy: Scheduler.Policy {
        let deviations = deviations
        return { ready, choice in
            if let d = deviations.first(where: { $0.choice == choice }) {
                return d.index % ready.count
            }
            return ready.count - 1
        }
    }

    public var description: String {
        deviations.isEmpty
            ? "default (depth-first) schedule"
            : deviations.map { "at choice point \($0.choice) run ready[\($0.index)]" }.joined(separator: "; ")
    }
}
