Require Import Coq.Init.Datatypes.
Require Import Coq.Lists.List.
Require Import Coq.Arith.MinMax.
Require Import Omega.
Require Import CpdtTactics.


Module Type ACTION.

  Parameter A : Type.

  Parameter None : A.

  Definition well_behaved (f : A -> A -> A) : Prop :=
    (forall (a : A), f a None = a) /\
    (forall (a : A), f None a = a).

End ACTION.
