---------------------------- MODULE Auth ----------------------------
(* Token refresh with rotation: the relation of
   Sources/AboveTheCode/Auth.swift, for TLC. Credentials are named by
   generation, pair g being access token g and refresh token g, so
   "fresh" is g + 1. N bounds the requests the app sends and G the
   refreshes the server grants; that is what makes the state space
   finite. Bounded is the clause the Swift relation gained from its own
   report: a 401 on the token the last refresh returned, with no success
   in between, signs out instead of refreshing again.

   Hegel checks the relation on drawn behaviours and the Swift session
   against it. TLC adds what a finite trace cannot: exhaustiveness for
   N = 3, G = 2, and the liveness that every request the app issues is
   eventually answered, under weak fairness of the environment. *)
EXTENDS Integers

CONSTANTS N, G, Bounded
Ids == 0..N-1
Out == -1        \* creds: signed out
None == -1       \* refreshing: no refresh in flight
Absent == -2     \* reqs[i]: not in flight
Waiting == -1    \* reqs[i]: held back until the refresh completes

VARIABLES creds, reqs, refreshing, rejected, done, n, unproven
vars == <<creds, reqs, refreshing, rejected, done, n, unproven>>

TypeOK ==
  /\ creds \in -1..G
  /\ reqs \in [Ids -> -2..G]
  /\ refreshing \in -1..G
  /\ rejected \subseteq 0..G
  /\ done \in [Ids -> {"none", "ok", "failed"}]
  /\ n \in 0..N
  /\ unproven \in BOOLEAN

Init ==
  /\ creds = 0
  /\ reqs = [i \in Ids |-> Absent]
  /\ refreshing = None
  /\ rejected = {}
  /\ done = [i \in Ids |-> "none"]
  /\ n = 0
  /\ unproven = FALSE

Sent(i) == reqs[i] >= 0
Issued(i) == i < n

(* The app sends request n. Signed out: it fails at once. A refresh in
   flight: it waits, since the token in hand is known bad. *)
Send ==
  /\ n < N
  /\ n' = n + 1
  /\ IF creds = Out
       THEN /\ done' = [done EXCEPT ![n] = "failed"]
            /\ UNCHANGED reqs
       ELSE /\ reqs' = [reqs EXCEPT ![n] = IF refreshing = None THEN creds ELSE Waiting]
            /\ UNCHANGED done
  /\ UNCHANGED <<creds, refreshing, rejected, unproven>>

(* A 200. An ok under the current token is the proof the bound waits for. *)
Ok(i) ==
  /\ Sent(i)
  /\ reqs' = [reqs EXCEPT ![i] = Absent]
  /\ done' = [done EXCEPT ![i] = "ok"]
  /\ unproven' = IF reqs[i] = creds THEN FALSE ELSE unproven
  /\ UNCHANGED <<creds, refreshing, rejected, n>>

(* A 401, answered by which token the request went out under. *)
Unauthorized(i) ==
  /\ Sent(i)
  /\ rejected' = rejected \cup {reqs[i]}
  /\ UNCHANGED n
  /\ IF creds = Out THEN
       /\ reqs' = [reqs EXCEPT ![i] = Absent]
       /\ done' = [done EXCEPT ![i] = "failed"]
       /\ UNCHANGED <<creds, refreshing, unproven>>
     ELSE IF refreshing # None THEN
       /\ reqs' = [reqs EXCEPT ![i] = Waiting]
       /\ UNCHANGED <<creds, refreshing, done, unproven>>
     ELSE IF reqs[i] # creds THEN            \* stale: the session moved on, resend
       /\ reqs' = [reqs EXCEPT ![i] = creds]
       /\ UNCHANGED <<creds, refreshing, done, unproven>>
     ELSE IF unproven /\ Bounded THEN        \* the bound: this token came from the last refresh
       /\ creds' = Out
       /\ reqs' = [reqs EXCEPT ![i] = Absent]
       /\ done' = [done EXCEPT ![i] = "failed"]
       /\ UNCHANGED <<refreshing, unproven>>
     ELSE                                    \* first news the token is bad: one refresh
       /\ reqs' = [reqs EXCEPT ![i] = Waiting]
       /\ refreshing' = creds
       /\ UNCHANGED <<creds, done, unproven>>

(* The refresh returns the next pair; the queue is resent under it. *)
Refreshed ==
  /\ refreshing # None
  /\ creds < G
  /\ creds' = creds + 1
  /\ refreshing' = None
  /\ unproven' = TRUE
  /\ reqs' = [i \in Ids |-> IF reqs[i] = Waiting THEN creds + 1 ELSE reqs[i]]
  /\ UNCHANGED <<rejected, done, n>>

(* The refresh is rejected: signed out, the queue fails. *)
RefreshFailed ==
  /\ refreshing # None
  /\ creds' = Out
  /\ refreshing' = None
  /\ reqs' = [i \in Ids |-> IF reqs[i] = Waiting THEN Absent ELSE reqs[i]]
  /\ done' = [i \in Ids |-> IF reqs[i] = Waiting THEN "failed" ELSE done[i]]
  /\ UNCHANGED <<rejected, n, unproven>>

Settled == n = N /\ \A i \in Ids : done[i] # "none"

(* Stutter once finished, so TLC's deadlock check means a real deadlock. *)
Terminating == Settled /\ UNCHANGED vars

(* The environment: the server's answers. The app's sends are not fair;
   it may stop sending. *)
Env == \/ \E i \in Ids : Ok(i) \/ Unauthorized(i)
       \/ Refreshed
       \/ RefreshFailed

Next == Send \/ Env \/ Terminating

Spec == Init /\ [][Next]_vars /\ WF_vars(Env)

(* Inv, as in Auth.swift: refreshing exactly when the token held has been
   rejected, the token traded is the current one, nobody waits for a
   refresh that is not happening. It holds with and without the bound,
   because an invariant sees one state and the loop is a property of the
   trace. *)
Inv ==
  /\ (refreshing # None) <=> (creds # Out /\ creds \in rejected)
  /\ (refreshing # None) => (refreshing = creds)
  /\ (\E i \in Ids : reqs[i] = Waiting) => (refreshing # None)

(* The bound as a trace property. Auth.swift's formula is
   always(refreshStarts => weakNext(weakUntil(!refreshStarts, proof)));
   between a start and its completion no second start is possible, so
   "no start while the last refresh's token is unproven" is the same
   property, and unproven is its history variable. Violated when Bounded
   is FALSE: the loop, caught at its second turn. *)
RefreshStarts == refreshing = None /\ refreshing' # None
NoRefreshWithoutProof == [][RefreshStarts => ~unproven]_vars

(* Liveness, checkable here and not on a finite trace: every request the
   app issues is eventually answered, ok or failed. *)
EverySettled == \A i \in Ids : [](Issued(i) => <>(done[i] # "none"))
=====================================================================
