------------------------------ MODULE TwoPhase ------------------------------
(* Two-phase commit as in Lamport's TwoPhase.tla (the TLA+ video course),
   with the network as a set of messages that may be delivered in any
   order and never lost, plus one more thing Examples/TwoPhaseCommit
   exercises: the coordinator may crash after collecting every vote and
   before deciding (Crash = TRUE). Participants that voted yes then wait
   forever: consistency holds, termination does not. Swift's faults
   (drops, duplicates) and its timeout-abort are not modelled here; TLC
   checks the protocol, hegel checks the code. *)
EXTENDS Integers

CONSTANTS RM, Crash

VARIABLES rmState, tmState, tmPrepared, msgs
vars == <<rmState, tmState, tmPrepared, msgs>>

Message == [type : {"Prepared"}, rm : RM] \cup [type : {"Commit", "Abort"}]

TypeOK ==
  /\ rmState \in [RM -> {"working", "prepared", "committed", "aborted"}]
  /\ tmState \in {"init", "committed", "aborted", "crashed"}
  /\ tmPrepared \subseteq RM
  /\ msgs \subseteq Message

Init ==
  /\ rmState = [r \in RM |-> "working"]
  /\ tmState = "init"
  /\ tmPrepared = {}
  /\ msgs = {}

TMRcvPrepared(r) ==
  /\ tmState = "init"
  /\ [type |-> "Prepared", rm |-> r] \in msgs
  /\ tmPrepared' = tmPrepared \cup {r}
  /\ UNCHANGED <<rmState, tmState, msgs>>

TMCommit ==
  /\ tmState = "init"
  /\ tmPrepared = RM
  /\ tmState' = "committed"
  /\ msgs' = msgs \cup {[type |-> "Commit"]}
  /\ UNCHANGED <<rmState, tmPrepared>>

TMAbort ==
  /\ tmState = "init"
  /\ tmState' = "aborted"
  /\ msgs' = msgs \cup {[type |-> "Abort"]}
  /\ UNCHANGED <<rmState, tmPrepared>>

TMCrash ==
  /\ Crash
  /\ tmState = "init"
  /\ tmPrepared = RM
  /\ tmState' = "crashed"
  /\ UNCHANGED <<rmState, tmPrepared, msgs>>

RMPrepare(r) ==
  /\ rmState[r] = "working"
  /\ rmState' = [rmState EXCEPT ![r] = "prepared"]
  /\ msgs' = msgs \cup {[type |-> "Prepared", rm |-> r]}
  /\ UNCHANGED <<tmState, tmPrepared>>

RMChooseToAbort(r) ==
  /\ rmState[r] = "working"
  /\ rmState' = [rmState EXCEPT ![r] = "aborted"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

RMRcvCommitMsg(r) ==
  /\ [type |-> "Commit"] \in msgs
  /\ rmState' = [rmState EXCEPT ![r] = "committed"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

RMRcvAbortMsg(r) ==
  /\ [type |-> "Abort"] \in msgs
  /\ rmState' = [rmState EXCEPT ![r] = "aborted"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

Done == \A r \in RM : rmState[r] \in {"committed", "aborted"}
Terminating == Done /\ UNCHANGED vars

Next ==
  \/ TMCommit \/ TMAbort \/ TMCrash
  \/ \E r \in RM :
       TMRcvPrepared(r) \/ RMPrepare(r) \/ RMChooseToAbort(r)
       \/ RMRcvCommitMsg(r) \/ RMRcvAbortMsg(r)
  \/ Terminating

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

(* Lamport's TCConsistent: no two participants decide differently. *)
Consistent ==
  \A r1, r2 \in RM : ~ /\ rmState[r1] = "aborted"
                       /\ rmState[r2] = "committed"

(* Every participant decides. Holds without the crash; with it, TLC's
   counterexample is the blocked state. *)
Termination == <>Done
=============================================================================
