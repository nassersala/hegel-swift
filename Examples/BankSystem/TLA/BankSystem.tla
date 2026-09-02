------------------------- MODULE BankSystem -------------------------
(* The composed relation of Examples/BankSystem/Sources/System, Phase A
   section 4 Init_S / Next_S with the decisions substituted: P1a ids are
   teller x seq, P2a a copy gets the stored reply, P3a seen never shrinks,
   P4b Timeout bounded by K and GiveUp to unknown, P5a one outstanding
   request per teller, P6a a refusal carries the balance. Two tellers, one
   account, requests drawn from Amounts, MaxN requests per teller, Dup and
   Drop bounded by counters so TLC terminates. `applied` is the history
   variable pi, the Apply steps in order, which Once and Serial read.

   Hegel checks the same relation on drawn behaviours and the composed
   code against it. TLC adds exhaustiveness for these constants, and the
   liveness the finite checks cannot see. *)
EXTENDS Integers, Sequences, Bags, FiniteSets

CONSTANTS Tellers, B0, MaxN, K, Amounts, DupMax, DropMax

Req == [kind : {"dep", "wd"}, n : Amounts]
Rep == [kind : {"ok", "refused"}, bal : Nat]
NoReq == [kind |-> "none", n |-> 0]
NoRep == [kind |-> "none", bal |-> 0]
Unknown == [kind |-> "unknown", bal |-> 0]
Ids == Tellers \X (1..MaxN)

VARIABLES bal, seen, tl, net, applied, reqOf, dups, drops
vars == <<bal, seen, tl, net, applied, reqOf, dups, drops>>

Meaning(r, b) ==
  IF r.kind = "dep" THEN [bal |-> b + r.n, rep |-> [kind |-> "ok", bal |-> b + r.n]]
  ELSE IF r.n <= b THEN [bal |-> b - r.n, rep |-> [kind |-> "ok", bal |-> b - r.n]]
  ELSE [bal |-> b, rep |-> [kind |-> "refused", bal |-> b]]

Request(t, n, r) == [kind |-> "q", t |-> t, n |-> n, req |-> r]
Reply(t, n, rep) == [kind |-> "r", t |-> t, n |-> n, rep |-> rep]

TypeOK ==
  /\ bal \in Nat
  /\ seen \in [Ids -> Rep \cup {NoRep}]
  /\ tl \in [Tellers -> [pend : Req \cup {NoReq}, seq : 0..MaxN, tries : 0..K, out : Rep \cup {NoRep, Unknown}]]
  /\ IsABag(net)
  /\ applied \in Seq(Ids)
  /\ reqOf \in [Ids -> Req \cup {NoReq}]
  /\ dups \in 0..DupMax
  /\ drops \in 0..DropMax

Init ==
  /\ bal = B0
  /\ seen = [i \in Ids |-> NoRep]
  /\ tl = [t \in Tellers |-> [pend |-> NoReq, seq |-> 0, tries |-> 0, out |-> NoRep]]
  /\ net = EmptyBag
  /\ applied = <<>>
  /\ reqOf = [i \in Ids |-> NoReq]
  /\ dups = 0
  /\ drops = 0

Put(m) == net (+) SetToBag({m})
Take(m) == net (-) SetToBag({m})
InNet(m) == BagIn(m, net)

(* Next_T, teller t. *)
Submit(t, r) ==
  /\ tl[t].pend = NoReq
  /\ tl[t].seq < MaxN
  /\ tl' = [tl EXCEPT ![t] = [pend |-> r, seq |-> @.seq + 1, tries |-> 1, out |-> NoRep]]
  /\ net' = Put(Request(t, tl[t].seq + 1, r))
  /\ reqOf' = [reqOf EXCEPT ![<<t, tl[t].seq + 1>>] = r]
  /\ UNCHANGED <<bal, seen, applied, dups, drops>>

Timeout(t) ==
  /\ tl[t].pend # NoReq
  /\ tl[t].tries < K
  /\ tl' = [tl EXCEPT ![t].tries = @ + 1]
  /\ net' = Put(Request(t, tl[t].seq, tl[t].pend))
  /\ UNCHANGED <<bal, seen, applied, reqOf, dups, drops>>

GiveUp(t) ==
  /\ tl[t].pend # NoReq
  /\ tl[t].tries = K
  /\ tl' = [tl EXCEPT ![t] = [pend |-> NoReq, seq |-> @.seq, tries |-> 0, out |-> Unknown]]
  /\ UNCHANGED <<bal, seen, net, applied, reqOf, dups, drops>>

