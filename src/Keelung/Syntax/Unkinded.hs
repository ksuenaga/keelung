{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Keelung.Syntax.Unkinded where

import Control.Arrow (left)
import Control.Monad.Except
import Control.Monad.State
import Data.IntSet (IntSet)
import Data.Serialize
import Data.Typeable
import GHC.Generics (Generic)
import Keelung.Error
import qualified Keelung.Monad as S
import Keelung.Syntax (Addr, Heap, Var)
import qualified Keelung.Syntax as S

class Flatten a b where
  flatten :: a -> b

data Value n = Number n | Boolean Bool | Unit
  deriving (Generic)

instance Flatten (S.Value kind n) (Value n) where
  flatten (S.Number n) = Number n
  flatten (S.Boolean b) = Boolean b
  flatten S.UnitVal = Unit

instance Serialize n => Serialize (Value n)

-- data Ref = Variable Var | Array Addr
--   deriving (Generic)

data VarRef
  = NumVar Var
  | BoolVar Var
  | UnitVar Var
  deriving (Generic)

instance Serialize VarRef

data ArrRef = Arr Addr ArrKind
  deriving (Generic)

instance Serialize ArrRef

data ArrKind = ArrOf | ArrOfNum | ArrOfBool | ArrOfUnit
  deriving (Generic)

instance Serialize ArrKind

data Ref
  = VarRef VarRef
  | ArrRef ArrRef
  deriving (Generic)

instance Serialize Ref

instance Flatten (S.Ref ('S.V kind)) VarRef where
  flatten (S.Variable ref)
    | typeOf ref == typeRep (Proxy :: Proxy (S.Ref ('S.V 'S.Bool))) = BoolVar ref
    | typeOf ref == typeRep (Proxy :: Proxy (S.Ref ('S.V 'S.Num))) = NumVar ref
    | otherwise = UnitVar ref

data Expr n
  = Val (Value n)
  | Var VarRef
  | Add (Expr n) (Expr n)
  | Sub (Expr n) (Expr n)
  | Mul (Expr n) (Expr n)
  | Div (Expr n) (Expr n)
  | Eq (Expr n) (Expr n)
  | And (Expr n) (Expr n)
  | Or (Expr n) (Expr n)
  | Xor (Expr n) (Expr n)
  | BEq (Expr n) (Expr n)
  | IfThenElse (Expr n) (Expr n) (Expr n)
  | ToBool (Expr n)
  | ToNum (Expr n)
  deriving (Generic)

instance Typeable kind => Flatten (S.Expr kind n) (Expr n) where
  flatten (S.Val val) = Val (flatten val)
  flatten (S.Var ref) = Var (flatten ref)
  flatten (S.Add x y) = Add (flatten x) (flatten y)
  flatten (S.Sub x y) = Sub (flatten x) (flatten y)
  flatten (S.Mul x y) = Mul (flatten x) (flatten y)
  flatten (S.Div x y) = Div (flatten x) (flatten y)
  flatten (S.Eq x y) = Eq (flatten x) (flatten y)
  flatten (S.And x y) = And (flatten x) (flatten y)
  flatten (S.Or x y) = Or (flatten x) (flatten y)
  flatten (S.Xor x y) = Xor (flatten x) (flatten y)
  flatten (S.BEq x y) = BEq (flatten x) (flatten y)
  flatten (S.IfThenElse c t e) = IfThenElse (flatten c) (flatten t) (flatten e)
  flatten (S.ToBool x) = ToBool (flatten x)
  flatten (S.ToNum x) = ToNum (flatten x)

instance Serialize n => Serialize (Expr n)

data Elaborated n = Elaborated
  { -- | The resulting 'Expr'
    elabExpr :: !(Maybe (Expr n)),
    -- | The state of computation after elaboration
    elabComp :: Computation n
  }
  deriving (Generic)

instance Typeable kind => Flatten (S.Elaborated kind n) (Elaborated n) where
  flatten (S.Elaborated e c) = Elaborated (fmap flatten e) (flatten c)

instance Serialize n => Serialize (Elaborated n)

-- | An Assignment associates an expression with a reference
data Assignment n = Assignment VarRef (Expr n)
  deriving (Generic)

instance Typeable kind => Flatten (S.Assignment kind n) (Assignment n) where
  flatten (S.Assignment r e) = Assignment (flatten r) (flatten e)

instance Serialize n => Serialize (Assignment n)

-- | Data structure for elaboration bookkeeping
data Computation n = Computation
  { -- Counter for generating fresh variables
    compNextVar :: Int,
    -- Counter for allocating fresh heap addresses
    compNextAddr :: Int,
    -- Variables marked as inputs
    compInputVars :: IntSet,
    -- Heap for arrays
    compHeap :: Heap,
    -- Assignments
    compNumAsgns :: [Assignment n],
    compBoolAsgns :: [Assignment n],
    -- Assertions are expressions that are expected to be true
    compAssertions :: [Expr n]
  }
  deriving (Generic)

instance Flatten (S.Computation n) (Computation n) where
  flatten (S.Computation nextVar nextAddr inputVars heap asgns bsgns asgns') =
    Computation nextVar nextAddr inputVars heap (map flatten asgns) (map flatten bsgns) (map flatten asgns')

instance Serialize n => Serialize (Computation n)

type Comp n = StateT (Computation n) (Except Error)

-- | How to run the 'Comp' monad
runComp :: Computation n -> Comp n a -> Either Error (a, Computation n)
runComp comp f = runExcept (runStateT f comp)

-- | An alternative to 'elaborate' that returns '()' instead of 'Expr'
elaborate_ :: Comp n () -> Either String (Elaborated n)
elaborate_ prog = do
  ((), comp') <- left show $ runComp (Computation 0 0 mempty mempty mempty mempty mempty) prog
  return $ Elaborated Nothing comp'

elaborate :: Comp n (Expr n) -> Either String (Elaborated n)
elaborate prog = do
  (expr, comp') <- left show $ runComp (Computation 0 0 mempty mempty mempty mempty mempty) prog
  return $ Elaborated (Just expr) comp'

-- | Allocate a fresh variable.
allocVar :: Comp n Int
allocVar = do
  index <- gets compNextVar
  modify (\st -> st {compNextVar = succ index})
  return index

assignNum :: VarRef -> Expr n -> Comp n ()
assignNum var e = modify' $ \st -> st {compNumAsgns = Assignment var e : compNumAsgns st}

assignBool :: VarRef -> Expr n -> Comp n ()
assignBool var e = modify' $ \st -> st {compBoolAsgns = Assignment var e : compNumAsgns st}