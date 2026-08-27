import Bank.Model

/-!
# The C boundary

State packed as `balance (Int32, sign-extended) | phaseA << 32 | phaseB << 40`;
events as `kind * 2 + task` (kind: 0 checkPass, 1 checkFail, 2 commit;
task: 0 a, 1 b). `variant`: 0 unsafe, 1 safe.
-/

namespace Bank

def Task.tag : Task → UInt8 | .a => 0 | .b => 1
def Task.ofTag : UInt8 → Option Task | 0 => some .a | 1 => some .b | _ => none
def Phase.tag : Phase → UInt8 | .idle => 0 | .checked => 1 | .done => 2
def Phase.ofTag : UInt8 → Option Phase
  | 0 => some .idle | 1 => some .checked | 2 => some .done | _ => none

def Event.ofTag (x : UInt8) : Option Event :=
  match x / 2, Task.ofTag (x % 2) with
  | 0, some t => some (.checkPass t)
  | 1, some t => some (.checkFail t)
  | 2, some t => some (.commit t)
  | _, _ => none

theorem Task.ofTag_tag (t : Task) : Task.ofTag t.tag = some t := by cases t <;> rfl
theorem Phase.ofTag_tag (p : Phase) : Phase.ofTag p.tag = some p := by cases p <;> rfl

def S.pack (s : S) : UInt64 :=
  (s.balance.toInt32.toUInt32.toUInt64) ||| (s.a.tag.toUInt64 <<< 32) ||| (s.b.tag.toUInt64 <<< 40)

def S.unpack (w : UInt64) : Option S :=
  match Phase.ofTag (w >>> 32).toUInt8, Phase.ofTag (w >>> 40).toUInt8 with
  | some pa, some pb => some ⟨(w.toUInt32.toInt32).toInt, pa, pb⟩
  | _, _ => none

@[export bank_initial]
def initialC (_ : Unit) : UInt64 := initial.pack

@[export bank_enabled]
def enabledC (variant : UInt8) (state : UInt64) (event : UInt8) : UInt8 :=
  match S.unpack state, Event.ofTag event with
  | some s, some e => if (if variant == 0 then enabledUnsafe s e else enabledSafe s e) then 1 else 0
  | _, _ => 0

@[export bank_step]
def stepC (variant : UInt8) (state : UInt64) (event : UInt8) : UInt64 :=
  match S.unpack state, Event.ofTag event with
  | some s, some e => (if variant == 0 then stepUnsafe s e else stepSafe s e).pack
  | _, _ => state

end Bank
