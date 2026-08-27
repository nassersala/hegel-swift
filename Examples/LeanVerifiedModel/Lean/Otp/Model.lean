/-!
# A one-time-code login with an attempt counter

The abstract model of the login screen. `step` is total on enabled
stimuli; `enabled` says which stimuli make sense in a state. The theorems
below are what the Swift implementation inherits if it refines `step`.
-/

namespace Otp

inductive Screen where
  | phone | code | locked | home
  deriving DecidableEq, Repr

inductive Stim where
  | enterPhone | send | goodCode | badCode | resend | back
  deriving DecidableEq, Repr

inductive Resp where
  | none | showCodeField | showError | lockOut | signIn
  deriving DecidableEq, Repr

structure S where
  screen : Screen
  attempts : Nat
  deriving DecidableEq, Repr

def initial : S := ⟨.phone, 0⟩

/-- The lockout threshold: the third bad code locks. -/
def limit : Nat := 3

def enabled : S → Stim → Bool
  | ⟨.phone, _⟩, .enterPhone => true
  | ⟨.phone, _⟩, .send => true
  | ⟨.phone, _⟩, .back => true
  | ⟨.code, _⟩, .goodCode => true
  | ⟨.code, _⟩, .badCode => true
  | ⟨.code, _⟩, .resend => true
  | ⟨.code, _⟩, .back => true
  | ⟨.locked, _⟩, .back => true
  | _, _ => false

def step : S → Stim → S × Resp
  | ⟨.phone, _⟩, .send => (⟨.code, 0⟩, .showCodeField)
  | ⟨.phone, n⟩, .back => (⟨.phone, n⟩, .none)
  | ⟨.code, _⟩, .goodCode => (⟨.home, 0⟩, .signIn)
  | ⟨.code, n⟩, .badCode =>
      if n + 1 ≥ limit then (⟨.locked, n + 1⟩, .lockOut) else (⟨.code, n + 1⟩, .showError)
  | ⟨.code, n⟩, .resend => (⟨.code, n⟩, .showCodeField)   -- resend keeps the count
  | ⟨.code, _⟩, .back => (⟨.phone, 0⟩, .none)
  | ⟨.locked, _⟩, .back => (⟨.phone, 0⟩, .none)
  | s, _ => (s, .none)

/-- The reachable-state invariant: the counter never exceeds the limit,
and while a code is being entered it is strictly below it (the third bad
code leaves the code screen). Stated as `attempts ≤ limit` alone this is
not preserved; Lean rejected that version. -/
def Inv (s : S) : Prop := s.attempts ≤ limit ∧ (s.screen = .code → s.attempts < limit)

theorem inv_initial : Inv initial := by simp [Inv, initial, limit]

theorem inv_preserved (s : S) (x : Stim) (h : Inv s) : Inv (step s x).1 := by
  rcases s with ⟨sc, n⟩
  simp only [Inv, limit] at *
  cases sc <;> cases x <;> simp only [step] <;> (try split) <;> simp_all [limit] <;> omega

/-- Resend never touches the counter (the planted Swift bug violates this). -/
theorem resend_keeps_attempts (s : S) : (step s .resend).1.attempts = s.attempts := by
  rcases s with ⟨sc, n⟩
  cases sc <;> simp [step]

/-- Lockout happens exactly on the third bad code. -/
theorem lockout_iff (s : S) :
    (step s .badCode).2 = .lockOut ↔ s.screen = .code ∧ s.attempts + 1 ≥ limit := by
  rcases s with ⟨sc, n⟩
  cases sc <;> simp [step, limit] <;> split <;> simp_all

/-- A bad code on the code screen advances the counter by exactly one. -/
theorem badCode_increments (n : Nat) :
    (step ⟨.code, n⟩ .badCode).1.attempts = n + 1 := by
  simp [step]; split <;> rfl

end Otp
