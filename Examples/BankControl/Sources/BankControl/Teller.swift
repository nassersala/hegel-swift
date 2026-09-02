/// A teller app. It names each request once and resends the same request
/// until a reply arrives, so the network's drops are covered by retries and
/// its duplicates are harmless. A reply for a request it is not waiting on
/// is ignored.
public struct Teller: Sendable {
    public enum Status: Hashable, Sendable {
        case pending(attempts: Int)
        case completed(Outcome)
        case abandoned(attempts: Int)
    }

    public struct Pending: Hashable, Sendable {
        public let request: Request
        public var lastSentAt: Int
        public var attempts: Int
    }

    public enum Event: Hashable, Sendable {
        case submitted(RequestID, Operation)
        case sent(RequestID, attempt: Int)
        case completed(RequestID, Outcome)
        case abandoned(RequestID, attempts: Int)
        case ignoredReply(RequestID)
    }

    public let id: TellerID
    /// Resend a request this many ticks after its last send without a reply.
    public let timeout: Int
    /// Give up after this many sends; nil means keep trying.
    public let maxAttempts: Int?

    public private(set) var nextSequence = 0
    public private(set) var pending: [RequestID: Pending] = [:]
    public private(set) var status: [RequestID: Status] = [:]
    public private(set) var events: [Event] = []

    public init(id: TellerID, timeout: Int = 4, maxAttempts: Int? = nil) {
        precondition(timeout >= 1)
        self.id = id
        self.timeout = timeout
        self.maxAttempts = maxAttempts
    }

    /// Queue an operation. It is sent on the next `tick`.
    @discardableResult
    public mutating func submit(_ operation: Operation) -> RequestID {
        let id = RequestID(teller: self.id, sequence: nextSequence)
        nextSequence += 1
        let request = Request(id: id, operation: operation)
        pending[id] = Pending(request: request, lastSentAt: Int.min, attempts: 0)
        status[id] = .pending(attempts: 0)
        events.append(.submitted(id, operation))
        return id
    }

    /// Everything to send at `now`: first sends and retries of pending
    /// requests whose timeout has passed.
    public mutating func tick(now: Int) -> [Request] {
        var out: [Request] = []
        for id in pending.keys.sorted() {
            guard var p = pending[id] else { continue }
            let due = p.attempts == 0 || now - p.lastSentAt >= timeout
            guard due else { continue }
            if let max = maxAttempts, p.attempts >= max {
                pending[id] = nil
                status[id] = .abandoned(attempts: p.attempts)
                events.append(.abandoned(id, attempts: p.attempts))
                continue
            }
            p.attempts += 1
            p.lastSentAt = now
            pending[id] = p
            status[id] = .pending(attempts: p.attempts)
            events.append(.sent(id, attempt: p.attempts))
            out.append(p.request)
        }
        return out
    }

    public mutating func receive(_ reply: Reply) {
        guard pending[reply.id] != nil else {
            events.append(.ignoredReply(reply.id))
            return
        }
        pending[reply.id] = nil
        status[reply.id] = .completed(reply.outcome)
        events.append(.completed(reply.id, reply.outcome))
    }

    public var isIdle: Bool { pending.isEmpty }

    public var completed: [RequestID: Outcome] {
        var out: [RequestID: Outcome] = [:]
        for (id, s) in status {
            if case .completed(let o) = s { out[id] = o }
        }
        return out
    }
}
