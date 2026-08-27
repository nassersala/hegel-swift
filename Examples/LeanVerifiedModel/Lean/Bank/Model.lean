/-!
# Two concurrent withdrawals: a labelled transition system

The account race from `Examples/ScheduleProperties`, as a relation: which
enabled event fires next is not decided here (the schedule decides it in
Swift). `step` is total on enabled events. Two variants of the same
relation: `unsafe` (check, suspend, commit) and `safe` (check and commit
atomically).
-/

namespace Bank

inductive Task where
  | a | b
  deriving DecidableEq, Repr

inductive Phase where
  | idle | checked | done
  deriving DecidableEq, Repr

inductive Event where
  | checkPass (t : Task)
  | checkFail (t : Task)
  | commit (t : Task)
  deriving DecidableEq, Repr

structure S where
  balance : Int
  a : Phase
  b : Phase
  deriving DecidableEq, Repr

def amount : Int := 100

def initial : S := ⟨100, .idle, .idle⟩

def S.phase (s : S) : Task → Phase
  | .a => s.a
  | .b => s.b

def S.setPhase (s : S) : Task → Phase → S
  | .a, p => { s with a := p }
  | .b, p => { s with b := p }

/-- Unsafe: the check and the commit are separate events; another task may
run between them. -/
def enabledUnsafe (s : S) : Event → Bool
  | .checkPass t => s.phase t = .idle && s.balance ≥ amount
  | .checkFail t => s.phase t = .idle && s.balance < amount
  | .commit t    => s.phase t = .checked

def stepUnsafe (s : S) : Event → S
  | .checkPass t => s.setPhase t .checked
  | .checkFail t => s.setPhase t .done
  | .commit t    => { s.setPhase t .done with balance := s.balance - amount }

/-- Safe: `checkPass` is the commit. `commit` is never enabled. -/
def enabledSafe (s : S) : Event → Bool
  | .checkPass t => s.phase t = .idle && s.balance ≥ amount
  | .checkFail t => s.phase t = .idle && s.balance < amount
  | .commit _    => false

def stepSafe (s : S) : Event → S
  | .checkPass t => { s.setPhase t .done with balance := s.balance - amount }
  | .checkFail t => s.setPhase t .done
  | .commit _    => s

/-- A finite path: every event enabled where it fires. -/
def Path (enabled : S → Event → Bool) (step : S → Event → S) : S → List Event → S → Prop
  | s, [], s' => s = s'
  | s, e :: es, s' => enabled s e = true ∧ Path enabled step (step s e) es s'

/-- Reachable-state invariant for the safe relation. -/
def Inv (s : S) : Prop := s.balance ≥ 0

theorem inv_initial : Inv initial := by simp [Inv, initial]

theorem safe_preserves_inv (s : S) (e : Event) (h : Inv s) (he : enabledSafe s e = true) :
    Inv (stepSafe s e) := by
  rcases s with ⟨bal, pa, pb⟩
  cases e with
  | checkPass t => cases t <;> simp_all [Inv, enabledSafe, stepSafe, S.setPhase, S.phase, amount] <;> omega
  | checkFail t => cases t <;> simp_all [Inv, enabledSafe, stepSafe, S.setPhase, S.phase]
  | commit t => simp_all [enabledSafe]

theorem safe_path_inv (es : List Event) :
    ∀ s s', Inv s → Path enabledSafe stepSafe s es s' → Inv s' := by
  induction es with
  | nil => intro s s' hs hp; unfold Path at hp; subst hp; exact hs
  | cons e es ih =>
    intro s s' hs hp
    unfold Path at hp
    exact ih _ _ (safe_preserves_inv s e hs hp.1) hp.2

/-- Every safe path from the initial state ends with a non-negative balance. -/
theorem safe_paths_nonneg (es : List Event) (s' : S)
    (h : Path enabledSafe stepSafe initial es s') : s'.balance ≥ 0 :=
  safe_path_inv es initial s' inv_initial h

/-- The unsafe relation admits the race: both checks pass before either
commit, and the balance reaches -100. An existence witness, not a theorem
about every schedule. -/
theorem unsafe_race :
    Path enabledUnsafe stepUnsafe initial
      [.checkPass .a, .checkPass .b, .commit .a, .commit .b]
      ⟨-100, .done, .done⟩ := by
  simp [Path, enabledUnsafe, stepUnsafe, initial, S.setPhase, S.phase, amount]

end Bank
