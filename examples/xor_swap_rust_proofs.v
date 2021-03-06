
From Coq          Require Import Lists.List.
From Coq          Require Import String.
From Coq          Require Import Vectors.Vector.
From CryptolToCoq Require Import SAWCoreScaffolding.
From CryptolToCoq Require Import SAWCoreVectorsAsCoqVectors.

From CryptolToCoq Require Import SAWCorePrelude.
From CryptolToCoq Require Import CompMExtra.

Load "xor_swap_rust.v".
Import xor_swap_rust.

Definition xor_swap_spec x1 x2 :
  CompM ({_ : SAWCorePrelude.bitvector 64 & unit} *
         ({_ : SAWCorePrelude.bitvector 64 & unit} * unit)) :=
  returnM (existT _ x2 tt, ((existT _ x1 tt), tt)).
Arguments xor_swap_spec /.

(* FIXME: move lemma to SAWCorePrelude...? *)
Lemma bvXor_twice_r n x y :
  SAWCorePrelude.bvXor n (SAWCorePrelude.bvXor n x y) y = x.
Proof.
  admit.
Admitted.

(* FIXME: move lemma to SAWCorePrelude...? *)
Lemma bvXor_twice_l n x y :
  SAWCorePrelude.bvXor n (SAWCorePrelude.bvXor n y x) y = x.
Proof.
  admit.
Admitted.

Lemma xor_swap_correct : refinesFun xor_swap_rust xor_swap_spec.
Proof.
  prove_refinement.
  rewrite bvXor_twice_r. rewrite bvXor_twice_l.
  reflexivity.
Qed.
