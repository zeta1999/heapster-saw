{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module SAWScript.Heapster.SAWTranslation where

import Data.Kind
import GHC.TypeLits
import Control.Lens hiding ((:>),Index)
import Control.Monad.Reader

import Data.Binding.Hobbits
import Data.Binding.Hobbits.NameMap (NameMap, NameAndElem(..))
import qualified Data.Binding.Hobbits.NameMap as NameMap

import Data.Parameterized.Context hiding ((:>), empty, take, view)
import qualified Data.Parameterized.Context as Ctx
import Data.Parameterized.TraversableFC

import Lang.Crucible.FunctionHandle
import Lang.Crucible.Types
import Lang.Crucible.LLVM.Bytes
import Lang.Crucible.LLVM.Extension
import Lang.Crucible.LLVM.MemModel
import Lang.Crucible.LLVM.Arch.X86
import Lang.Crucible.CFG.Expr
import Lang.Crucible.CFG.Core
import Lang.Crucible.CFG.Extension
import Lang.Crucible.Analysis.Fixpoint.Components

import Verifier.SAW.OpenTerm
import Verifier.SAW.Term.Functor

import SAWScript.Heapster.CruUtil
import SAWScript.Heapster.Permissions
import SAWScript.Heapster.Implication
import SAWScript.Heapster.TypedCrucible


----------------------------------------------------------------------
-- * The Pure Translation Monad
----------------------------------------------------------------------

-- | The result of translating a pure expression at 'CrucibleType' @a@
data PureTransRes (a :: CrucibleType) where
  -- | LLVM pointers have their translations dictated by their permissions, so
  -- their "values" are empty, i.e., the unit type
  PTrans_LLVM :: PureTransRes (LLVMPointerType w)

  -- | Splittings are also translated to unit
  PTrans_Spl :: PureTransRes SplittingType

  -- | The translation for any other type. NOTE: it is an error to use this
  -- constructor with one of the types already listed above.
  PTrans_Other :: OpenTerm -> PureTransRes a


-- | A context mapping bound names to their type-level SAW translations
type PureTransCtx (ctx :: RList CrucibleType) = MapRList PureTransRes ctx

-- | Map a pure translation result to an 'OpenTerm' or 'Nothing' if it has no
-- pure content, i.e., if it is a splitting or LLVM value
pureResToTerm :: PureTransRes a -> Maybe OpenTerm
pureResToTerm PTrans_LLVM = Nothing
pureResToTerm PTrans_Spl = Nothing
pureResToTerm (PTrans_Other t) = Just t

-- | Map a context of pure translations to a list of 'OpenTerm's, dropping the
-- "invisible" ones that are always translated to unit
pureCtxToTerms :: PureTransCtx ctx -> [OpenTerm]
pureCtxToTerms MNil = []
pureCtxToTerms (ctx :>: (pureResToTerm -> Just t)) = pureCtxToTerms ctx ++ [t]
pureCtxToTerms (ctx :>: _) = pureCtxToTerms ctx


-- | The type translation monad = a reader monad for 'PureTransCtx'
type PureTransM ctx = Reader (PureTransCtx ctx)


-- | Run a 'PureTransM' computation in an extended context
inExtPureTransM :: PureTransRes tp -> PureTransM (ctx :> tp) a ->
                   PureTransM ctx a
inExtPureTransM tp_trans = withReader (:>: tp_trans)

-- | Build a lambda in a translation monad
lambdaTransM :: String -> OpenTerm -> (OpenTerm -> Reader r OpenTerm) ->
                Reader r OpenTerm
lambdaTransM x tp body_m =
  do r <- ask
     return $ lambdaOpenTerm x tp (\x -> runReader (body_m x) r)

-- | Build a pi in a translation monad
piTransM :: String -> OpenTerm -> (OpenTerm -> Reader r OpenTerm) ->
            Reader r OpenTerm
piTransM x tp body_m =
  do r <- ask
     return $ piOpenTerm x tp (\x -> runReader (body_m x) r)

-- | Build a let-binding in a translation monad
letTransM :: String -> OpenTerm -> OpenTerm ->
             (OpenTerm -> Reader r OpenTerm) -> Reader r OpenTerm
letTransM x tp rhs body_m =
  do r <- ask
     return $ letOpenTerm x tp rhs (\x -> runReader (body_m x) r)


----------------------------------------------------------------------
-- * The Pure Translation
----------------------------------------------------------------------

-- | The typeclass for the pure translation
class PureTranslate a res | a -> res where
  ptranslate :: Mb ctx a -> PureTransM ctx res

instance PureTranslate (NatRepr n) OpenTerm where
  ptranslate mb_n = return $ natOpenTerm $ mbLift $ fmap intValue mb_n

instance PureTranslate (TypeRepr a) OpenTerm where
  ptranslate [nuP| (AnyRepr) |] =
    return $ error "PureTranslate: Any"
  ptranslate [nuP| (UnitRepr) |] =
    return $ unitTypeOpenTerm
  ptranslate [nuP| (BoolRepr) |] =
    return $ dataTypeOpenTerm "Prelude.Bool" []
  ptranslate [nuP| (NatRepr) |] =
    return $ dataTypeOpenTerm "Prelude.Nat" []
  ptranslate [nuP| (IntegerRepr) |] =
    return $ error "PureTranslate: IntegerRepr"
  ptranslate [nuP| (RealValRepr) |] =
    return $ error "PureTranslate: RealValRepr"
  ptranslate [nuP| (ComplexRealRepr) |] =
    return $ error "PureTranslate: ComplexRealRepr"
  ptranslate [nuP| (BVRepr w) |] =
    applyOpenTerm (globalOpenTerm "Prelude.bitvector") <$> ptranslate w
  ptranslate [nuP| (LLVMPointerRepr _) |] =
    return $ unitTypeOpenTerm
  ptranslate [nuP| (IntrinsicRepr _ _) |] =
    return $ error "PureTranslate: IntrinsicRepr (other than LLVMPointerRepr)"
  ptranslate [nuP| (RecursiveRepr _ _) |] =
    return $ error "PureTranslate: RecursiveRepr"
  ptranslate [nuP| (FloatRepr _) |] =
    return $ dataTypeOpenTerm "Prelude.Float" []
  ptranslate [nuP| (IEEEFloatRepr _) |] =
    return $ error "PureTranslate: IEEEFloatRepr"
  ptranslate [nuP| (CharRepr) |] =
    return $ error "PureTranslate: CharRepr"
  ptranslate [nuP| (StringRepr) |] =
    return $ dataTypeOpenTerm "Prelude.String" []
  ptranslate [nuP| (FunctionHandleRepr _ _) |] =
    return $ error "PureTranslate: FunctionHandleRepr"
  ptranslate [nuP| (MaybeRepr tp) |] =
    applyOpenTerm (globalOpenTerm "Prelude.Maybe") <$> ptranslate tp
  ptranslate [nuP| (VectorRepr _) |] =
    return $ error "PureTranslate: VectorRepr (can't map to Vec without size)"
  ptranslate [nuP| (StructRepr _) |] =
    return $ error "PureTranslate: StructRepr"
  ptranslate [nuP| (VariantRepr _) |] =
    return $ error "PureTranslate: VariantRepr"
  ptranslate [nuP| (ReferenceRepr _) |] =
    return $ error "PureTranslate: ReferenceRepr"
  ptranslate [nuP| (WordMapRepr _ _) |] =
    return $ error "PureTranslate: WordMapRepr"
  ptranslate [nuP| (StringMapRepr _) |] =
    return $ error "PureTranslate: StringMapRepr"
  ptranslate [nuP| (SymbolicArrayRepr _ _) |] =
    return $ error "PureTranslate: SymbolicArrayRepr"
  ptranslate [nuP| (SymbolicStructRepr _) |] =
    return $ error "PureTranslate: SymbolicStructRepr"


instance PureTranslate (ExprVar a) (PureTransRes a) where
  ptranslate mb_x
    | Left memb <- mbNameBoundP mb_x = mapRListLookup memb <$> ask
  ptranslate mb_x = error "ptranslate: unbound variable!"

instance PureTranslate (PermExpr a) (PureTransRes a) where
  ptranslate = error "FIXME HERE NOW"

instance ress ~ (CtxToRList as) =>
         PureTranslate (PermExprs as) (PureTransCtx ress) where
  ptranslate = error "FIXME HERE NOW"

instance PureTranslate (BVFactor w) OpenTerm where
  ptranslate = error "FIXME HERE NOW"


-- [| p :: ValuePerm |] = type of the impure translation of reg with perms p
instance PureTranslate (ValuePerm a) OpenTerm where
  ptranslate = error "FIXME HERE NOW"

instance PureTranslate (ValuePerms a) [OpenTerm] where
  ptranslate = error "FIXME HERE NOW"


----------------------------------------------------------------------
-- * The Impure Translation Monad
----------------------------------------------------------------------

-- | The result of translating an impure expression at 'CrucibleType' @a@
data ImpTransRes (a :: CrucibleType) where
  -- | LLVM pointer permissions can be broken into multiple SAW terms, one for
  -- each pointer permission
  ITrans_LLVMPtr :: [OpenTerm] -> ImpTransRes (LLVMPointerType w)

  -- | The @true@ permission translated to unit, i.e., nothing
  ITrans_True :: ImpTransRes a

  -- | An @eq(e)@ permission is also translated to unit
  ITrans_Eq :: ImpTransRes a

  -- | Any other permissions are just SAW terms. Note that this can include LLVM
  -- pointer permissions that have not yet been broken into multiple SAW terms.
  ITrans_Other :: OpenTerm -> ImpTransRes a

-- | A context mapping bound names to their perm translations
type ImpTransCtx (ctx :: RList CrucibleType) = MapRList ImpTransRes ctx


-- | Map an impure translation result to an 'OpenTerm'
impureResToTerm :: ImpTransRes a -> OpenTerm
impureResToTerm (ITrans_LLVMPtr ts) = tupleOpenTerm ts
impureResToTerm ITrans_True = unitOpenTerm
impureResToTerm ITrans_Eq = unitOpenTerm
impureResToTerm (ITrans_Other t) = t

-- | Map a context of pure translations to a list of 'OpenTerm's, dropping the
-- "invisible" ones that are always translated to unit
impureCtxToTerms :: ImpTransCtx ctx -> [OpenTerm]
impureCtxToTerms MNil = []
impureCtxToTerms (ctx :>: res) = impureCtxToTerms ctx ++ [impureResToTerm res]


-- | A mapping from a block entrypoint to its corresponding SAW variable that is
-- bound to its translation
data TypedEntryTrans ext blocks ret args =
  TypedEntryTrans (TypedEntry ext blocks ret args) OpenTerm

-- | A mapping from a block to the SAW functions for each entrypoint
data TypedBlockTrans ext blocks ret args =
  TypedBlockTrans [TypedEntryTrans ext blocks ret args]

-- | A mapping from all block entrypoints to their SAW translations
type TypedBlockMapTrans ext blocks ret =
  MapRList (TypedBlockTrans ext blocks ret) blocks

-- | Translate an entrypoint ID by looking up its SAW function
translateTypedEntryID :: TypedEntryID blocks args ghosts ->
                         TypedBlockMapTrans ext blocks ret ->
                         OpenTerm
translateTypedEntryID entryID blkMap =
  let TypedBlockTrans entries = mapRListLookup (entryBlockID entryID) blkMap in
  foldr (\(TypedEntryTrans entry trm) rest ->
          case entry of
            TypedEntry entryID' _ _ _
              | Just Refl <- testEquality entryID entryID' -> trm
            _ -> rest)
  (error "translateTypedEntryID")
  entries


-- | Contextual info for a permission-level translation
data ImpTransInfo ext blocks ret args ps ctx =
  ImpTransInfo
  {
    itiExprCtx :: PureTransCtx ctx,
    itiPermSet :: Mb ctx (PermSet ps),
    itiPermCtx :: ImpTransCtx ctx,
    itiBlockTrans :: TypedBlockMapTrans ext blocks ret,
    itiCatchHandler :: Maybe OpenTerm
  }

permTransInfoExtend :: PureTransRes tp -> ValuePerm tp -> ImpTransRes tp ->
                       ImpTransInfo ext blocks ret args ps ctx ->
                       ImpTransInfo ext blocks ret args ps (ctx :> tp)
permTransInfoExtend tp_trans p perm_trans (ImpTransInfo {..}) =
  ImpTransInfo
  { itiExprCtx = itiExprCtx :>: tp_trans
  , itiPermCtx = itiPermCtx :>: perm_trans
  , itiPermSet =
      mbCombine $
      fmap (\perms -> nu (\n -> set (varPerm n) p perms)) itiPermSet
  , .. }

-- | The monad for permission-level translation
type ImpTransM ext blocks ret args ps ctx =
  Reader (ImpTransInfo ext blocks ret args ps ctx)

-- | Embed a pure translation into an impure translation
embedPureM :: PureTransM ctx a -> ImpTransM ext blocks ret args ps ctx a
embedPureM = withReader itiExprCtx

-- | Run an 'ImpTransM' computation in an extended context
inExtImpTransM :: PureTransRes tp -> ValuePerm tp -> ImpTransRes tp ->
                  ImpTransM ext blocks ret args ps (ctx :> tp) a ->
                  ImpTransM ext blocks ret args ps ctx a
inExtImpTransM tp_trans p perm_trans =
  withReader $ permTransInfoExtend tp_trans p perm_trans

-- | Apply the translation of a function-like construct (i.e., a
-- 'TypedJumpTarget' or 'TypedFnHandle') to the pure plus impure translations of
-- its arguments
translateApply :: OpenTerm -> PureTransCtx tps -> ImpTransCtx tps ->
                  OpenTerm
translateApply f p_args i_args =
  applyOpenTermMulti f (pureCtxToTerms p_args ++ impureCtxToTerms i_args)


----------------------------------------------------------------------
-- * The Impure Translation
----------------------------------------------------------------------

-- | The typeclass for the impure translation
class ImpureTranslate a res ext blocks ret args ps | a -> res where
  itranslate :: Mb ctx a -> ImpTransM ext blocks ret args ps ctx res

-- | The typeclass for the impure translation of a functor at any type to an
-- 'OpenTerm'
class ImpureTranslate1 f ext blocks ret args ps where
  itranslate1 :: Mb ctx (f a) -> ImpTransM ext blocks ret args ps ctx OpenTerm

instance ImpureTranslate1 f ext blocks ret args ps =>
         ImpureTranslate (PermImpl f ps) OpenTerm ext blocks ret args ps where
  itranslate = error "FIXME HERE NOW"

instance ImpureTranslate (TypedReg tp) (ImpTransRes tp)
         ext blocks ret args ps where
  itranslate = error "FIXME HERE NOW"

instance ImpureTranslate (TypedExpr ext tp) (ImpTransRes tp)
         ext blocks ret args ps where
  itranslate = error "FIXME HERE NOW"

instance ImpureTranslate (TypedEntryID blocks args' ghosts) OpenTerm
         ext blocks ret args ps where
  itranslate mb_entryID =
    translateTypedEntryID (mbLift mb_entryID) <$> itiBlockTrans <$> ask

-- A sequence of distinguished permissions on variables translates to a list of
-- pure translations of the variables and impure translations of the permissions
-- on them
instance ImpureTranslate (DistPerms tps) (PureTransCtx tps, ImpTransCtx tps)
         ext blocks ret args ps where
  itranslate [nuP| DistPermsNil |] = return (MNil, MNil)
  itranslate [nuP| DistPermsCons perms x _ |] =
    do (p_trs,i_trs) <- itranslate perms
       p_tr <- embedPureM $ ptranslate x
       i_tr <- itranslate (fmap TypedReg x)
       return (p_trs :>: p_tr, i_trs :>: i_tr)

instance ImpureTranslate (TypedJumpTarget blocks ps) OpenTerm
         ext blocks ret args ps where
  itranslate [nuP| TypedJumpTarget entryID _ perms |] =
    do f <- itranslate entryID
       (p_args, i_args) <- itranslate perms
       return $ translateApply f p_args i_args

{-
FIXME HERE NOW:
- Need something special for TypedStmt to bind vars; maybe just do seqs?
- ImpTranslate for statement sequences, blocks / entrypoints, and CFGs
-}
