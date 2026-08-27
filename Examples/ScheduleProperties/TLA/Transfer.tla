-------------------------- MODULE Transfer --------------------------
(* The transfer fixture of Independence.swift: a withdrawal (w) and a
   transfer (t) racing on account A, the transfer's credit landing on
   B, an unrelated withdrawal (z) on C. Unsafe throughout: every task
   checks, may be interleaved, then commits. Events are named as the
   Swift trace names them, "<account> <event> <balance after>". *)
EXTENDS Integers, Sequences, TLC

Accounts == {"A", "B", "C"}
Tasks == {"w", "t", "z"}

VARIABLES balance, phase, event
vars == <<balance, phase, event>>

Init ==
  /\ balance = [x \in Accounts |-> 100]
  /\ phase = [k \in Tasks |-> "idle"]
  /\ event = "start"

Source(k) == IF k = "z" THEN "C" ELSE "A"
Amount(k) == IF k = "z" THEN 10 ELSE 100

Check(k) ==
  /\ phase[k] = "idle" /\ balance[Source(k)] >= Amount(k)
  /\ phase' = [phase EXCEPT ![k] = "checked"]
  /\ UNCHANGED balance
  /\ event' = Source(k) \o " check " \o ToString(balance[Source(k)])

Fail(k) ==
  /\ phase[k] = "idle" /\ balance[Source(k)] < Amount(k)
  /\ phase' = [phase EXCEPT ![k] = "done"]
  /\ UNCHANGED balance
  /\ event' = Source(k) \o " fail"

Commit(k) ==
  /\ phase[k] = "checked"
  /\ balance' = [balance EXCEPT ![Source(k)] = @ - Amount(k)]
  /\ phase' = [phase EXCEPT ![k] = IF k = "t" THEN "committed" ELSE "done"]
  /\ event' = Source(k) \o " commit " \o ToString(balance'[Source(k)])

Credit ==
  /\ phase["t"] = "committed"
  /\ balance' = [balance EXCEPT !["B"] = @ + 100]
  /\ phase' = [phase EXCEPT !["t"] = "done"]
  /\ event' = "B credit " \o ToString(balance'["B"])

AllDone == \A k \in Tasks : phase[k] = "done"
Terminating == AllDone /\ UNCHANGED vars

Next == \/ \E k \in Tasks : Check(k) \/ Fail(k) \/ Commit(k)
        \/ Credit
        \/ Terminating

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

Solvent == \A x \in Accounts : balance[x] >= 0
(* No second check on an account between a check and its commit. *)
NoDoubleCheck == ~(phase["w"] = "checked" /\ phase["t"] = "checked")
Termination == <>[]AllDone
=====================================================================
