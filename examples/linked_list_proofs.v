From Coq          Require Import Lists.List.
From Coq          Require Import String.
From Coq          Require Import Vectors.Vector.
From CryptolToCoq Require Import SAWCoreScaffolding.
From CryptolToCoq Require Import SAWCoreVectorsAsCoqVectors.
From Records      Require Import Records.

From CryptolToCoq Require Import SAWCorePrelude.
From CryptolToCoq Require Import CompMExtra.

Load "linked_list.v".
Import linked_list.

Import SAWCorePrelude.


Lemma no_errors_is_elem : refinesFun is_elem (fun _ _ => noErrorsSpec).
Proof.
  unfold is_elem, is_elem__tuple_fun, noErrorsSpec.
  prove_refinement.
Qed.

Lemma no_errors_is_elem_manual : refinesFun is_elem (fun _ _ => noErrorsSpec).
Proof.
  unfold is_elem, is_elem__tuple_fun.
  unfold noErrorsSpec.
  apply refinesFun_multiFixM_fst. intros x l.
  apply refinesM_letRecM0.
  apply refinesM_either_l; intros.
  - eapply refinesM_existsM_r. reflexivity.
  - apply refinesM_if_l; intros.
    + eapply refinesM_existsM_r. reflexivity.
    + rewrite existsM_bindM.
      apply refinesM_existsM_l; intros. rewrite returnM_bindM.
      eapply refinesM_existsM_r. reflexivity.
Qed.

Ltac destructArg_list :=
  (lazymatch goal with
  | |- MaybeDestructArg (list _) ?l ?g =>
    match g with
    | context [Datatypes.list_rect _ _ _ l] =>
      destruct l; simpl; apply noDestructArg
    end
  end).
Hint Extern 1 (MaybeDestructArg _ _ _) => destructArg_list :refinesFun.

(*
Fixpoint is_elem_spec (x:bitvector 64) (l:W64List) : CompM {_:bitvector 64 & unit} :=
  match l with
  | W64Nil => returnM (existT _ (bvNat 64 0) tt)
  | W64Cons y l' =>
    if bvEq 64 y x then returnM (existT _ (bvNat 64 1) tt) else
      is_elem_spec x l'
  end.
*)

Definition is_elem_fun (x:bitvector 64) :
  list {_:bitvector 64 & unit} -> CompM {_:bitvector 64 & unit} :=
  list_rect (fun _ => CompM {_:bitvector 64 & unit})
            (returnM (existT _ (bvNat 64 0) tt))
            (fun y l' rec =>
               if bvEq 64 (projT1 y) x then returnM (existT _ (bvNat 64 1) tt) else rec).

Arguments is_elem_fun /.

Lemma is_elem_fun_ref : refinesFun is_elem is_elem_fun.
Proof.
  unfold is_elem, is_elem__tuple_fun, is_elem_fun.
  prove_refinement.
Qed.

Lemma is_elem_fun_ref_manual : refinesFun is_elem is_elem_fun.
Proof.
  unfold is_elem, is_elem__tuple_fun, is_elem_fun.
  apply refinesFun_multiFixM_fst.
  apply refinesFunStep; intro x.
  apply refinesFunStep; intro l.
  destruct l; simpl; apply noDestructArg.
  - apply refinesM_letRecM0.
    reflexivity.
  - apply refinesM_letRecM0.
    apply refinesM_if_r; intro H; rewrite H; simpl.
    + reflexivity.
    + setoid_rewrite existT_eta_unit.
      setoid_rewrite bindM_returnM_CompM.
      reflexivity.
Qed.

(* The pure version of is_elem *)
Definition is_elem_pure (x:bitvector 64) (l:list {_:bitvector 64 & unit})
  : {_:bitvector 64 & unit} :=
  (list_rect (fun _ => {_:bitvector 64 & unit})
             (existT _ (bvNat 64 0) tt)
             (fun y l' rec =>
                if bvEq 64 (projT1 y) x then existT _ (bvNat 64 1) tt else rec) l).

Arguments is_elem_pure /.

Definition is_elem_lrt : LetRecType :=
  LRT_Fun (bitvector 64) (fun _ =>
    LRT_Fun (list {_:bitvector 64 & unit}) (fun _ =>
      LRT_Ret {_:bitvector 64 & unit})).

(* In order to prove this refinement we need induction on l, not just destruct!
   (Compare this to is_elem_fun_ref_manual) *)
Lemma is_elem_pure_fun_ref : @refinesFun is_elem_lrt is_elem_fun (fun x l => returnM (is_elem_pure x l)).
Proof.
  unfold is_elem_fun, is_elem_pure.
  apply refinesFunStep; intro x.
  apply refinesFunStep; intro l.
  induction l; simpl; apply noDestructArg.
  - reflexivity.
  - apply refinesM_if_l; intro H; rewrite H.
    + reflexivity.
    + exact IHl.
Qed.

Lemma is_elem_pure_ref : refinesFun is_elem (fun x l => returnM (is_elem_pure x l)).
Proof.
  intros x l. (* TODO add PreOrder_refinesFun to saw-core-coq to remove this line *)
  transitivity (is_elem_fun x l).
  exact (is_elem_fun_ref x l).
  exact (is_elem_pure_fun_ref x l).
Qed.

Definition orM {A} (m1 m2:CompM A) : CompM A :=
  existsM (fun (b:bool) => if b then m1 else m2).

Definition assertM (P:Prop) : CompM unit :=
  existsM (fun (_:P) => returnM tt).

(* The specification of is_elem: returns 1 if  *)
Definition is_elem_spec (x:bitvector 64) (l:list {_:bitvector 64 & unit})
  : CompM {_:bitvector 64 & unit} :=
  orM
    (assertM (List.In (existT _ x tt) l) >> returnM (existT _ (bvNat 64 1) tt))
    (assertM (~ List.In (existT _ x tt) l) >> returnM (existT _ (bvNat 64 0) tt)).

Arguments is_elem_spec /.

Lemma is_elem_spec_ref : refinesFun is_elem is_elem_spec.
Proof.
Admitted.


Arguments sorted_insert__tuple_fun /.
Eval simpl in sorted_insert__tuple_fun.

Lemma no_errors_sorted_insert : refinesFun sorted_insert (fun _ _ => noErrorsSpec).
Proof.
  unfold sorted_insert, sorted_insert__tuple_fun, noErrorsSpec.
  apply refinesFun_multiFixM_fst. intros x l. simpl.
  apply refinesM_letRecM0.
  destruct l; simpl.
  - unfold malloc, mallocSpec. rewrite returnM_bindM.
    eapply refinesM_existsM_r. reflexivity.
  - rewrite existsM_bindM. apply refinesM_existsM_l; intros.
    rewrite returnM_bindM.
    eapply refinesM_existsM_r. reflexivity.
Qed.
