{-# OPTIONS --safe #-}

module DoorModel where

-- This file is deliberately self-contained: it uses only Agda's builtins,
-- not the standard library.  The executable definition `step` is both the
-- subject of the proofs below and the source of the JSON table consumed by
-- Swift.  There is no second, hand-translated Swift model.

open import Agda.Builtin.Equality using (_≡_; refl)
open import Agda.Builtin.List using (List; []; _∷_)
open import Agda.Builtin.String using (String; primStringAppend)

infixr 5 _++_

_++_ : String → String → String
_++_ = primStringAppend

data State : Set where
  locked unlocked : State

data Command : Set where
  lock unlock openDoor : Command

data Observation : Set where
  ok opened denied : Observation

initial : State
initial = locked

record Transition : Set where
  constructor transition
  field
    next        : State
    observation : Observation

open Transition public

-- The complete abstract model.  Agda's coverage checker requires all six
-- state/command cases and its termination checker establishes totality.
step : State → Command → Transition
step locked   lock     = transition locked   ok
step locked   unlock   = transition unlocked ok
step locked   openDoor = transition locked   denied
step unlocked lock     = transition locked   ok
step unlocked unlock   = transition unlocked ok
step unlocked openDoor = transition unlocked opened

-- A safety theorem: the model can report that the door opened only when the
-- command began in the unlocked state.  The impossible equality in the
-- locked case is discharged by the empty pattern ().
open-only-when-unlocked :
  (state : State) → observation (step state openDoor) ≡ opened → state ≡ unlocked
open-only-when-unlocked locked   ()
open-only-when-unlocked unlocked refl = refl

-- A second small theorem used as provenance in the exported artifact.
locking-leaves-locked : (state : State) → next (step state lock) ≡ locked
locking-leaves-locked locked   = refl
locking-leaves-locked unlocked = refl

record Cell : Set where
  constructor cell
  field
    state   : State
    command : Command

open Cell

cells : List Cell
cells =
  cell locked   lock     ∷
  cell locked   unlock   ∷
  cell locked   openDoor ∷
  cell unlocked lock     ∷
  cell unlocked unlock   ∷
  cell unlocked openDoor ∷
  []

showState : State → String
showState locked   = "locked"
showState unlocked = "unlocked"

showCommand : Command → String
showCommand lock     = "lock"
showCommand unlock   = "unlock"
showCommand openDoor = "open"

showObservation : Observation → String
showObservation ok     = "ok"
showObservation opened = "opened"
showObservation denied = "denied"

showCell : Cell → String
showCell c =
  let result = step (state c) (command c)
  in  "    {\"state\":\"" ++ showState (state c) ++
      "\",\"command\":\"" ++ showCommand (command c) ++
      "\",\"next\":\"" ++ showState (next result) ++
      "\",\"observation\":\"" ++ showObservation (observation result) ++ "\"}"

showCells : List Cell → String
showCells []       = ""
showCells (c ∷ []) = showCell c
showCells (c ∷ cs) = showCell c ++ ",\n" ++ showCells cs

artifact : String
artifact =
  "{\n" ++
  "  \"schema\": 1,\n" ++
  "  \"model\": \"VerifiedDoor\",\n" ++
  "  \"source\": \"Agda/DoorModel.agda\",\n" ++
  "  \"initial\": \"" ++ showState initial ++ "\",\n" ++
  "  \"proofs\": [\"open-only-when-unlocked\", \"locking-leaves-locked\"],\n" ++
  "  \"transitions\": [\n" ++ showCells cells ++ "\n  ]\n" ++
  "}\n"
