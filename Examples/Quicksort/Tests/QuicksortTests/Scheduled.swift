import Testing

/// Suites that drive the controlled scheduler, serialized as a group so
/// they do not compete for cooperative-pool threads (the reason
/// `ScheduleProperties` serializes `Reach`). Note for the record: the
/// intermittent `.stuck` first seen here was not a pool effect but the
/// lost wakeup in `ThresholdCell.read`, drawn by some seeds and not
/// others; see `Regression.lostWakeup`.
@Suite(.serialized) enum Scheduled {}
