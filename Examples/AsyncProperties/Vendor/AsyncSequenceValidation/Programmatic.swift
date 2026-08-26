//===----------------------------------------------------------------------===//
//
// Added by hegel-swift's AsyncProperties example on top of the vendored
// swift-async-algorithms 1.1.5 sources. Same license as the rest of this
// directory (Apache License v2.0 with Runtime Library Exception).
//
//===----------------------------------------------------------------------===//

import _CAsyncSequenceValidationSupport
import AsyncAlgorithms

@available(AsyncAlgorithms 1.0, *)
extension AsyncSequenceValidationDiagram {
  /// One thing the consumer saw, stamped with the fake clock's tick.
  public enum Observation: Sendable, Equatable, CustomStringConvertible {
    /// `next()` returned a value.
    case value(String, tick: Int)
    /// `next()` returned nil.
    case finish(tick: Int)
    /// `next()` threw the diagram's failure (`^`).
    case failure(tick: Int)
    /// `next()` threw `CancellationError`.
    case cancelled(tick: Int)
    /// `next()` threw something else; the description is kept.
    case error(String, tick: Int)
    /// The consumer stopped demanding (its demand timeline ran out), so
    /// the sequence was never observed past this tick.
    case demandExhausted(tick: Int)

    public var tick: Int {
      switch self {
      case .value(_, let t), .finish(let t), .failure(let t), .cancelled(let t),
        .error(_, let t), .demandExhausted(let t):
        return t
      }
    }

    public var description: String {
      switch self {
      case .value(let v, let t): return "\(v)@\(t)"
      case .finish(let t): return "|@\(t)"
      case .failure(let t): return "^@\(t)"
      case .cancelled(let t): return ";@\(t)"
      case .error(let e, let t): return "error(\(e))@\(t)"
      case .demandExhausted(let t): return "…@\(t)"
      }
    }
  }

  /// The trace of one programmatic run.
  public struct Trace: Sendable, Equatable, CustomStringConvertible {
    /// Everything the consumer observed, in order.
    public var events: [Observation]
    /// The tick at which each `next()` call was issued, in order. One
    /// entry per event (the consumer stops after a terminal event).
    public var demandTicks: [Int]
    /// Choice points met (batches of two or more ready items) and the
    /// ready-set width high-water mark.
    public var choicePoints: Int = 0
    public var maxReadyWidth: Int = 0
    /// One line per deviation from the default order the schedule took.
    public var scheduleLog: [String] = []

    public var description: String {
      events.map(\.description).joined(separator: " ")
    }
  }

  /// A consumer that follows the output diagram's demand timeline exactly
  /// like the upstream `Test` does, but records every result including
  /// the terminal one and the tick each `next()` was issued at.
  struct RecordingTest<Operation: AsyncSequence & Sendable>: AsyncSequenceValidationTest, @unchecked Sendable
  where Operation.Element == String {
    let inputs: [Specification]
    let sequence: Operation
    let output: Specification
    let trace: ManagedCriticalState<Trace>
    let finished: ManagedCriticalState<Bool>
    /// Keep demanding after the task is cancelled (what a `for await`
    /// loop does): the cancelled sleep is recorded as `.cancelled` only
    /// when this is false.
    let persistent: Bool

    func record(_ observation: Observation, demandedAt tick: Int) {
      trace.withCriticalRegion { t in
        t.events.append(observation)
        t.demandTicks.append(tick)
      }
    }

    func test<C: TestClock>(
      with clock: C,
      activeTicks: [C.Instant],
      output: Specification,
      _ event: (String) -> Void
    ) async throws {
      var iterator = sequence.makeAsyncIterator()
      var terminated = false
      for tick in activeTicks {
        if tick != clock.now {
          do {
            try await clock.sleep(until: tick, tolerance: nil)
          } catch is CancellationError {
            if persistent {
              // Sleep cut short; demand now anyway.
            } else {
              // Cancelled while waiting to demand: the consumer never issues
              // this demand. Recorded so the trace still ends in a terminal.
              let now = Context.clock!.now.when.rawValue
              record(.cancelled(tick: now), demandedAt: now)
              terminated = true
              break
            }
          }
        }
        let demanded = Context.clock!.now.when.rawValue
        do {
          if let item = try await iterator.next() {
            record(.value(item, tick: Context.clock!.now.when.rawValue), demandedAt: demanded)
          } else {
            record(.finish(tick: Context.clock!.now.when.rawValue), demandedAt: demanded)
            terminated = true
            break
          }
        } catch is Failure {
          record(.failure(tick: Context.clock!.now.when.rawValue), demandedAt: demanded)
          terminated = true
          break
        } catch is CancellationError {
          record(.cancelled(tick: Context.clock!.now.when.rawValue), demandedAt: demanded)
          terminated = true
          break
        } catch {
          record(.error(String(describing: error), tick: Context.clock!.now.when.rawValue), demandedAt: demanded)
          terminated = true
          break
        }
      }
      if !terminated {
        record(.demandExhausted(tick: Context.clock!.now.when.rawValue), demandedAt: Context.clock!.now.when.rawValue)
      }
      finished.withCriticalRegion { $0 = true }
    }
  }

