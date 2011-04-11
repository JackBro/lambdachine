{-# LANGUAGE ViewPatterns, GADTs, ScopedTypeVariables #-}
{-# LANGUAGE PatternGuards, GeneralizedNewtypeDeriving #-}
{-| Generate bytecode from GHC Core.

GHC Core has quite a few invariants and accommodating them all
can be quite difficult (and fragile).  Fortunately, GHC provides
a clean-up transformation called @CorePrep@ that essentially transforms
Core into A-normal form.  The grammar for the output is:

@
    Trivial expressions 
       triv ::= lit |  var  | triv ty  |  /\a. triv  |  triv |> co

    Applications
       app ::= lit  |  var  |  app triv  |  app ty  |  app |> co

    Expressions
       body ::= app
              | let(rec) x = rhs in body     -- Boxed only
              | case body of pat -> body
	      | /\a. body
              | body |> co

    Right hand sides (only place where lambdas can occur)
       rhs ::= /\a.rhs  |  \x.rhs  |  body
@

Boquist's GRIN used different translation schemes for generating code
in a strict context and in a lazy context.  The latter would just
build a thunk.  We don't need this here, because thunks are build
using @let@ expressions.

The translation scheme still passes around a 'Context' argument, but
that is used mainly to detect tail calls.

Our bytecode does not support @let@ statements.  Nested bindings are
translated into top-level bindings and matching allocation
instructions at the original binding site.

 -}
module Lambdachine.Ghc.CoreToBC where

import Lambdachine.Builtin
import Lambdachine.Ghc.Utils
import Lambdachine.Grin.Bytecode as Grin
import Lambdachine.Id as N
import Lambdachine.Utils hiding ( Uniquable(..) )
import Lambdachine.Utils.Unique ( mkBuiltinUnique )

import qualified Var as Ghc
import qualified VarEnv as Ghc
import qualified VarSet as Ghc
import qualified HscTypes as Ghc ( CoreModule(..) )
import qualified Module as Ghc
import qualified Literal as Ghc
import qualified Name as Ghc
import qualified IdInfo as Ghc
import qualified Id as Ghc
import qualified Type as Ghc
import qualified DataCon as Ghc
import qualified CoreSyn as Ghc ( Expr(..), mkConApp )
import qualified PrimOp as Ghc
import qualified TysWiredIn as Ghc
import qualified TysPrim as Ghc
import qualified TyCon as Ghc
import qualified TypeRep as Ghc
import qualified Outputable as Ghc
import TyCon ( TyCon )
import Outputable ( Outputable, showPpr, alwaysQualify, showSDocForUser )
import CoreSyn ( CoreBind, CoreBndr, CoreExpr, CoreArg, CoreAlt,
                 Bind(..), Expr(Lam, Let, Type, Cast, Note),
                 AltCon(..),
                 collectBinders, flattenBinds, collectArgs )
import Var ( isTyVar )
import Unique ( Uniquable(..), getKey )
import FastString ( unpackFS )

import qualified Data.Map as M
import qualified Data.Set as S
import Control.Applicative hiding ( (<*>) )
import Control.Monad.State
import Control.Monad.Reader
--import Control.Monad.Fix
import Data.Foldable ( toList )
import Data.List ( foldl', sortBy )
import Data.Ord ( comparing )
import Data.Monoid
import Data.Maybe ( fromMaybe )

import Debug.Trace

----------------------------------------------------------------------
-- * Debug Utils:

unimplemented :: String -> a
unimplemented str = error $ "UNIMPLEMENTED: " ++ str

tracePpr :: Outputable a => a -> b -> b
tracePpr o exp = trace (">>> " ++ showPpr o) exp

-- -------------------------------------------------------------------
-- * Top-level Interface
type Bcis x = BcGraph O x

generateBytecode :: Supply Unique -> Ghc.ModuleName -> [CoreBind] -> [TyCon] -> BCOs
generateBytecode us mdl bndrs0 data_tycons =
  runTrans mdl us $ do
    let dcon_bcos = M.unions $ map transTyCon data_tycons
    toplevel_bcos <- go bndrs0 mempty
    local_bcos <- getBCOs
    return (M.unions [dcon_bcos, toplevel_bcos, local_bcos])
 where
--   go _ _ | trace "genBC-go" False = undefined
   go [] acc = return acc
   go (NonRec f body : bndrs) acc = do
     bcos <- transTopLevelBind f body
     go bndrs (M.union bcos acc)
   go (Rec fs : bndrs) acc =
     let go' [] acc' = go bndrs acc'
         go' ((f, body):fs') acc' = do
           bcos <- transTopLevelBind f body
           go' fs' (M.union bcos acc')
     in go' fs acc

transTyCon :: TyCon -> BCOs
transTyCon tycon = do
  let bcos0 =
        M.singleton (tyConId (Ghc.tyConName tycon))
           BcTyConInfo{ bcoDataCons =
                          map dataConInfoTableId (Ghc.tyConDataCons tycon) }
  collect' bcos0 (Ghc.tyConDataCons tycon) $ \bcos dcon ->
    let dcon_id = dataConInfoTableId dcon
        ty = transType (Ghc.dataConRepType dcon)
        arg_tys | FunTy args _ <- ty = args
                | otherwise = []
        bco = BcConInfo { bcoConTag = Ghc.dataConTag dcon
                        , bcoConFields = Ghc.dataConRepArity dcon
                        , bcoConArgTypes = arg_tys }
    in M.insert dcon_id bco bcos

transTopLevelBind :: CoreBndr -> CoreExpr -> Trans BCOs
transTopLevelBind f (viewGhcLam -> (params, body)) = do
  this_mdl <- getThisModule
  let !f' = toplevelId this_mdl f
  let bco_type | (_:_) <- params = BcoFun (length params)
               | looksLikeCon body = Con
               | isGhcConWorkId f = Con
               | otherwise = CAF
  case bco_type of
    Con -> buildCon f' body
    _ -> do
      let env0 = mkLocalEnv [(x, undefined) | x <- params]
          locs0 = mkLocs [ (b, InReg n) | (b, n) <- zip params [0..] ]
          fvi0 = Ghc.emptyVarEnv
      (bcis, _, fvs, Nothing) <- withParentFun f $ transBody body env0 fvi0 locs0 RetC
      g <- finaliseBcGraph bcis
      let bco = BcObject { bcoType = bco_type
                         , bcoCode = g
                         , bcoGlobalRefs = toList (globalVars fvs)
                         , bcoConstants = []
                         , bcoFreeVars = M.empty
                         }
      return (M.singleton f' bco)

-- | Translate a GHC System FC type into runtime type info.
--
-- We currently look through type abstraction and application.  A
-- polymorphic type (i.e., a type variable) is just represented as a
-- pointer.  At runtime such a value must have an associated info
-- table, so we can just look at that to figure out the type.
--
-- TODO: How to deal with 'void' types, like @State#@?
--
transType :: Ghc.Type -> OpTy
transType (Ghc.TyConApp tycon _)
  | Ghc.isPrimTyCon tycon =
    case () of
     _ | tycon == Ghc.intPrimTyCon   -> IntTy
       | tycon == Ghc.charPrimTyCon  -> CharTy
       | tycon == Ghc.floatPrimTyCon -> FloatTy
       | tycon == Ghc.byteArrayPrimTyCon -> PtrTy
       | otherwise ->
         error $ "Unknown primitive type: " ++ showPpr tycon
  | otherwise =
    AlgTy (tyConId (Ghc.tyConName tycon))
transType ty@(Ghc.FunTy _ _) | (args, res) <- Ghc.splitFunTys ty =
  FunTy (map transType args) (transType res)
-- Type abstraction stuff.  See documentation above.
transType (Ghc.ForAllTy _ t) = transType t
transType (Ghc.TyVarTy _) = PtrTy
transType (Ghc.AppTy t _) = transType t
-- Get the dictionary data type for predicates.
-- TODO: I think this may cause a GHC panic under some circumstances.
transType (Ghc.PredTy pred) =
  transType (Ghc.predTypeRep pred)
transType ty =
  error $ "transType: Don't know how to translate type: "
          ++ showPpr ty

looksLikeCon :: CoreExpr -> Bool
looksLikeCon (viewGhcApp -> Just (f, args)) = 
  not (null args) && isGhcConWorkId f 
looksLikeCon _ = False

buildCon :: Id -> CoreExpr -> Trans BCOs
buildCon f (viewGhcApp -> Just (dcon, args0)) = do
  this_mdl <- getThisModule
  let dcon' = dataConInfoTableId (ghcIdDataCon dcon)
      fields = transFields (toplevelId this_mdl) args0
  return (M.singleton f (BcoCon Con dcon' fields))

data ClosureInfo
  = ConObj Ghc.Id [CoreArg] --[Either BcConst Ghc.Id]
  | AppObj Ghc.Id [CoreArg] --[Either BcConst Ghc.Id]
  | FunObj !Int Id [Ghc.Id]

-- | Translate a local binding.
--
-- For a simple non-recursive binding we distinguish three forms of
-- the RHS:
--
--   * @C x1 .. xN@: Constructor application.  This is
--     translated into a direct @ALLOC@ instruction.
--
--   * @f x1 .. xN@: Regular function application.  GHC creates custom
--     code for each application.  Since we're paying the bytecode
--     overhead already, however, we can just create a generic @AP@
--     node.  The JIT will automatically generate specialised code for
--     commonly encountered @AP@ nodes (or optimise away their
--     creation in the first place).
--
--   * For anything else we create a new top-level BCO.
--
-- In each case we keep track of the free variables referenced by the RHS
-- and allocate the proper object at the original binding site.
--
-- In the case of recursive bindings matters get slightly more
-- complicated.  Consider the following code:
--
-- > let x = Cons a y
-- >     y = Cons b x
-- > in ...
--
-- Note that the first reference to @y@ is actually a forward
-- reference, that is, the value of @y@ is not known at the point
-- where it is needed to initialise the object stored in @x@.
--
-- There are (at least) two options to translate this into bytecode:
--
-- Option 1: Write a dummy value into the @x@ object and then update
-- it later when the value of @y@ is known:
--
-- > LOADCON r1, Cons
-- > LOADCON r2, Blackhole
-- > ALLOC r3, r1, <a>, r2  -- allocate (Cons a *)
-- > ALLOC r4, r1, <b>, r3  -- allocate (Cons b x)
-- > STORE r3, 2, r4        -- fixup second field of x
--
-- Option 2: Separate allocation from initialisation.
--
-- > ALLOC r3, Cons
-- > ALLOC r4, Cons
-- > STORE r3, 1, <a>
-- > STORE r3, 2, r4
-- > STORE r4, 1, <b>
-- > STORE r4, 2, r3
--
-- It is not obvious which variant is better.  Option 2 requires that
-- the allocation and initialisation sequence is non-interruptible.
-- Otherwise, the fields freshly allocated objects must be initialised
-- to a dummy value in order to avoid confusing the garbage collector.
-- For that reason we currently use Option 1.
-- 
transBinds :: CoreBind -> LocalEnv -> FreeVarsIndex 
           -> KnownLocs
           -> Trans (Bcis O, KnownLocs, FreeVars, LocalEnv)
transBinds bind env fvi locs0 = do
  case bind of
    NonRec f body -> do
      ci <- transBind f body env
      build_bind_code Ghc.emptyVarEnv (extendLocalEnv env f undefined)
                      fvi [(f, ci)] locs0
    Rec bndrs -> do
      let xs = map fst bndrs
          env' = extendLocalEnvList env xs
      (cis, fw_env) <- trans_binds_rec (Ghc.mkVarSet xs) bndrs env' Ghc.emptyVarEnv []
      let locs1 = extendLocs locs0 [ (x, Fwd) | x <- xs ]
      build_bind_code fw_env env' fvi cis locs1
 where
   trans_binds_rec :: Ghc.VarSet -- variables that will be defined later
                   -> [(CoreBndr, CoreExpr)] -- the bindings
                   -> LocalEnv  -- the local env
                   -> Ghc.VarEnv [(Int, Ghc.Id)] -- fixup accumulator
                   -> [(Ghc.Id, ClosureInfo)] -- closure info accumulator
                   -> Trans ([(Ghc.Id, ClosureInfo)],
                             Ghc.VarEnv [(Int, Ghc.Id)])
   trans_binds_rec _fwds [] _env fix_acc ci_acc =
     return (reverse ci_acc, fix_acc)
   trans_binds_rec fwds ((f, body):binds) env fix_acc ci_acc = do
     closure_info <- transBind f body env
     let fwd_refs =
           case closure_info of
             ConObj dcon fields ->
               [ (x, offs) | (offs, Right x) <- zip [1..] (map viewGhcArg fields)
                           , x `Ghc.elemVarSet` fwds ]
             AppObj doc fields ->
               [ (x, offs) | (offs, Right x) <- zip [2..] (map viewGhcArg fields)
                           , x `Ghc.elemVarSet` fwds ]
             FunObj _ _ frees ->
               [ (x, offs) | (offs, x) <- zip [1..] frees
                           , x `Ghc.elemVarSet` fwds ]
     let fix_acc' = foldl' (\e (x, offs) ->
                              Ghc.extendVarEnv_C (++) e x [(offs, f)])
                      fix_acc fwd_refs
     let fwds' = Ghc.delVarSet fwds f
     trans_binds_rec fwds' binds env fix_acc'
                     ((f, closure_info) : ci_acc)

-- | Creates the actual code sequence (including fixup of forward references).
build_bind_code :: Ghc.VarEnv [(Int, Ghc.Id)]
                -> LocalEnv -> FreeVarsIndex
                -> [(Ghc.Id, ClosureInfo)] -> KnownLocs
                -> Trans (Bcis O, KnownLocs, FreeVars, LocalEnv)
build_bind_code fwd_env env fvi closures locs0 = do
  (bcis, locs, fvs) <- go emptyGraph locs0 mempty closures
  return (bcis, locs, fvs, env)
 where
   -- TODO: Do we need to accumulate the environment?
   go bcis locs fvs [] = return (bcis, locs, fvs)

   go bcis locs0 fvs ((x, ConObj dcon fields) : objs) = do
     (bcis1, locs1, fvs1, Just r)
       <- transStore dcon fields env fvi locs0 (BindC Nothing)
     let locs2 = updateLoc locs1 x (InVar r)
     go (bcis <*> bcis1 <*> add_fw_refs x r locs2) locs2 (fvs `mappend` fvs1) objs

   go bcis locs0 fvs ((x, AppObj f args) : objs) = do
     (bcis1, locs1, fvs1, (freg:regs))
       <- transArgs (Ghc.Var f : args) env fvi locs0
     rslt <- mbFreshLocal Nothing
     let bcis2 = (bcis <*> bcis1) <*> insMkAp rslt (freg:regs)
         locs2 = updateLoc locs1 x (InVar rslt)
         bcis3 = bcis2 <*> add_fw_refs x rslt locs2
     go bcis3 locs2 (fvs `mappend` fvs1) objs

   go bcis locs0 fvs ((x, FunObj _arity info_tbl0 args) : objs) = do
     let info_tbl = mkInfoTableId (idName info_tbl0)
     (bcis1, locs1, fvs1, regs)
       <- transArgs (map Ghc.Var args) env fvi locs0
     tag_reg <- mbFreshLocal Nothing
     rslt <- mbFreshLocal Nothing
     let bcis2 = bcis <*> bcis1 <*> insLoadGbl tag_reg info_tbl <*>
                 insAlloc rslt tag_reg regs
         locs2 = updateLoc locs1 x (InVar rslt)
         bcis3 = bcis2 <*> add_fw_refs x rslt locs2
     go bcis3 locs2 (fvs `mappend` fvs1) objs

   add_fw_refs x r locs =
     case Ghc.lookupVarEnv fwd_env x of
       Nothing -> emptyGraph --emptyBag
       Just fixups ->
         catGraphs $   -- listToBag $
           [ insStore ry n r | (n, y) <- fixups,
                               let Just (InVar ry) = lookupLoc locs y ]

transBind :: CoreBndr -- ^ The binder name ...
          -> CoreExpr -- ^ ... and its body.
          -> LocalEnv -- ^ The 'LocalEnv' at the binding site.
          -> Trans ClosureInfo
transBind x (viewGhcApp -> Just (f, args)) _env0
 | isGhcConWorkId f
 = return (ConObj f args)
 | Just _ <- isGhcPrimOpId f
 = error $ "Primop in let: " ++ showPpr x
 | otherwise
 = return (AppObj f args)
transBind x (viewGhcLam -> (bndrs, body)) env0 = do
  let locs0 = mkLocs $ (x, Self) : [ (b, InReg n) | (b, n) <- zip bndrs [0..] ]
      env = fold2l' extendLocalEnv env0 bndrs (repeat undefined)

  -- Here comes the magic:
  (bcis, vars, gbls, _) <- mfix $ \ ~(_bcis, _vars, _gbls, fvis) -> do
    (bcis, locs', fvs, Nothing) <- withParentFun x $ transBody body env fvis locs0 RetC
    let closure_vars = Ghc.varSetElems (closureVars fvs)
        -- maps from closure variable to its index
        cv_indices = Ghc.mkVarEnv (zip closure_vars [(1::Int)..])
    return (bcis, closure_vars, globalVars fvs, cv_indices)

  this_mdl <- getThisModule
  parent <- getParentFun
  let cl_prefix | Nothing <- parent = ".cl_"
                | Just s  <- parent = ".cl_" ++ s ++ "_"
  x' <- freshVar (showPpr this_mdl ++ cl_prefix ++ Ghc.getOccString x) mkTopLevelId
  trace ("DBG: " ++ show parent ++ "=>" ++ show x') $ do
  g <- finaliseBcGraph bcis
  let arity = length bndrs
      free_vars = M.fromList [ (n, transType (Ghc.varType v))
                              | (n, v) <- zip [1..] vars ]
  let bco = BcObject { bcoType = if arity > 0 then BcoFun arity else Thunk
                     , bcoCode = g
                     , bcoConstants = []
                     , bcoGlobalRefs = toList gbls
                     , bcoFreeVars = free_vars }
  addBCO x' bco
  return (FunObj arity x' vars)

transFields :: (Ghc.Id -> a) -> [CoreArg] -> [Either BcConst a]
transFields f args = map to_field args
 where
   to_field (Ghc.Lit (Ghc.MachInt n)) = Left (CInt n)
   to_field (Ghc.Var x)               = Right (f x)
   to_field (Ghc.App x (Ghc.Type _))  = to_field x
   to_field (Lam a x) | isTyVar a     = to_field x
   to_field (Cast x _)                = to_field x
   to_field (Note _ x)                = to_field x
   to_field arg = 
     error $ "transFields: Ill-formed argument: " ++ showPpr arg

-- -------------------------------------------------------------------

newtype Trans a = Trans { unTrans :: State TransState a }
  deriving (Functor, Applicative, Monad, MonadFix)

-- transFix :: (a -> Trans a) -> Trans a
-- transFix f = let Trans s = 

data TransState = TransState
  { tsUniques :: Supply Unique
  , tsLocalBCOs :: BCOs
  , tsModuleName :: Ghc.ModuleName
  , tsParentFun :: Maybe String
  }

runTrans :: Ghc.ModuleName -> Supply Unique -> Trans a -> a
runTrans mdl us (Trans m) = evalState m s0
 where
   s0 = TransState { tsUniques = us
                   , tsLocalBCOs = M.empty
                   , tsModuleName = mdl
                   , tsParentFun = Nothing }

genUnique :: Trans (Supply Unique)
genUnique = Trans $ do
  s <- get
  case split2 (tsUniques s) of
    (us, us') -> do
      put $! s{ tsUniques = us }
      return us'

getThisModule :: Trans Ghc.ModuleName
getThisModule = Trans $ gets tsModuleName

withParentFun :: Ghc.Id -> Trans a -> Trans a
withParentFun x (Trans act) = Trans $ do
  s <- get
  let x_occ = showSDocForUser Ghc.neverQualify (Ghc.ppr (Ghc.getOccName x))
      pfun = tsParentFun s
  put $! (case pfun of
           Nothing ->
             s{ tsParentFun = Just x_occ }
           Just p ->
             s{ tsParentFun = Just (p ++ "_" ++ x_occ) })
  r <- act
  s' <- get
  put $! s'{ tsParentFun = pfun }
  return r

getParentFun :: Trans (Maybe String)
getParentFun = Trans (gets tsParentFun)

instance UniqueMonad Trans where
  freshUnique = hooplUniqueFromUniqueSupply `fmap` genUnique

addBCO :: Id -> BytecodeObject -> Trans ()
addBCO f bco = Trans $
  modify' $ \s ->
    let !bcos' = M.insert f bco (tsLocalBCOs s) in
    s{ tsLocalBCOs = bcos' }

getBCOs :: Trans BCOs
getBCOs = Trans $ gets tsLocalBCOs

-- | Describes where to find the value of a variable.
data ValueLocation
  = InVar BcVar
    -- ^ The value has already been loaded into the given register.
  | Field BcVar Int
    -- ^ The value can be loaded from memory by loading the nth slot
    -- from the given variable.
  | InReg Int
    -- ^ The value is in a specific register.
  | FreeVar Int
  | Fwd
    -- ^ A forward reference.
  | Self
    -- ^ The value is the contents of the @Node@ pointer.
  | Global Id
  deriving Show

-- | Maps GHC Ids to their (current) location in bytecode.
--
-- For example, when translating the body of function @f x y@,
-- this will map @x@ to @InReg 0@ and @y@ to @InReg 1@.
-- This corresponds to the calling convention.
--
-- We also use this to avoid unnecessary loads.  When pattern matching
-- variable @z@ the beginning of the case alternative for @C x y@ will
-- /not/ immediately load @x@ and @y@ into registers.  Instead we add
-- @x -> Field z 1@ and @y -> Field z 2@ to the @KnownLocs@.  If we
-- later do need @x@ or @y@ we can issue the store there.
--
newtype KnownLocs = KnownLocs (Ghc.IdEnv ValueLocation)

lookupLoc :: KnownLocs -> CoreBndr -> Maybe ValueLocation
lookupLoc (KnownLocs env) x = Ghc.lookupVarEnv env x

updateLoc :: KnownLocs -> CoreBndr -> ValueLocation -> KnownLocs
updateLoc (KnownLocs env) x l = KnownLocs $ Ghc.extendVarEnv env x l

extendLocs :: KnownLocs -> [(CoreBndr, ValueLocation)] -> KnownLocs
extendLocs (KnownLocs env) xls = 
  KnownLocs $ Ghc.extendVarEnvList env xls

noLocs :: KnownLocs
noLocs = KnownLocs Ghc.emptyVarEnv

mkLocs :: [(Ghc.Id, ValueLocation)] -> KnownLocs
mkLocs l = KnownLocs (Ghc.mkVarEnv l)

instance Monoid KnownLocs where
  mempty = noLocs
  (KnownLocs e1) `mappend` (KnownLocs e2) =
    KnownLocs (Ghc.plusVarEnv e1 e2)

-- | Keeps track of non-toplevel variables bound outside the current
-- bytecode context.  Consider the following example:
--
-- > f l y = case l of
-- >           Cons x xs -> let g = <body> in
-- >                        ...
--
-- Assume that @<body>@ mentions @y@ and @x@; these have to become
-- closure variables.  The bytecode for @let g ...@ will look
-- something like this.
--
-- > loadinfo tmp, info-table-for-<body>
-- > alloc tmp, <x>, <y>
--
-- This allocates a closure of size 2, corresponding to the two free
-- variables.  The code for accessing @x@ and @y@ in @<body>@ then has
-- to access them as closure variables, e.g.,
--
-- > loadf r1, 0   ; access x
-- > loadf r3, 1   ; access y
--
-- References to global variables in @<body>@ are accessed as usual
-- using @loadg@ instructions.
--
-- When translating @<body>@ above, this environment contains @{l, y,
-- x, xs}@.
newtype LocalEnv = LocalEnv (Ghc.IdEnv Id)

-- | Lookup element from a 'LocalEnv'.
lookupLocalEnv :: LocalEnv -> Ghc.Id -> Maybe Id
lookupLocalEnv (LocalEnv env) x = Ghc.lookupVarEnv env x

-- | Add a mapping to a 'LocalEnv'.
extendLocalEnv :: LocalEnv -> Ghc.Id -> Id -> LocalEnv
extendLocalEnv (LocalEnv env) x y =
  LocalEnv (Ghc.extendVarEnv env x y)

-- | Create a 'LocalEnv' from a list.
mkLocalEnv :: [(Ghc.Id, Id)] -> LocalEnv
mkLocalEnv lst = LocalEnv (Ghc.mkVarEnv lst)

extendLocalEnvList :: LocalEnv -> [Ghc.Id] -> LocalEnv
extendLocalEnvList (LocalEnv env) xs =
  LocalEnv $ Ghc.extendVarEnvList env [ (x, undefined) | x <- xs ]

-- | Create an empty 'LocalEnv'.  @emptyLocalEnv == mkLocalEnv []@
emptyLocalEnv :: LocalEnv
emptyLocalEnv = LocalEnv Ghc.emptyVarEnv


type FreeVarsIndex = Ghc.IdEnv Int

-- | The context describes whether we should bind the result of the
-- translated expression (and to which variable).
--
-- The Type parameter describes the exit shape of the resulting graph.
--
-- If the context is @BindC (Just r)@, then the result should be
-- written into register @r@.  If it is @BindC Nothing@ then the
-- result should be written into a fresh local variable.
data Context x where
  RetC :: Context C
  BindC :: Maybe BcVar -> Context O

contextVar :: Context x -> Maybe BcVar
contextVar RetC = Nothing
contextVar (BindC mx) = mx


data FreeVars = FreeVars 
  { closureVars :: Ghc.VarSet  -- ^ Closure variables for this BCO
  , globalVars  :: S.Set Id  -- ^ References to global vars from this BCO.
  }

instance Monoid FreeVars where
  mempty = FreeVars Ghc.emptyVarSet S.empty
  (FreeVars cvs1 gvs1) `mappend` (FreeVars cvs2 gvs2) =
    FreeVars (cvs1 `Ghc.unionVarSet` cvs2) (gvs1 `S.union` gvs2)

closureVar :: Ghc.Id -> FreeVars
closureVar x = FreeVars (Ghc.unitVarSet x) S.empty

globalVar :: Id -> FreeVars
globalVar x = FreeVars Ghc.emptyVarSet (S.singleton x)

freshVar :: String -> (Name -> a) -> Trans a
freshVar nm f = do
  us <- genUnique
  return (f (freshName us (nm ++ tail (show (supplyValue us)))))

mbFreshLocal :: Maybe BcVar -> Trans BcVar
mbFreshLocal (Just v) = return v
mbFreshLocal Nothing = freshVar "%" (BcVar . mkLocalId)

-- | Create a new local 'Id' from a 'Ghc.Id'.
internCoreBndr :: CoreBndr -> Trans Id
internCoreBndr x = freshVar (Ghc.getOccString x) mkLocalId

-- | Translate a @body@ (using @CorePrep@ terminology) into bytecode.
--
-- If the context is 'RetC' will append a return statement or tail
-- call at the end.  Otherwise, the result is written into a register.
transBody ::
     CoreExpr  -- ^ The expression we're working on.
  -> LocalEnv  -- ^ The locally bound variables.  See 'LocalEnv'.
  -> FreeVarsIndex
  -> KnownLocs -- ^ Known register locations for some vars.
  -> Context x  -- ^ The code generation context.
  -> Trans (Bcis x, KnownLocs, FreeVars, Maybe BcVar)
     -- ^ Returns:
     --
     --  * The instructions corresponding to the expression
     --  * Modified register locations
     --  * Free variables (not top-level) of the expression.
     --  * The variable that the result is bound to (if needed).
     --

--transBody e _ _ _ _ | tracePpr e False = undefined
transBody (Ghc.Lit l) env _fvi locs ctxt = do
  (is, r) <- transLiteral l (contextVar ctxt)
  case ctxt of
    RetC -> return (is <*> insRet1 r,
                   locs, mempty, Nothing)
    BindC _ -> return (is, locs, mempty, Just r)

transBody (Ghc.Var x) env fvi locs0 ctxt = do
  (is0, r, eval'd, locs1, fvs) <- transVar x env fvi locs0 (contextVar ctxt)
  let is | eval'd = is0
         | otherwise = withFresh $ \l ->
                         is0 <*> insEval l r |*><*| mkLabel l
  case ctxt of
    RetC -> return (is <*> insRet1 r,
                   locs1, fvs, Nothing)
    BindC _ -> return (is, locs1, fvs, Just r)

transBody expr@(Ghc.App _ _) env fvi locs0 ctxt
 | Just (f, args) <- viewGhcApp expr
 = transApp f args env fvi locs0 ctxt

-- Special case for primitive conditions, i.e., (case x #< y of ...)
-- and such.
transBody (Ghc.Case scrut@(Ghc.App _ _) bndr ty alts) env0 fvi locs0 ctxt
  | Just (f, args) <- viewGhcApp scrut,
    Just (cond, ty) <- isCondPrimOp =<< isGhcPrimOpId f,
    isLength 2 args
  = case alts of
      [_,_] -> transBinaryCase cond ty args bndr alts env0 fvi locs0 ctxt
      [_] ->
        transBody build_bool_expr env0 fvi locs0 ctxt
 where
   build_bool_expr =
     Ghc.Case
       (Ghc.Case scrut bndr Ghc.boolTy
          [(DataAlt Ghc.trueDataCon,  [], Ghc.mkConApp Ghc.trueDataCon [])
          ,(DataAlt Ghc.falseDataCon, [], Ghc.mkConApp Ghc.falseDataCon [])])
       bndr
       ty
       alts
 
transBody (Ghc.Case scrut bndr _ty alts) env0 fvi locs0 ctxt =
  transCase scrut bndr alts env0 fvi locs0 ctxt

transBody (Ghc.Let (NonRec x (viewGhcApp -> Just (f, args@(_:_)))) body)
          env fvi locs0 ctxt
 | isGhcConWorkId f
  = do (bcis0, locs1, fvs0, Just r)
         <- transStore f args env fvi locs0 (BindC Nothing)
       let locs2 = updateLoc locs1 x (InVar r)
           env' = extendLocalEnv env x undefined
       (bcis1, locs3, fvs1, mb_r) <- withParentFun x $ transBody body env' fvi locs2 ctxt
       return (bcis0 <*> bcis1, locs3, fvs0 `mappend` fvs1, mb_r)

transBody (Ghc.Let bind body) env fvi locs0 ctxt = do
  (bcis, locs1, fvs, env') <- transBinds bind env fvi locs0
  (bcis', locs2, fvs', mb_r) <- transBody body env' fvi locs1 ctxt
  return (bcis <*> bcis', locs2, fvs `mappend` fvs', mb_r)

transBody (Ghc.Note _ e) env fvi locs ctxt = transBody e env fvi locs ctxt
transBody (Ghc.Cast e _) env fvi locs ctxt = transBody e env fvi locs ctxt
transBody (Ghc.Lam a e) env fvi locs ctxt
  | isTyVar a = transBody e env fvi locs ctxt
transBody e _ _ _ _ = error $ "transBody: " ++ showPpr e

-- | Translate a literal into bytecode.
--
-- Usually just amounts to loading a value from the constant pool.
-- Indices of the constant pool are determined in a separate pass.
transLiteral :: Ghc.Literal -> Maybe BcVar
             -> Trans (Bcis O, BcVar)
transLiteral lit mbvar = do
  rslt <- mbFreshLocal mbvar
  return (insLoadLit rslt (fromGhcLiteral lit), rslt)

fromGhcLiteral :: Ghc.Literal -> BcConst
fromGhcLiteral lit = case lit of
  Ghc.MachStr fs   -> CStr (unpackFS fs)
  Ghc.MachChar c   -> CChar c
  Ghc.MachInt n    -> CInt n
  Ghc.MachInt64 n  -> CInt64 n
  Ghc.MachWord n   -> CWord n
  Ghc.MachWord64 n -> CWord64 n
  Ghc.MachFloat r  -> CFloat r
  Ghc.MachDouble r -> CDouble r

-- | Translate a variable reference into bytecode.
--
-- Ensures that the variable is loaded into a register.  Uses
-- 'KnownLocs' to figure out the existing location (if any).
--
-- If the variable already has already been loaded into another
-- variable this creates a move instruction (which may later be
-- removed by the register allocator).
--
-- INVARIANT: @Closure-vars = dom(LocalEnv) - dom(KnownLocs)@
--
transVar ::
     CoreBndr
  -> LocalEnv
  -> FreeVarsIndex
  -> KnownLocs
  -> Maybe BcVar -- ^ @Just r <=>@ load variable into specified
                 -- register.
  -> Trans (Bcis O, BcVar, Bool, KnownLocs, FreeVars)
     -- ^ Returns:
     --
     -- * The instructions to load the variable
     -- 
     -- * The register it has been loaded into
     -- 
     -- * @True <=>@ the variable is known to be in WHNF (e.g., a
     -- top-level function).
     --
     -- * Updated 'KnownLocs'
     --
     -- * TODO
-- transVar x _ _ _ _ | trace ("transVar: " ++ showPpr x ++ " : "
--                            ++ showPpr (Ghc.idType x) ++ " / "
--                            ++ show (not (Ghc.isUnLiftedType (Ghc.idType x))))
--                     False = undefined
transVar x env fvi locs0 mr =
  case lookupLoc locs0 x of
    Just (InVar x') -> -- trace "inVAR" $
      return (mbMove mr x', fromMaybe x' mr, in_whnf, locs0, mempty)
    Just (InReg r) -> do -- trace "inREG" $
      x' <- mbFreshLocal mr
      return (insMove x' (BcReg r), x', in_whnf,
              updateLoc locs0 x (InVar x'), mempty)
    Just (Field p n) -> do -- trace "inFLD" $ do
      r <- mbFreshLocal mr
      return (insFetch r p n,
              r, in_whnf, updateLoc locs0 x (InVar r), mempty)
    Just Fwd -> do
      r <- mbFreshLocal mr
      return (insLoadBlackhole r, r, True, locs0, mempty)
    Just Self -> do
      r <- mbFreshLocal mr
      return (insLoadSelf r, r, True, locs0, mempty)
    Nothing
      | Just x' <- lookupLocalEnv env x -> do
          -- Note: To avoid keeping track of two environments we must
          -- only reach this case if the variable is bound outside the
          -- current closure.
          r <- mbFreshLocal mr
          -- Do not force @i@ -- must remain a thunk
          let i = expectJust "transVar" (Ghc.lookupVarEnv fvi x)
          return (insLoadFV r i, r, in_whnf,
                  updateLoc locs0 x (InVar r), closureVar x)

      | otherwise -> do  -- global variable
          this_mdl <- getThisModule
          let x' | isGhcConWorkId x,
                   not (Ghc.isNullarySrcDataCon (ghcIdDataCon x))
                 = dataConInfoTableId (ghcIdDataCon x)
                 | otherwise
                 = toplevelId this_mdl x
          r <- mbFreshLocal mr
          return (insLoadGbl r x', r, isGhcConWorkId x,  -- TODO: only if CAF
                  updateLoc locs0 x (InVar r), globalVar x')
    r -> error $ "transVar: unhandled case: " ++ show r ++ " "
              ++ showPpr x
 where
   in_whnf = Ghc.isUnLiftedType (Ghc.idType x)

transApp :: CoreBndr -> [CoreArg] -> LocalEnv -> FreeVarsIndex
         -> KnownLocs -> Context x
         -> Trans (Bcis x, KnownLocs, FreeVars, Maybe BcVar)
transApp f [] env fvi locs ctxt = transBody (Ghc.Var f) env fvi locs ctxt
transApp f args env fvi locs0 ctxt
  | Just p <- isGhcPrimOpId f, isLength 2 args 
  = do (is0, locs1, fvs, [r1, r2]) <- transArgs args env fvi locs0
       case () of
         _ | Just (op, ty) <- primOpToBinOp p
           -> do
             rslt <- mbFreshLocal (contextVar ctxt)
             maybeAddRet ctxt (is0 <*> insBinOp op ty rslt r1 r2)
                         locs1 fvs rslt
         _ | Just (cond, ty) <- isCondPrimOp p
           -> do
             -- A comparison op that does not appear within a 'case'.
             -- We must now fabricate a 'Bool' into the result.
             -- That is, `x ># y` is translated into:
             --
             -- >     if x > y then goto l1 else goto l2
             -- > l1: loadlit rslt, True
             -- >     goto l3:
             -- > l2: loadlit rslt, False
             -- > l3:
             rslt <- mbFreshLocal (contextVar ctxt)
             l1 <- freshLabel;  l2 <- freshLabel;  l3 <- freshLabel
             let is1 =  -- shape: O/O
                   catGraphsC (is0 <*> insBranch cond ty r1 r2 l1 l2)
                     [ mkLabel l1 <*> insLoadGbl rslt trueDataConId
                                  <*> insGoto l3,
                       mkLabel l2 <*> insLoadGbl rslt falseDataConId
                                  <*> insGoto l3]
                   |*><*| mkLabel l3
             maybeAddRet ctxt is1 locs1 fvs rslt
         _ | otherwise ->
             error $ "Unknown primop: " ++ showPpr p

  | isGhcConWorkId f  -- allocation
  = transStore f args env fvi locs0 ctxt
  | otherwise
  = do (is0, locs1, fvs0, regs) <- transArgs args env fvi locs0
       (is1, fr, _, locs2, fvs1)
          <- transVar f env fvi locs1 Nothing
       let is2 = is0 <*> is1
           fvs = fvs0 `mappend` fvs1
       case ctxt of
         RetC -> -- tailcall
           -- Ensure that tailcalls always use registers r0..r(N-1)
           -- for arguments.  This allows zero-copy function call.
           let is = is2 <*>
                      catGraphs [ insMove (BcReg n) r |
                                   (n,r) <- zip [0..] regs ]
               ins = is <*> insCall Nothing fr (map BcReg [0.. length regs - 1 ])
           in
           return (ins, locs2, fvs, Nothing)
         BindC mr ->  do
           -- need to ensure that x = O, so we need to emit
           -- a fresh label after the call
           r <- mbFreshLocal mr
           let ins = withFresh $ \l ->
                       is2 <*> insCall (Just (r, l)) fr regs |*><*| mkLabel l
           return (ins, locs2, fvs, Just r)
--error $ "transApp: " ++ showPpr f ++ " " ++ showPpr (Ghc.idDetails f)

-- | Generate code for loading the given function arguments into
-- registers.
transArgs :: [CoreArg] -> LocalEnv -> FreeVarsIndex -> KnownLocs
          -> Trans (Bcis O, KnownLocs, FreeVars, [BcVar])
transArgs args0 env fvi locs0 = go args0 emptyGraph locs0 mempty []
 where
   go [] bcis locs fvs regs = return (bcis, locs, fvs, reverse regs)
   go (arg:args) bcis locs fvs regs = do
     (bcis', locs', fvs', r) <- trans_arg arg locs
     go args (bcis <*> bcis') locs' (fvs `mappend` fvs') (r:regs)

   trans_arg (Ghc.Lit l) locs = do
     (bcis, r) <- transLiteral l Nothing
     return (bcis, locs, mempty, r)
   trans_arg (Ghc.Var x) locs = do
     (bcis, r, _, locs', fvs) <- transVar x env fvi locs Nothing
     return (bcis, locs', fvs, r)
   -- The boring cases
   trans_arg (Ghc.App x (Ghc.Type _)) locs = trans_arg x locs
   trans_arg (Lam a x) locs | isTyVar a    = trans_arg x locs
   trans_arg (Cast x _) locs               = trans_arg x locs
   trans_arg (Note _ x) locs               = trans_arg x locs

transStore :: CoreBndr -> [CoreArg] -> LocalEnv -> FreeVarsIndex
           -> KnownLocs -> Context x
           -> Trans (Bcis x, KnownLocs, FreeVars, Maybe BcVar)
transStore dcon args env fvi locs0 ctxt = do
  (bcis0, locs1, fvs, regs) <- transArgs args env fvi locs0
  (bcis1, con_reg, _, locs2, fvs')
    <- transVar dcon env fvi locs1 (contextVar ctxt)  -- XXX: loadDataCon or sth.
  rslt <- mbFreshLocal (contextVar ctxt)
  let bcis = (bcis0 <*> bcis1) <*> insAlloc rslt con_reg regs
  maybeAddRet ctxt bcis locs2 (fvs `mappend` fvs') rslt

transCase :: forall x.
             CoreExpr -> CoreBndr -> [CoreAlt]
          -> LocalEnv -> FreeVarsIndex -> KnownLocs
          -> Context x
          -> Trans (Bcis x, KnownLocs, FreeVars, Maybe BcVar)

-- Only a single case alternative.  This is just EVAL(bndr) and
-- possibly matching on the result.
transCase scrut bndr [(altcon, vars, body)] env0 fvi locs0 ctxt = do
  (bcis, locs1, fvs0, Just r) <- transBody scrut env0 fvi locs0 (BindC Nothing)
  let locs2 = updateLoc locs1 bndr (InVar r)
      env = extendLocalEnv env0 bndr undefined
  let locs3 = addMatchLocs locs2 r altcon vars
      env' = extendLocalEnvList env vars
  (bcis', locs4, fvs1, mb_r) <- transBody body env' fvi locs3 ctxt
  return (bcis <*> bcis', locs4, fvs0 `mappend` fvs1, mb_r)

-- Literal cases are handled specially by translating them into a
-- decision tree.  There's still room for improvement, though.  See
-- 'buildCaseTree' below.
transCase scrut bndr alts env0 fvi locs0 ctxt
 | isLitCase alts
 = do
  (bcis0, locs1, fvs0, Just reg) <- transBody scrut env0 fvi locs0 (BindC Nothing)
  -- bndr gets bound to the literal
  let locs2 = updateLoc locs1 bndr (InVar reg)
      env = extendLocalEnv env0 bndr undefined
  let (dflt, ty, tree) = buildCaseTree alts

  -- If the context requires binding to a variable, then we have to
  -- make sure all branches write their result into the same
  -- variable.
  ctxt' <- (case ctxt of
             RetC -> return RetC
             BindC mr -> BindC . Just <$> mbFreshLocal mr)
            :: Trans (Context x)

  end_label <- freshLabel

  let
    transArm :: CoreExpr -> Trans (Label, BcGraph C C, FreeVars)
    transArm bdy = do
      l <- freshLabel
      (bcis, _locs', fvs, _mb_var)
        <- transBody bdy env fvi locs2 ctxt'
      case ctxt' of
        RetC ->
          return (l, mkLabel l <*> bcis, fvs)
        BindC _ ->
          return (l, mkLabel l <*> bcis <*> insGoto end_label, fvs)

  (dflt_label, dflt_bcis, dflt_fvs) <- transArm dflt

  let
    build_branches :: CaseTree
                   -> Trans (Label, [BcGraph C C], FreeVars)

    build_branches (Leaf Nothing) = do
      return (dflt_label, [], mempty)
    build_branches (Leaf (Just expr)) = do
      (lbl, bci, fvs) <- transArm expr
      return (lbl, [bci], fvs)

    build_branches (Branch cmp lit true false) = do
      (true_lbl, true_bcis, true_fvs) <- build_branches true
      (false_lbl, false_bcis, false_fvs) <- build_branches false
      -- Ensure the code blocks are closed at the end
      (lit_bcis, lit_reg) <- transLiteral lit Nothing
      l <- freshLabel
      return (l, [mkLabel l <*> lit_bcis
                  <*> insBranch cmp ty reg lit_reg true_lbl false_lbl]
                 ++ true_bcis ++ false_bcis,
              true_fvs `mappend` false_fvs)

  case ctxt' of
    RetC -> do
      (l_root, bcis, fvs1) <- build_branches tree
      return ((bcis0 <*> insGoto l_root) `catGraphsC` bcis
               |*><*| dflt_bcis,
              locs1, mconcat [fvs0, fvs1, dflt_fvs], Nothing)
    BindC (Just r) -> do
      (l_root, bcis, fvs1) <- build_branches tree
      return ((bcis0 <*> insGoto l_root) `catGraphsC` bcis
                |*><*| dflt_bcis |*><*| mkLabel end_label,
              locs1, mconcat [fvs0, fvs1, dflt_fvs], Just r)

-- The general case
transCase scrut bndr alts env0 fvi locs0 ctxt = do
  (bcis, locs1, fvs0, Just r) <- transBody scrut env0 fvi locs0 (BindC Nothing)
  let locs2 = updateLoc locs1 bndr (InVar r)
  let env = extendLocalEnv env0 bndr undefined
  case ctxt of
    RetC -> do -- inss are closed at exit
      (alts, inss, fvs1) <- transCaseAlts alts r env fvi locs2 RetC
      return ((bcis <*> insCase CaseOnTag {- XXX: wrong -} r alts)
              `catGraphsC` inss,
              locs1, fvs0 `mappend` fvs1, Nothing)
    BindC mr -> do -- close inss' first
      error "UNTESTED"
      r1 <- mbFreshLocal mr
      (alts, inss, fvs1) <- transCaseAlts alts r env fvi locs2 (BindC (Just r1))
      let bcis' =
            withFresh $ \l ->
              let inss' = [ ins <*> insGoto l | ins <- inss ] in
              ((bcis <*> insCase CaseOnTag r alts) `catGraphsC` inss')
               |*><*| mkLabel l  -- make sure we're open at the end
      return (bcis', locs1, fvs0 `mappend` fvs1, Just r1)


data CaseTree
  = Leaf (Maybe CoreExpr)  -- execute this code (or default)
  | Branch CmpOp Ghc.Literal CaseTree CaseTree
    -- cmp + ty,  true_case, false_case

-- | Given a list of literal pattern matches, builds a balanced tree.
--
-- The goal is for this tree to select among the @N@ alternatives in
-- @log2(N)@ time.
--
-- TODO: Detect and take advantage of ranges.
buildCaseTree :: [CoreAlt]
              -> (CoreExpr, OpTy, CaseTree)
                 -- ^ Default code, comparison type, and other cases
buildCaseTree ((DEFAULT, [], dflt_expr):alts0) =
  assert alts_is_sorted $ (dflt_expr, ty, buildTree alts)
 where
   alts = map simpl_lit alts0

   alts_is_sorted =
     map fst (sortBy (comparing fst) alts) == map fst alts

   dflt = Leaf Nothing
   leaf x = Leaf (Just x)

   simpl_lit (LitAlt lit, [], expr) =
     assert (ghcLiteralType lit == ty) $ (lit, expr)

   ty = case alts0 of ((LitAlt l, _, _):_) -> ghcLiteralType l

   buildTree [(l, body)] =
     Branch CmpEq l (leaf body) dflt
   buildTree [(l1, body1), (l2,body2)] =
     Branch CmpEq l1 (leaf body1) (Branch CmpEq l2 (leaf body2) dflt)
   buildTree alts1 =
     let l = length alts1 in
     case splitAt (l `div` 2) alts1 of
       (lows, highs@((l, _):_)) ->
         Branch CmpGe l (buildTree highs) (buildTree lows)

isLitCase :: [CoreAlt] -> Bool
isLitCase ((DEFAULT, _, _):alts) = isLitCase alts
isLitCase ((LitAlt _, _, _):_) = True
isLitCase ((DataAlt _, _, _):_) = False
isLitCase [] = False

transCaseAlts ::
     [CoreAlt] -- ^ The case alternatives
  -> BcVar     -- ^ The variable we're matching on.
  -> LocalEnv -> FreeVarsIndex -> KnownLocs -> Context x
  -> Trans ([(BcTag, BlockId)], [BcGraph C x], FreeVars)
transCaseAlts alts match_var env fvi locs0 ctxt = do
  (targets, bcis, fvss) <- unzip3 <$>
    (forM alts $ \(altcon, vars, body) -> do
      let locs1 = addMatchLocs locs0 match_var altcon vars
          env' = extendLocalEnvList env vars
      (bcis, _locs2, fvs, _mb_var) <- transBody body env' fvi locs1 ctxt
      l <- freshLabel
      return ((dataConTag altcon, l), mkLabel l <*> bcis, fvs))
  return (targets, bcis, mconcat fvss)

-- | Translate a binary case (i.e., a two-arm branch).
transBinaryCase :: forall x.
                   BinOp -> OpTy -> [CoreArg] -> CoreBndr
                -> [CoreAlt] -> LocalEnv -> FreeVarsIndex
                -> KnownLocs -> Context x
                -> Trans (Bcis x, KnownLocs, FreeVars, Maybe BcVar)
transBinaryCase cond ty args bndr alts@[_,_] env0 fvi locs0 ctxt = do
  -- TODO: We may want to get the result of the comparison as a
  -- Bool.  In the True branch we therefore want to have:
  --
  -- > bndr :-> loadLit True
  --
  (bcis, locs1, fvs, [r1, r2]) <- transArgs args env0 fvi locs0
--  let locs2 = updateLoc locs1 bndr (InVar r)
  let env = extendLocalEnv env0 bndr undefined
  let match_var = error "There must be no binders in comparison binops"
  let (trueBody, falseBody) =
        case alts of
          [(DEFAULT, [], b1), (DataAlt c, [], b2)]
           | c == Ghc.trueDataCon  -> (b2, b1)
           | c == Ghc.falseDataCon -> (b1, b2)
          [(DataAlt c1, [], b1), (DataAlt _, [], b2)]
           | c1 == Ghc.trueDataCon  -> (b1, b2)
           | c1 == Ghc.falseDataCon -> (b2, b1)
  -- If the context requires binding to a variable, then we have to
  -- make sure both branches write their result into the same
  -- variable.
  ctxt' <- (case ctxt of
             RetC -> return RetC
             BindC mr -> BindC . Just <$> mbFreshLocal mr)
            :: Trans (Context x)

  let transUnaryConAlt body con_id = do
        let locs2 = updateLoc locs1 bndr (Global con_id)
        l <- freshLabel
        (bcis, _locs1, fvs1, _mb_var)
          <- transBody body env fvi locs2 ctxt'
        return (l, mkLabel l <*> bcis, fvs1)

  (tLabel, tBcis, tFvs) <- transUnaryConAlt trueBody trueDataConId
  (fLabel, fBcis, fFvs) <- transUnaryConAlt falseBody falseDataConId

  case ctxt' of
    RetC -> do
      return (bcis <*> insBranch cond ty r1 r2 tLabel fLabel
                   |*><*| tBcis |*><*| fBcis,
              locs1, mconcat [fvs, tFvs, fFvs], Nothing)
    BindC (Just r) -> do
      l <- freshLabel
      return (bcis <*> insBranch cond ty r1 r2 tLabel fLabel
                |*><*| tBcis <*> insGoto l
                |*><*| fBcis <*> insGoto l
                |*><*| mkLabel l,
              locs1, mconcat [fvs, tFvs, fFvs], Just r)

addMatchLocs :: KnownLocs -> BcVar -> AltCon -> [CoreBndr] -> KnownLocs
addMatchLocs locs _base_reg DEFAULT [] = locs
addMatchLocs locs _base_reg (LitAlt _) [] = locs
addMatchLocs locs base_reg (DataAlt _) vars =
  extendLocs locs [ (x, Field base_reg n) | (x,n) <- zip vars [1..] ]

dataConTag :: AltCon -> BcTag
dataConTag DEFAULT = DefaultTag
dataConTag (DataAlt dcon) = Tag $ Ghc.dataConTag dcon
dataConTag (LitAlt (Ghc.MachInt n)) = LitT n

-- | Append a @Ret1@ instruction if needed and return.
maybeAddRet :: Context x -> Bcis O -> KnownLocs -> FreeVars -> BcVar
            -> Trans (Bcis x, KnownLocs, FreeVars, Maybe BcVar)
maybeAddRet (BindC _) is locs fvs r =
  return (is, locs, fvs, Just r)
maybeAddRet RetC is locs fvs r =
  return (is <*> insRet1 r, locs, fvs, Nothing)

-- | Return a move instruction if target is @Just x@.
--
-- Redundant move instructions are eliminated by a later pass.
mbMove :: Maybe BcVar -> BcVar -> Bcis O
mbMove Nothing _ = emptyGraph
mbMove (Just r) r'
  | r == r'   = emptyGraph
  | otherwise = insMove r r'

isGhcConWorkId :: CoreBndr -> Bool
isGhcConWorkId x
  | Ghc.DataConWorkId _ <- Ghc.idDetails x = True
  | otherwise                              = False

ghcIdDataCon :: CoreBndr -> Ghc.DataCon
ghcIdDataCon x
  | Ghc.DataConWorkId dcon <- Ghc.idDetails x = dcon
  | otherwise = error "ghcIdDataCon: Id is not a DataConWorkId"

-- | Return @Just p@ iff input is a primitive operation.
isGhcPrimOpId :: CoreBndr -> Maybe Ghc.PrimOp
isGhcPrimOpId x
  | Ghc.PrimOpId p <- Ghc.idDetails x = Just p
  | otherwise                         = Nothing

-- TODO: This needs more thought.
primOpToBinOp :: Ghc.PrimOp -> Maybe (BinOp, OpTy)
primOpToBinOp primop =
  case primop of
    Ghc.IntAddOp -> Just (OpAdd, IntTy)
    Ghc.IntSubOp -> Just (OpSub, IntTy)
    Ghc.IntMulOp -> Just (OpMul, IntTy)
    Ghc.IntQuotOp -> Just (OpDiv, IntTy)
    Ghc.IntRemOp  -> Just (OpRem, IntTy)
    _ -> Nothing

isCondPrimOp :: Ghc.PrimOp -> Maybe (BinOp, OpTy)
isCondPrimOp primop =
  case primop of
    Ghc.IntGtOp -> Just (CmpGt, IntTy)
    Ghc.IntGeOp -> Just (CmpGe, IntTy)
    Ghc.IntEqOp -> Just (CmpEq, IntTy)
    Ghc.IntNeOp -> Just (CmpNe, IntTy)
    Ghc.IntLtOp -> Just (CmpLt, IntTy)
    Ghc.IntLeOp -> Just (CmpLe, IntTy)

    Ghc.CharGtOp -> Just (CmpGt, CharTy)
    Ghc.CharGeOp -> Just (CmpGe, CharTy)
    Ghc.CharEqOp -> Just (CmpEq, CharTy)
    Ghc.CharNeOp -> Just (CmpNe, CharTy)
    Ghc.CharLtOp -> Just (CmpLt, CharTy)
    Ghc.CharLeOp -> Just (CmpLe, CharTy)

    _ -> Nothing

-- | View expression as n-ary application.  The expression in function
-- position must be a variable.  Ignores type abstraction, notes and
-- coercions.
--
-- > viewApp [| f @a x y 42# |] = Just (f, [x, y, 42#])
-- > viewApp [| case e of ... |] = Nothing
-- > viewApp [| 42# x |] = Nothing
-- 
viewGhcApp :: CoreExpr -> Maybe (CoreBndr, [CoreArg])
viewGhcApp expr = go expr []
 where
   go (Ghc.Var v)          as = Just (v, as)
   go (Ghc.App f (Type _)) as = go f as
   go (Ghc.App f a)        as = go f (a:as)
   go (Ghc.Note _ e)       as = go e as
   go (Ghc.Cast e _)       as = go e as
   go (Ghc.Lam x e) as | isTyVar x = go e as
   go _ _ = Nothing

-- | View expression as n-ary abstraction.  Ignores type abstraction.
--
-- > viewGhcLam [| /\a b \x y -> exp |] = ([x, y], exp)
viewGhcLam :: CoreExpr -> ([CoreBndr], CoreExpr)
viewGhcLam expr = go expr []
 where
   go (Ghc.Lam x e) xs
     | isTyVar x = go e xs
     | otherwise = go e (x:xs)
   go (Cast e _) xs = go e xs
   go (Note _ e) xs = go e xs
   go e xs = (reverse xs, e)


-- | Look through noise in arguments.  Ignores things like type
-- applications, coercions, type abstractions and notes.
--
-- Requires the @CorePrep@ invariants to hold.
viewGhcArg :: CoreArg -> Either Ghc.Literal Ghc.Id
viewGhcArg (Ghc.Var x)              = Right x
viewGhcArg (Ghc.Lit l)              = Left l
viewGhcArg (Ghc.App x (Ghc.Type _)) = viewGhcArg x
viewGhcArg (Lam a x) | isTyVar a    = viewGhcArg x
viewGhcArg (Cast x _)               = viewGhcArg x
viewGhcArg (Note _ x)               = viewGhcArg x

ghcLiteralType :: Ghc.Literal -> OpTy
ghcLiteralType lit = case lit of
  Ghc.MachInt _    -> IntTy
  Ghc.MachInt64 _  -> Int64Ty
  Ghc.MachChar _   -> CharTy
  Ghc.MachWord _   -> WordTy
  Ghc.MachWord64 _ -> Word64Ty
  Ghc.MachStr _    -> AddrTy
  Ghc.MachFloat _  -> FloatTy
  Ghc.MachDouble _ -> DoubleTy
