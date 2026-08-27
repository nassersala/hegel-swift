-------------------------- MODULE Quicksort --------------------------
(* Lamport's quicksort, "Thinking Above the Code" (2014): the algorithm
   as a next-state relation over the array A and the set U of index
   ranges still to partition. Recursion is one refinement of it. *)
EXTENDS Integers, FiniteSets

CONSTANTS N, Values
Index == 1..N

(* Permutations of B[lo..hi] with everything in lo..p at most everything
   in (p+1)..hi; the rest of B unchanged. *)
Partitions(B, p, lo, hi) ==
  { C \in [Index -> Values] :
      /\ \A i \in Index \ (lo..hi) : C[i] = B[i]
      /\ \A v \in Values :
           Cardinality({i \in lo..hi : B[i] = v}) = Cardinality({i \in lo..hi : C[i] = v})
      /\ \A i \in lo..p, j \in (p+1)..hi : C[i] <= C[j] }

VARIABLES A, A0, U
vars == <<A, A0, U>>

Init == /\ A \in [Index -> Values]
        /\ A0 = A
        /\ U = {<<1, N>>}

Next ==
  /\ U /= {}
  /\ \E r \in U :
       LET b == r[1]  t == r[2] IN
       IF b /= t
         THEN \E p \in b..(t-1) :
                /\ A' \in Partitions(A, p, b, t)
                /\ U' = (U \ {r}) \cup {<<b, p>>, <<p+1, t>>}
         ELSE /\ A' = A
              /\ U' = U \ {r}
  /\ UNCHANGED A0

Terminating == U = {} /\ UNCHANGED vars
Spec == Init /\ [][Next \/ Terminating]_vars /\ WF_vars(Next)

Sorted == \A i, j \in Index : i < j => A[i] <= A[j]
Permutation == \A v \in Values :
  Cardinality({i \in Index : A[i] = v}) = Cardinality({i \in Index : A0[i] = v})

(* Partial correctness: when U is empty, A is a sorted permutation of A0. *)
Correct == U = {} => Sorted /\ Permutation
Termination == <>[](U = {})
=======================================================================