  /// Runs `operation` over the parsed `inputs` under the deterministic
  /// clock, driving the consumer along `output`'s demand timeline (its
  /// value symbols are demand points; `;` cancels the consumer; the
  /// diagram's own expected values are ignored). Returns everything the
  /// consumer observed.
  ///
  /// Like `test(theme:_:)`, this installs the global enqueue hook for the
  /// duration of the run and must not be called concurrently.
  public static func run<Operation: AsyncSequence & Sendable>(
    inputs: [String],
    output: String,
    theme: ASCIITheme = .ascii,
    slack: Int = 32,
    persistentConsumer: Bool = false,
    schedule: ((_ ready: [String], _ choice: Int) -> Int)? = nil,
    file: StaticString = #file,
    line: UInt = #line,
    operation: (AsyncSequenceValidationDiagram) -> Operation
  ) throws -> Trace where Operation.Element == String {
    let location = SourceLocation(file: file, line: line)
    let policy = SchedulePolicy(pick: schedule)
    let diagram = AsyncSequenceValidationDiagram(policy: policy)
    let clock = diagram._clock
    let sequence = operation(diagram)
    for index in 0..<inputs.count {
      _ = diagram.inputs[index]  // fault in all inputs
    }
    for (index, spec) in inputs.enumerated() {
      try diagram.inputs[index].parse(spec, theme: theme, location: location)
    }
    let test = RecordingTest(
      inputs: inputs.map { Specification(specification: $0, location: location) },
      sequence: sequence,
      output: Specification(specification: output, location: location),
      trace: ManagedCriticalState(Trace(events: [], demandTicks: [])),
      finished: ManagedCriticalState(false),
      persistent: persistentConsumer)

    let parsedOutput = try Event.parse(output, theme: theme, location: location)
    let cancelEvents = Set(
      parsedOutput.filter { _, event in
        if case .cancel = event { return true }
        return false
      }.map { when, _ in when })
    let activeTicks = parsedOutput.reduce(into: [Clock.Instant(when: .zero)]) { events, thisEvent in
      switch thisEvent {
      case (let when, .delayNext(_)):
        events.removeLast()
        events.append(when.advanced(by: .steps(1)))
      case (let when, _):
        events.append(when)
      }
    }
    // Unlike `test(theme:_:)`, a run continues until the consumer is done
    // (terminal event or demand exhausted), so operators that sleep past
    // the last input event (throttle's completion flush, debounce) are
    // observed; `slack` bounds a consumer that never returns.
    let times = parsedOutput.map { when, _ in when }
    let end = (times + diagram.inputs.compactMap { $0.end }).max() ?? Clock.Instant(when: .zero)
    let maxTicks = end.when.rawValue * 2 + slack

    Context.clock = clock
    Context.specificationFailures.removeAll()
    Context.driver = TaskDriver(queue: diagram.queue) { driver in
      swift_task_enqueueGlobal_hook = { job, original in
        Context.driver?.enqueue(job)
      }
      let runner = Task {
        try? await test.test(with: clock, activeTicks: activeTicks, output: test.output) { _ in }
      }
      diagram.queue.drain()
      var ticks = 0
      while !test.finished.withCriticalRegion({ $0 }) && ticks < maxTicks {
        if cancelEvents.contains(diagram.queue.now.advanced(by: .steps(1))) {
          runner.cancel()
        }
        diagram.queue.advance()
        ticks += 1
      }
      runner.cancel()
      Context.clock = nil
      swift_task_enqueueGlobal_hook = nil
    }
    Context.driver?.start()
    Context.driver?.join()
    Context.driver = nil
    var result = test.trace.withCriticalRegion { $0 }
    result.choicePoints = policy.choicePoints
    result.maxReadyWidth = policy.maxWidth
    result.scheduleLog = policy.log
    return result
  }
}
