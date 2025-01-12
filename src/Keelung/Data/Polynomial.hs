{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Polynomials over a field for use in constraint systems
module Keelung.Data.Polynomial
  ( Poly,
    buildEither,
    singleVar,
    bind,
    vars,
    varSize,
    coeffs,
    mergeCoeffs,
    constant,
    view,
    renumberVars,
    evaluate,
    addConstant,
    multiplyBy,
    --
    delete,
    merge,
    negate,
    substWithIntMap,
  )
where

import Control.DeepSeq (NFData)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet (IntSet)
import Data.Serialize (Serialize)
import GHC.Generics (Generic)
import Keelung.Syntax (Var)
import Prelude hiding (negate)
import Prelude qualified

-- | A Poly is a polynomial of the form @c + c₀x₀ + c₁x₁ ... cₙxₙ = 0@
--
--   Invariances:
--
--      * The coefficients are non-zone
--      * The degree of the polynomial is 1 (there's at least one variable)
data Poly n = Poly !n !(IntMap n)
  deriving (Functor, Generic, NFData)

instance Serialize n => Serialize (Poly n)

-- | Two polynomials are the same, if they have the same coefficients and variables
-- or one is the negation of the other
instance (Eq n, Num n) => Eq (Poly n) where
  (Poly c1 v1) == (Poly c2 v2) =
    (c1 == c2 && v1 == v2)
      || (c1 == -c2 && v1 == IntMap.map Prelude.negate v2)

instance (Ord n, Num n) => Ord (Poly n) where
  compare (Poly c x) (Poly d y) =
    if Poly c x == Poly d y
      then EQ
      else
        let numOfTerms1 = IntMap.size x + if c == 0 then 0 else 1
            numOfTerms2 = IntMap.size y + if d == 0 then 0 else 1
         in compare (numOfTerms1, x, c) (numOfTerms2, y, d)

instance (Show n, Ord n, Eq n, Num n) => Show (Poly n) where
  show (Poly n xs)
    | n == 0 =
        if firstSign == " + "
          then concat restOfTerms
          else "- " ++ concat restOfTerms
    | otherwise = concat (show n : termStrings)
    where
      (firstSign, restOfTerms) = case concatMap printTerm $ IntMap.toList xs of
        [] -> error "[ panic ] Empty PolyG"
        (x' : xs') -> (x', xs')

      termStrings = concatMap printTerm $ IntMap.toList xs
      -- return a pair of the sign ("+" or "-") and the string representation
      printTerm :: (Show n, Ord n, Eq n, Num n) => (Var, n) -> [String]
      printTerm (x, c)
        | c == 0 = error "printTerm: coefficient of 0"
        | c == 1 = [" + ", "$" ++ show x]
        | c == -1 = [" - ", "$" ++ show x]
        | c < 0 = [" - ", show (Prelude.negate c) ++ "$" ++ show x]
        | otherwise = [" + ", show c ++ "$" ++ show x]

-- | Create a polynomial from a constant and a list of coefficients.
--   Coefficients of 0 are discarded.
buildEither :: (Num n, Eq n) => n -> [(Var, n)] -> Either n (Poly n)
buildEither c xs =
  let xs' = IntMap.filter (0 /=) $ IntMap.fromListWith (+) xs
   in if IntMap.null xs'
        then Left c
        else Right (Poly c xs')

-- | Create a polynomial from a constant and a list of coefficients.
--   Coefficients of 0 are discarded.
buildEither' :: (Num n, Eq n) => n -> IntMap n -> Either n (Poly n)
buildEither' c xs =
  let xs' = IntMap.filter (0 /=) xs
   in if IntMap.null xs'
        then Left c
        else Right (Poly c xs')

-- | Create a polynomial from a constant and a list of coefficients.
--   Coefficients of 0 are discarded.
buildMaybe :: (Num n, Eq n) => n -> IntMap n -> Maybe (Poly n)
buildMaybe c xs =
  let xs' = IntMap.filter (0 /=) xs
   in if IntMap.null xs'
        then Nothing
        else Just (Poly c xs')

-- | Create a simple binding of a variable to a value
bind :: Num n => Var -> n -> Poly n
bind x n = Poly n (IntMap.singleton x (-1))

-- | Create a polynomial from a single variable
singleVar :: Num n => Var -> Poly n
singleVar x = Poly 0 (IntMap.singleton x 1)

-- | Return the set of variables.
vars :: Poly n -> IntSet
vars = IntMap.keysSet . coeffs

-- | Number of variables.
varSize :: Poly n -> Int
varSize = IntMap.size . coeffs

-- | Return the mapping of variables to coefficients.
coeffs :: Poly n -> IntMap n
coeffs (Poly _ xs) = xs

-- | Merge coefficients of the same variable by adding them up
mergeCoeffs :: (Num n, Eq n) => IntMap n -> IntMap n -> IntMap n
mergeCoeffs xs ys = IntMap.filter (0 /=) $ IntMap.unionWith (+) xs ys

-- | Return the constant.
constant :: Poly n -> n
constant (Poly c _) = c

-- | View pattern for 'Poly'
view :: Poly n -> (n, IntMap n)
view (Poly c xs) = (c, xs)

-- | For renumbering the variables.
renumberVars :: (Var -> Var) -> Poly n -> Poly n
renumberVars f (Poly c xs) = Poly c (IntMap.mapKeys f xs)

-- | Given an assignment of variables, return the value of the polynomial.
evaluate :: (Num n, Eq n) => Poly n -> IntMap n -> n
evaluate (Poly c xs) assignment =
  IntMap.foldlWithKey
    (\acc k v -> (v * IntMap.findWithDefault 0 k assignment) + acc)
    c
    xs

-- | Delete a variable from the polynomial.
delete :: (Num n, Eq n) => Var -> Poly n -> Maybe (Poly n)
delete x (Poly c xs) = buildMaybe c (IntMap.delete x xs)

-- | Merge two polynomials.
merge :: (Num n, Eq n) => Poly n -> Poly n -> Either n (Poly n)
merge (Poly c xs) (Poly d ys) = case buildEither' (c + d) (IntMap.filter (0 /=) $ IntMap.unionWith (+) xs ys) of
  Left n -> Left n
  Right xs' -> Right xs'

-- | Negate a polynomial.
negate :: (Num n, Eq n) => Poly n -> Poly n
negate (Poly c xs) = Poly (-c) (fmap Prelude.negate xs)

-- | Substitute variables in a 'Poly' with an 'IntMap' of values.
--   Returns a boolean indicating whether the substitution changed the polynomial.
substWithIntMap :: (Num n, Eq n) => Poly n -> IntMap n -> (Either n (Poly n), Bool)
substWithIntMap (Poly c xs) bindings =
  let (c', xs', changed) =
        IntMap.foldlWithKey'
          ( \(is, us, flag) var coeff ->
              case IntMap.lookup var bindings of
                Nothing -> (is, IntMap.insert var coeff us, flag)
                Just val -> ((coeff * val) + is, us, True)
          )
          (c, mempty, False)
          xs
   in (buildEither' c' xs', changed)

addConstant :: Num n => n -> Poly n -> Poly n
addConstant d (Poly c xs) = Poly (c + d) xs

multiplyBy :: (Eq n, Num n) => n -> Poly n -> Either n (Poly n)
multiplyBy 0 (Poly _ _) = Left 0
multiplyBy d (Poly c xs) = Right (Poly (c * d) (fmap (* d) xs))