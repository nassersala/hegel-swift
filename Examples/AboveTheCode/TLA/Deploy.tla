--------------------------- MODULE Deploy ---------------------------
(* Zero-downtime deployment: the relation of
   Sources/AboveTheCode/Deploy.swift, for TLC. N servers go from v1 to
   v2, offline while they upgrade; K must be online at every state; the
   balancer names which servers are online. Design picks the Start guard
   and the online set: "any" and "one" are the two designs refuted in
   Wlaschin's talk, without a balancer; "balanced" is the relation.

   Hegel checks the relation on drawn behaviours and the rollouts against
   it. TLC adds the whole state space, the deadlock at N < 2K, and the
   liveness a finite trace cannot state: under weak fairness of the
   upgrade steps, every server ends at v2. Stuttering is built in to
   [][Next]_vars; without WF the upgrade may idle forever, which is the
   lesson of the talk's counter. *)
EXTENDS Integers, FiniteSets

CONSTANTS N, K, Design
ASSUME Design \in {"any", "one", "balanced"}
Servers == 1..N

VARIABLES servers, lb
vars == <<servers, lb>>

TypeOK ==
  /\ servers \in [Servers -> {"v1", "off", "v2"}]
  /\ lb \in {"v1", "v2"}

Init ==
  /\ servers = [s \in Servers |-> "v1"]
  /\ lb = "v1"

Offline == {s \in Servers : servers[s] = "off"}
AtV2 == {s \in Servers : servers[s] = "v2"}

(* Without a balancer, online is "not offline". With one, it is the
   servers at the balancer's version. *)
Online ==
  IF Design = "balanced" THEN {s \in Servers : servers[s] = lb}
                         ELSE {s \in Servers : servers[s] # "off"}

MayStart(s) ==
  CASE Design = "any" -> TRUE
    [] Design = "one" -> Offline = {}
    [] Design = "balanced" -> Cardinality(Online \ {s}) >= K

Start(s) ==
  /\ servers[s] = "v1"
  /\ MayStart(s)
  /\ servers' = [servers EXCEPT ![s] = "off"]
  /\ UNCHANGED lb

Finish(s) ==
  /\ servers[s] = "off"
  /\ servers' = [servers EXCEPT ![s] = "v2"]
  /\ UNCHANGED lb

Switch ==
  /\ Design = "balanced"
  /\ lb = "v1"
  /\ Cardinality(AtV2) >= K
  /\ lb' = "v2"
  /\ UNCHANGED servers

Done ==
  /\ \A s \in Servers : servers[s] = "v2"
  /\ Design = "balanced" => lb = "v2"

Upgrade == (\E s \in Servers : Start(s) \/ Finish(s)) \/ Switch
Terminating == Done /\ UNCHANGED vars
Next == Upgrade \/ Terminating

Spec == Init /\ [][Next]_vars /\ WF_vars(Upgrade)

(* Safety. *)
ZeroDowntime == Cardinality(Online) >= K
SameVersion == \A s, t \in Online : servers[s] = servers[t]
(* The batch, as the relation states it: never more than N - K offline. *)
AtMostTheBatch == Cardinality(Offline) <= N - K

(* Liveness, under WF. *)
EventuallyDone == <>[]Done
=====================================================================
