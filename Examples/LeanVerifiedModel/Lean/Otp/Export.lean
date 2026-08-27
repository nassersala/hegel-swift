import Otp.Model

/-!
# The C boundary

Scalars only, so the ABI carries no Lean objects: screens, stimuli and
responses are `UInt8` tags, the counter is `UInt32`. The encoders are
proved to round-trip, so what Swift calls is `step` up to encoding.
-/

namespace Otp

def Screen.tag : Screen → UInt8
  | .phone => 0 | .code => 1 | .locked => 2 | .home => 3

def Screen.ofTag : UInt8 → Option Screen
  | 0 => some .phone | 1 => some .code | 2 => some .locked | 3 => some .home | _ => none

def Stim.ofTag : UInt8 → Option Stim
  | 0 => some .enterPhone | 1 => some .send | 2 => some .goodCode
  | 3 => some .badCode | 4 => some .resend | 5 => some .back | _ => none

def Resp.tag : Resp → UInt8
  | .none => 0 | .showCodeField => 1 | .showError => 2 | .lockOut => 3 | .signIn => 4

theorem Screen.ofTag_tag (s : Screen) : Screen.ofTag s.tag = some s := by
  cases s <;> rfl

/-- `otp_enabled(screen, attempts, stim)`: 1 if the stimulus is enabled,
0 otherwise (also 0 for an unknown tag). -/
@[export otp_enabled]
def enabledC (screen : UInt8) (attempts : UInt32) (stim : UInt8) : UInt8 :=
  match Screen.ofTag screen, Stim.ofTag stim with
  | some sc, some x => if enabled ⟨sc, attempts.toNat⟩ x then 1 else 0
  | _, _ => 0

/-- `otp_step(screen, attempts, stim)`: packed result
`response | nextScreen << 8 | nextAttempts << 16`. An unknown tag returns
the input state with response 0. -/
@[export otp_step]
def stepC (screen : UInt8) (attempts : UInt32) (stim : UInt8) : UInt64 :=
  match Screen.ofTag screen, Stim.ofTag stim with
  | some sc, some x =>
      let (s', r) := step ⟨sc, attempts.toNat⟩ x
      r.tag.toUInt64 ||| (s'.screen.tag.toUInt64 <<< 8) ||| (s'.attempts.toUInt64 <<< 16)
  | _, _ => screen.toUInt64 <<< 8 ||| attempts.toUInt64 <<< 16

/-- `otp_initial()`: the initial state, packed as above with response 0. -/
@[export otp_initial]
def initialC (_ : Unit) : UInt64 :=
  initial.screen.tag.toUInt64 <<< 8 ||| initial.attempts.toUInt64 <<< 16

end Otp
