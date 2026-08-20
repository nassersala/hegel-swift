import CHegel

extension TestCase {
    /// Records a targeting observation: `score` must be finite, and higher
    /// means "more interesting". With the target phase enabled (the
    /// default), libhegel hill-climbs — biasing later test cases toward
    /// inputs that produced higher scores under the same label — which
    /// turns rare-event discovery from a lottery into a search.
    ///
    /// Each label may be recorded at most once per test case. Use distinct
    /// labels to optimize several observations independently.
    public func target(_ score: Double, label: String = "target") throws(HegelError) {
        try call(hegel_target(ctx.raw, raw, score, label))
    }
}
