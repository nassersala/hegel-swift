---------------------------- MODULE Bank ----------------------------
(* Two concurrent withdrawals of the whole balance, as the labelled
   transition system of Examples/LeanVerifiedModel/Lean/Bank/Model.lean:
   tasks a and b, phases idle / checked / done, events checkPass,
   checkFail, commit. Unsafe: check and commit are separate events, so
   the other task may run between them. Safe: checkPass is the commit.
   Which enabled event fires next is TLC's to choose; in Swift the
   schedule chooses. *)
EXTENDS Integers, Sequences

CONSTANTS Amount, Initial, Safe
Tasks == {"a", "b"}

VARIABLES balance, phase, event
vars == <<balance, phase, event>>

Init ==
  /\ balance = Initial
  /\ phase = [t \in Tasks |-> "idle"]
  /\ event = "start"

CheckPass(t) ==
  /\ phase[t] = "idle" /\ balance >= Amount
  /\ IF Safe
       THEN /\ balance' = balance - Amount
            /\ phase' = [phase EXCEPT ![t] = "done"]
       ELSE /\ UNCHANGED balance
            /\ phase' = [phase EXCEPT ![t] = "checked"]
  /\ event' = "checkPass " \o t

CheckFail(t) ==
  /\ phase[t] = "idle" /\ balance < Amount
  /\ phase' = [phase EXCEPT ![t] = "done"]
  /\ UNCHANGED balance
  /\ event' = "checkFail " \o t

Commit(t) ==
  /\ phase[t] = "checked"
  /\ balance' = balance - Amount
  /\ phase' = [phase EXCEPT ![t] = "done"]
  /\ event' = "commit " \o t

AllDone == \A t \in Tasks : phase[t] = "done"

(* Stutter once finished, so TLC's deadlock check means a real deadlock. *)
Terminating == AllDone /\ UNCHANGED vars

Next == \/ \E t \in Tasks : CheckPass(t) \/ CheckFail(t) \/ Commit(t)
        \/ Terminating

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

(* Safety. The two formulas of ScheduleTests.swift:
   G(checkmark commit => balance >= 0) and, for the mechanism,
   "no second check between a check and its commit", which as a state
   predicate is "never two tasks checked at once". *)
Solvent == balance >= 0
NoDoubleCheck == ~(\E t1, t2 \in Tasks : t1 # t2 /\ phase[t1] = "checked" /\ phase[t2] = "checked")

(* Liveness, provable here and only a bounded surrogate in Swift:
   under weak fairness both withdrawals finish. *)
Termination == <>[]AllDone
=====================================================================