(* Next_L on the arrival of a request, and the reply onto the wire. *)
Arrive(m) ==
  /\ m.kind = "q"
  /\ InNet(m)
  /\ IF seen[<<m.t, m.n>>] = NoRep
       THEN LET x == Meaning(m.req, bal) IN         \* Apply
            /\ bal' = x.bal
            /\ seen' = [seen EXCEPT ![<<m.t, m.n>>] = x.rep]
            /\ applied' = Append(applied, <<m.t, m.n>>)
            /\ net' = Put(Reply(m.t, m.n, x.rep)) (-) SetToBag({m})
       ELSE                                          \* Again: the stored reply
            /\ net' = Put(Reply(m.t, m.n, seen[<<m.t, m.n>>])) (-) SetToBag({m})
            /\ UNCHANGED <<bal, seen, applied>>
  /\ UNCHANGED <<tl, reqOf, dups, drops>>

(* Take or Ignore at teller m.t. *)
Deliver(m) ==
  /\ m.kind = "r"
  /\ InNet(m)
  /\ net' = Take(m)
  /\ IF tl[m.t].pend # NoReq /\ m.n = tl[m.t].seq
       THEN tl' = [tl EXCEPT ![m.t] = [pend |-> NoReq, seq |-> @.seq, tries |-> 0, out |-> m.rep]]
       ELSE UNCHANGED tl
  /\ UNCHANGED <<bal, seen, applied, reqOf, dups, drops>>

Dup(m) ==
  /\ InNet(m)
  /\ dups < DupMax
  /\ dups' = dups + 1
  /\ net' = Put(m)
  /\ UNCHANGED <<bal, seen, tl, applied, reqOf, drops>>

Drop(m) ==
  /\ InNet(m)
  /\ drops < DropMax
  /\ drops' = drops + 1
  /\ net' = Take(m)
  /\ UNCHANGED <<bal, seen, tl, applied, reqOf, dups>>

Settled == BagCardinality(net) = 0 /\ \A t \in Tellers : tl[t].pend = NoReq /\ tl[t].seq = MaxN
Terminating == Settled /\ UNCHANGED vars

TellerStep == \E t \in Tellers : Timeout(t) \/ GiveUp(t)
NetStep == \E m \in BagToSet(net) : Arrive(m) \/ Deliver(m)
Fault == \E m \in BagToSet(net) : Dup(m) \/ Drop(m)

Next ==
  \/ \E t \in Tellers, r \in Req : Submit(t, r)
  \/ TellerStep
  \/ NetStep
  \/ Fault
  \/ Terminating

(* Fairness. The tellers' own timers are fair (a timer fires). Whether the
   network must be fair is the question the configs ask: FairNet adds weak
   fairness of Arrive and Deliver. Submits are never fair: a teller may
   stop. *)
Spec == Init /\ [][Next]_vars /\ WF_vars(TellerStep)
FairSpec == Init /\ [][Next]_vars /\ WF_vars(TellerStep) /\ WF_vars(NetStep)

(* The four invariants of Phase A section 4. *)
NonNegative == bal >= 0

Distinct(s) == \A i, j \in 1..Len(s) : i # j => s[i] # s[j]
Once == /\ Distinct(applied)
        /\ {applied[i] : i \in 1..Len(applied)} = {i \in Ids : seen[i] # NoRep}

(* reqOf is the second history variable: the request under each id, set
   at Submit; the relation itself does not store it (P5a makes it the
   teller's pend at the time), Serial needs it. *)
RECURSIVE Fold(_, _)
Fold(s, b) == IF s = <<>> THEN b ELSE Fold(Tail(s), Meaning(reqOf[Head(s)], b).bal)
Serial == Fold(applied, B0) = bal

Agree == \A t \in Tellers :
  (tl[t].out \in Rep) => (tl[t].pend = NoReq /\ seen[<<t, tl[t].seq>>] = tl[t].out)

(* Liveness. Submitted(t, n): teller t has issued request n. Done(t, n):
   it has been taken or given up. Applied(t, n): the ledger applied it.
   Learned(t, n): the teller shows its reply, or unknown. *)
Submitted(t, n) == tl[t].seq >= n
Done(t, n) == tl[t].seq > n \/ (tl[t].seq = n /\ tl[t].pend = NoReq)
Applied(t, n) == seen[<<t, n>>] # NoRep
LearnedReply(t, n) == tl[t].seq = n /\ tl[t].pend = NoReq /\ tl[t].out = seen[<<t, n>>]

EverySubmittedSettles == \A t \in Tellers, n \in 1..MaxN : [](Submitted(t, n) => <>Done(t, n))
EveryAppliedIsLearnedOrUnknown == \A t \in Tellers, n \in 1..MaxN : [](Applied(t, n) => <>Done(t, n))
(* The stronger reading the seam list asked about: an applied request's
   teller eventually shows the reply itself, not unknown. *)
EveryAppliedIsLearned == \A t \in Tellers, n \in 1..MaxN : [](Applied(t, n) => <>LearnedReply(t, n))
=====================================================================
