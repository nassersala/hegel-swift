# Lean-verified model with a counter

The one-time-code login, modelled in Lean 4 with a real attempt counter
(`structure S where screen : Screen; attempts : Nat`), consumed by Hegel as an
*evaluator*: no table, no JSON. `lake build` compiles the model to C, the Swift
test links it and calls `otp_step` and `otp_enabled` from a `Command`'s `model:`
and `precondition:`.

What Lean checks (`Lean/Otp/Model.lean`): `step` is total; `Inv` (counter ≤ 3,
and < 3 while a code is being entered) holds initially and is preserved by every
step; `resend` never changes the counter; lockout happens exactly on the third
bad code; a bad code increments by exactly one. `Lean/Otp/Export.lean` is the C
boundary, scalars only (`UInt8` tags, `UInt32` counter, one packed `UInt64`
result), with the tag encoders proved to round-trip.

What Hegel checks (`Tests/.../OtpTests.swift`): a Swift `LoginScreen` refines
the Lean model over 300 random walks. A screen whose resend resets the counter
(violating `resend_keeps_attempts`) shrinks to five steps by observation alone,
and to three steps when `consistent:` compares the counter:

```
initial: sut phone/0, model phone/0
  send -> showCodeField
  badCode -> showError
  resend -> showCodeField
  invariant consistent failed
violated: screen code/0 vs model code/1
```

Two things the setup found on its own. Lean rejected the first invariant
("counter ≤ 3"): it is not preserved, since a code screen at 3 would go to 4;
the real invariant needs the "< 3 on the code screen" conjunct. And the first
Swift screen kept the counter after sign-in while the model resets it; no
response reveals that, only α with the counter did.

## The screen

`Sources/LoginUI` is the shipping code: an `@Observable LoginViewModel` (its
`handle(_:)` is the state machine) and a SwiftUI `LoginView`. It links nothing
from Lean. `Tests/.../ViewModelTests.swift` drives the view model against the
Lean `step`; the app just binds to it. So the screen on the simulator is the
tested one, and the test needs Lean only on the Mac that runs it.

```sh
cd App && xcodegen generate
xcodebuild -project LoginApp.xcodeproj -scheme LoginApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The correct code is 1234 (it says so on the screen). The screen explains
itself: a row of capsules shows which stimuli are possible in the current
state (what `isEnabled` says; the affordance property checks that list
against Lean's `enabled` after every step), and a trace of bubbles shows each
handled stimulus with its response, the state change, and the theorem the
test checks that step against. A toggle turns on the resend bug; the bubble
where the implementation stops agreeing with `resend_keeps_attempts` turns
red. The bubbles are the implementation's own trace, not a live oracle: the
app does not link Lean, the test does.

The affordance property (`affordancesMatchLeanEnabled`) is the
`AffordanceProperties` idea with a proved legality function as oracle; a
screen that hides Back when locked (`hidesBackWhenLocked`) is caught at the
lock, four steps in. Text
validation (empty phone, empty code) is deliberately outside it: the text is
the stimulus's argument, not the machine's state, so the model does not know
about it and the buttons disable on `!isEnabled || text.isEmpty`.

## Building

Needs Lean 4 via [elan](https://github.com/leanprover/elan) (installs under
`~/.elan`, no sudo):

```sh
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain stable
(cd Lean && lake build Otp:static)     # proofs checked, then C compiled to Lean/.lake/build/lib/libotp_Otp.a
swift test
```

`Package.swift` finds the toolchain through `LEAN_SYSROOT` (`lean
--print-prefix`) or the default elan toolchain, and links `libotp_Otp.a`
with Lean's static runtime (`libInit.a`, `libleanrt.a`, `libuv.a`,
`libgmp.a`) through `unsafeFlags`; that is why this is an example package
rather than a library dependency. The linker warns that the Lean objects
target a newer macOS than the package minimum; harmless.

Trusted, not checked: the C emitted by Lean, the tag encoding on the Swift
side (the Lean side's is proved), and the Lean runtime.
