{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE MagicHash #-}

module Fractions where

import Control.Applicative
import Control.Monad.Zip
import Data.Bits
import Data.Foldable
import Data.Ratio
import Data.Semigroup
import Data.Traversable
import Data.Word
import GHC.Real (Ratio((:%)))
import GHC.Types (Int(..))
import GHC.Integer.Logarithms
import Linear (Additive(..))
import Prelude hiding (foldr, foldl1, all, any)

type Z = Integer

-- | An integral domain has no zero divisors.
--
-- We care primarily about "nice integral domains" where we can compare for equality
class (Eq a, Num a) => IntegralDomain a where

instance IntegralDomain Integer
instance (IntegralDomain a, Integral a) => IntegralDomain (Ratio a)
instance IntegralDomain Float
instance IntegralDomain Double

--------------------------------------------------------------------------------
-- * Polynomials
--------------------------------------------------------------------------------

data P a = P [a]
  deriving (Show, Eq, Foldable, Functor)

zeroes :: Num a => Int -> [a] -> [a]
zeroes 0 xs = xs
zeroes n xs = 0 : zeroes (n-1) xs

xTimes :: Num a => P a -> P a
xTimes (P []) = P []
xTimes (P as) = P (0:as)

(*^) :: IntegralDomain a => a -> P a -> P a
0 *^ _ = 0
a *^ P bs = P $ map (a*) bs

lift :: IntegralDomain a => a -> P a
lift 0 = P []
lift a = P [a]

-- evaluate a polynomial at 0
at0 :: Num a => P a -> a
at0 (P (a:_)) = a
at0 (P [])    = 0

-- evaluate using Horner's rule
at :: Num a => a -> P a -> a
at x (P as) = foldr (\a r -> a + x*r) 0 as

instance IntegralDomain a => Semigroup (P a) where
  P as <> x = foldr (\a r -> lift a + x*r) 0 as

instance IntegralDomain a => Monoid (P a) where
  mempty = P [0,1]
  mappend = (<>)

instance IntegralDomain a => Num (P a) where
  P as0 + P bs0 = P $ go 0 as0 bs0 where
    go n (a:as) (b:bs) = case a + b of
      0 -> go (n + 1) as bs
      c -> zeroes n (c : go 0 as bs)
    go _ [] [] = []
    go n [] bs = zeroes n bs
    go n as [] = zeroes n as
  P as0 - P bs0 = P $ go 0 as0 bs0 where
    go n (a:as) (b:bs) = case a - b of
      0 -> go (n + 1) as bs
      c -> zeroes n (c : go 0 as bs)
    go _ [] [] = []
    go n [] bs = zeroes n (map negate bs)
    go n as [] = zeroes n as
  P as0 * bs = go as0 where
    go [] = P []
    go (0:as) = xTimes (go as)
    go (a:as) = a *^ bs + xTimes (go as)
  negate (P as) = P (map negate as)
  abs xs = signum xs * xs
  signum (P []) = P []
  signum (P as) = P [signum (last as)]
  fromInteger 0 = P []
  fromInteger n = P [fromInteger n]

instance IntegralDomain a => IntegralDomain (P a)

--------------------------------------------------------------------------------
-- * Extended Rationals
--------------------------------------------------------------------------------

-- | Extended, unreduced, field of fractions
--
-- @
-- V a = Frac a ∪ {∞,⊥}
-- @
--
-- @
-- ⊥ = V 0 0
-- ∞ = V a 0, a /= 0
-- @
data V a = V !a !a
  deriving (Show, Functor, Traversable)

instance Foldable V where
  foldMap k (V a b) = k a `mappend` k b
  foldl1 k (V a b) = k a b

mediant :: Num a => V a -> V a -> V a
mediant (V a b) (V c d) = V (a + c) (b + d)

indeterminate :: IntegralDomain a => V a -> Bool
indeterminate (V a b) = a == 0 && b == 0

infinite :: IntegralDomain a => V a -> Bool
infinite (V a b) = a /= 0 && b == 0

instance (IntegralDomain a, Eq a) => Eq (V a) where
  V a b == V c d = b /= 0 && d /= 0 && a*d == b*c
  V a b /= V c d = b /= 0 && d /= 0 && a*d /= b*c

instance (IntegralDomain a, Ord a) => Ord (V a) where
  compare (V a b) (V c d)
    | b * d == 0 = GT -- undefined
    | otherwise = compare (a * d) (b * c)
  V a b <= V c d = b * d /= 0 && a*d <= b*c
  V a b <  V c d = b * d /= 0 && a*d <  b*c
  V a b >  V c d = b * d /= 0 && a*d >  b*c
  V a b >= V c d = b * d /= 0 && a*d >= b*c
  min u@(V a b) v@(V c d)
    | b * d == 0 = V (hard a b c d) 0
    | a*d <= b*c = u
    | otherwise  = v
    where -- min ∞ ∞ = ∞, min ∞ a = ⊥, min ∞ b = ⊥
      hard 0 0 _ _ = 0
      hard _ _ 0 0 = 0
      hard _ 0 _ _ = 0
      hard _ _ _ 0 = 0
      hard _ _ _ _ = 1 -- min ∞ ∞ = ∞
  max u@(V a b) v@(V c d)
    | b * d == 0 = V (hard a b c d) 0
    | a*d <= b*c = v
    | otherwise  = u
    where -- max ∞ ∞ = ∞, max ∞ a = ⊥, max ∞ b = ⊥
      hard 0 0 _ _ = 0
      hard _ _ 0 0 = 0
      hard _ 0 _ _ = 0
      hard _ _ _ 0 = 0
      hard _ _ _ _ = 1 -- max ∞ ∞ = ∞

minmax :: (IntegralDomain a, Ord a) => V a -> V a -> (V a, V a)
minmax u@(V a b) v@(V c d)
  | b * d == 0, w <- V (hard a b c d) 0 = (w,w)
  | a*d <= b*c = (u,v)
  | otherwise  = (v,u)
  where -- max ∞ ∞ = ∞, max ∞ a = ⊥, max ∞ b = ⊥
    hard 0 0 _ _ = 0
    hard _ _ 0 0 = 0
    hard _ 0 _ _ = 0
    hard _ _ _ 0 = 0
    hard _ _ _ _ = 1 -- max ∞ ∞ = ∞

instance IntegralDomain a => Num (V a) where
  V a b + V c d = V (if b*d == 0 then hard a b c d else a*d+b*c) (b*d) where
    hard _ _ 0 0 = 0 -- ⊥ + a = ⊥
    hard 0 0 _ _ = 0 -- a + ⊥ = ⊥
    hard _ 0 _ 0 = 0 -- ∞ + ∞ = ⊥
    hard _ _ _ _ = 1 -- ∞ - a = ∞
                     -- a - ∞ = ∞

  V a b - V c d = V (if b*d == 0 then hard a b c d else a*d-b*c) (b*d) where
    hard _ _ 0 0 = 0 -- ⊥ - a = ⊥
    hard 0 0 _ _ = 0 -- a - ⊥ = ⊥
    hard _ 0 _ 0 = 0 -- ∞ - ∞ = ⊥
    hard _ _ _ _ = 1 -- ∞ - a = ∞
                     -- a - ∞ = ∞

  V a b * V c d = V (if b*d == 0 then hard a b c d else a*c) (b*d) where
    hard _ _ 0 0 = 0 -- a * ⊥ = ⊥
    hard 0 0 _ _ = 0 -- ⊥ * a = ⊥
    hard _ 0 0 _ = 0 -- ∞ * 0 = ⊥
    hard 0 _ _ 0 = 0 -- 0 * ∞ = ⊥
    hard _ _ _ _ = 1 -- ∞ * ∞ = ∞

  abs xs = signum xs * xs
  signum = fmap signum
  fromInteger n = V (fromInteger n) 1

-- |
-- @
-- recip ⊥ = ⊥
-- recip ∞ = 0
-- recip 0 = ∞
-- recip (V a b) = V b a
-- @
instance IntegralDomain a => Fractional (V a) where
  recip (V a b) = V b a
  p / q = p * recip q
  fromRational r = V (fromInteger (numerator r)) (fromInteger (denominator r))

instance (Integral a, IntegralDomain a) => Real (V a) where
  toRational (V k n) = toInteger k % toInteger n -- blows up on indeterminate and ∞ forms

instance (Integral a, IntegralDomain a) => RealFrac (V a) where
  properFraction (V a b) = case divMod a b of
    (q, r) -> (fromIntegral q, V r b)

instance IntegralDomain a => IntegralDomain (V a)

--------------------------------------------------------------------------------
-- * Rescaling Results
--------------------------------------------------------------------------------

integerLog2 :: Integer -> Int
integerLog2 i = I# (integerLog2# i)

-- | divide out all residual powers of 2
--
-- Used for rescaling @V Z@, @M Z@, @T Z@, and @Q Z@ intermediate results.
scale :: (Foldable f, Functor f) => f Z -> f Z
scale xs
  | n <= 1 = xs -- lsb is a 1, or we're 0, keep original
  | s <- integerLog2 n = fmap (`unsafeShiftR` s) xs
  where
    m = foldl1 (.|.) xs -- of all the bits
    n = m .&. negate m  -- keep least significant set bit

-- | divide out all residual powers of 2
--
-- Used for rescaling @V (P Z)@, @M (P Z)@, @T (P Z)@, @Q (P Z)@ intermediate results.
scaleP :: (Foldable f, Functor f, Foldable p, Functor p) => f (p Z) -> f (p Z)
scaleP xs
  | n <= 1 = xs -- lsb is a 1, or we're 0, keep original
  | s <- integerLog2 n = fmap (`unsafeShiftR` s) <$> xs
  where
    m = (foldl'.foldl') (.|.) 0 xs -- of all the bits
    n = m .&. negate m  -- keep least significant set bit

--------------------------------------------------------------------------------
-- * Decimal reductions
--------------------------------------------------------------------------------

-- |
--
-- Z w/ Z mod 10 maintained in parallel
--
-- optimized for reduction in scale by factors of 10, which arise in decimal expansion.
data Dec = Dec !Integer {-# UNPACK #-} !Word8
  deriving Show

-- TODO: figure out a fancy bit hack
rem10 :: Word8 -> Word8
rem10 x = rem x 10

instance Eq Dec where
  Dec a _ == Dec c _ = a == c

instance Ord Dec where
  Dec a _ `compare` Dec c _ = compare a c

instance Num Dec where
  Dec a b + Dec c d = Dec (a + c) (rem10 $ b + d)
  Dec a b - Dec c d = Dec (a - c) (rem10 $ b - d)
  Dec a b * Dec c d = Dec (a * c) (rem10 $ b * d)
  abs x@(Dec a b)
    | a < 0 = Dec (negate a) (10 - b)
    | otherwise = x
  signum (Dec a _) = fromInteger (signum a)
  fromInteger i = Dec i (fromInteger $ rem i 10)

instance Real Dec where
  toRational (Dec a _) = toRational a

instance Enum Dec where
  fromEnum (Dec a _) = fromInteger a
  toEnum = fromIntegral
  succ (Dec a b) = Dec (succ a) (rem10 $ b + 1)
  pred (Dec a b) = Dec (pred a) (rem10 $ b - 1)

-- div10 ms = unsafeShiftR (ms * 205) 11 -- computes div10 legally for [0,2047] in a 22 bit+ register

instance Integral Dec where
  toInteger (Dec a _) = a
  quot (Dec a _) (Dec c _) = fromInteger (quot a c)
  rem (Dec a _) (Dec c _) = fromInteger (rem a c)
  quotRem (Dec a _) (Dec c _) = case quotRem a c of
    (e, f) -> (fromInteger e, fromInteger f)
  div (Dec a _) (Dec c _) = fromInteger (div a c)
  mod (Dec a _) (Dec c _) = fromInteger (mod a c)
  divMod (Dec a _) (Dec c _) = case divMod a c of
    (e, f) -> (fromInteger e, fromInteger f)

instance IntegralDomain Dec

-- remove common factors of 10
scale10 :: (Foldable f, Functor f) => f Dec -> f Dec
scale10 xs
  | any (\(Dec _ b) -> b /= 0) xs = xs
  | all (\(Dec a _) -> a == 0) xs = xs
  | otherwise = scale10 $ fmap (`div` 10) xs

--------------------------------------------------------------------------------
-- * Intervals
--------------------------------------------------------------------------------

-- data I
--   = U               -- the entire universe R∞
--   | I {-# UNPACK #-} !(V Z) {-# UNPACK #-} !(V Z) -- a closed interval

class Columns f where
  columns :: Semigroup m => (V a -> m) -> f a -> m

instance Columns V where
  columns f v = f v

--------------------------------------------------------------------------------
-- * Contractivity
--------------------------------------------------------------------------------

data SigmaS = SigmaN | SigmaZ | SigmaP | SigmaI deriving (Eq)

instance Semigroup SigmaS where
  SigmaP <> SigmaP = SigmaP
  SigmaN <> SigmaN = SigmaN
  SigmaZ <> x      = x
  x      <> SigmaZ = x
  SigmaN <> SigmaP = SigmaI
  SigmaP <> SigmaN = SigmaI
  SigmaI <> _      = SigmaI
  _      <> SigmaI = SigmaI

class Sigma a where
  sigma :: a -> SigmaS

  default sigma :: (Columns f) => f a -> SigmaS
  sigma v = columns sigma v

instance Sigma Z where
  sigma n = case compare n 0 of
    LT -> SigmaN
    EQ -> SigmaZ
    GT -> SigmaP

instance Sigma (P Z) where
  sigma (P as) | all (== 0) as = SigmaZ
               | all (>= 0) as = SigmaP
               | all (<= 0) as = SigmaN
               | otherwise     = SigmaI

instance Sigma a => Sigma (V a) where
  sigma (V a b) = case sigma a of
    SigmaI -> SigmaI
    SigmaN | sigma b == SigmaN -> SigmaN
           | sigma b == SigmaZ -> SigmaN
           | otherwise         -> SigmaI
    SigmaP | sigma b == SigmaP -> SigmaP
           | sigma b == SigmaZ -> SigmaP
           | otherwise         -> SigmaI
    SigmaZ                    -> sigma b

instance (Sigma a) => Sigma (M a)
instance (Sigma a) => Sigma (Q a)
instance (Sigma a) => Sigma (T a)

pos :: Sigma a => a -> Bool
pos a = let s = sigma a in
  s == SigmaN || s == SigmaP

--------------------------------------------------------------------------------
-- * r((1+√5)/2) = r(√5)
--
-- Fib a b * Fib c d ≡ (ax+b)*(cx+d) (mod x^2-x-1)
--------------------------------------------------------------------------------

-- |
-- @Fib a b :: Fib r@ denotes @aΦ + b@ ∈ r(Φ)
data Fib a = Fib !a !a
  deriving (Show, Functor, Foldable, Traversable, Eq)

instance (IntegralDomain a, Ord a) => Ord (Fib a) where
  compare (Fib a b) (Fib c d) = case compare a c of
    LT | b <= d    -> LT
       | otherwise -> go compare (a-c) (b-d)
    EQ -> compare b d
    GT | b >= d    -> GT
       | otherwise -> go (flip compare) (a-c) (b-d)
   where
     -- convert to a(√5) and compare squares
     go k e f = k (sq (e+2*f)) (5*sq e)
     sq x = x*x

instance Num a => Num (Fib a) where
  Fib a b + Fib c d = Fib (a + c) (b + d)
  -- Φ^2 = Φ+1, so (aΦ+b)(cΦ+d) = ac(Φ+1) + (ad+bc)Φ + bd == (ac+ad+bc)Φ + (ac+bd)
  Fib a b * Fib c d = Fib (a*(c + d) + b*c) (a*c + b*d)
  Fib a b - Fib c d = Fib (a - c) (b - d)
  negate (Fib a b) = Fib (negate a) (negate b)
  abs x = x
  signum _ = Fib 0 1 -- with our current constraints this is all we can say, not willing to give up instances to do better.
  fromInteger n = Fib 0 (fromInteger n)

instance Fractional a => Fractional (Fib a) where
  recip (Fib a b) = Fib (-a/d) ((a+b)/d) where
    d = b*b + a*b - a*a
  fromRational r = Fib 0 (fromRational r)

instance Applicative Fib where
  pure a = Fib a a
  Fib a b <*> Fib c d = Fib (a c) (b d)

instance Monad Fib where
  return a = Fib a a
  Fib a b >>= f = Fib a' b' where
    Fib a' _ = f a
    Fib _ b' = f b

instance MonadZip Fib where
  mzipWith f (Fib a b) (Fib c d) = Fib (f a c) (f b d)
  munzip (Fib (a,b) (c,d)) = (Fib a c, Fib b d)

instance Additive Fib where
  zero = Fib 0 0
  (^+^) = (+)
  (^-^) = (-)

instance IntegralDomain a => IntegralDomain (Fib a)

class IntegralDomain a => Golden a where
  -- | (1 + sqrt 5)/2
  phi :: a
  default phi :: Floating a => a
  phi = (1 + sqrt 5)*0.5

  -- |
  -- @
  -- sqrt 5 = phi + iphi
  -- @
  sqrt5 :: a
  sqrt5 = 2*phi - 1

  -- |
  -- @
  -- phi * iphi = 1
  -- @
  iphi :: a
  iphi = phi - 1

instance IntegralDomain a => Golden (Fib a) where
  phi = Fib 1 0

instance Golden Float
instance Golden Double
instance Golden E
instance Golden a => Golden (V a) where
  phi = V phi 1

unfib :: Golden a => Fib a -> a
unfib (Fib a b) = a*phi + b

-- fast fibonacci transform
fib :: IntegralDomain a => Integer -> a
fib n
  | n >= 0 = getPhi (phi ^ n)
  | otherwise = getPhi (iphi ^ negate n)

getPhi :: Fib a -> a
getPhi (Fib a _) = a

-- |
-- redundant digits in base Φ
-- @
-- dphin = scaleP $ digit phi (negate iphi)
-- dphip = scaleP $ digit phi iphi
-- @
dphin, dphip :: M (Fib Z)
dphin = M (Fib 1 0) (Fib 0 0) (Fib 0 1) (Fib 1 1)
dphip = M (Fib 1 1) (Fib 0 1) (Fib 0 0) (Fib 1 0)

--------------------------------------------------------------------------------
-- * Affine transformations
--------------------------------------------------------------------------------

-- | @'Af' a b@ represents a function @f@ such that
--
-- @
-- f(x) = ax + b
-- @
--
-- @
-- M a ~ Af (V a)
-- T a ~ Af (Af (V a))
-- @
--
data Af a = Af a a
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | composition
--
-- @
-- f(g(x)) = a(cx+d)+b = (ac)x + (ad+b)
-- @
instance Num a => Semigroup (Af a) where
  Af a b <> Af c d = Af (a*c) (a*d+b)

instance Num a => Monoid (Af a) where
  mempty = Af 1 0
  mappend = (<>)

-- | convert an affine transform into a polynomial
ap :: IntegralDomain a => Af a -> P a
ap (Af 0 0) = P []
ap (Af 0 b) = P [b]
ap (Af a b) = P [b,a]

-- | evaluate an affine transformation
affine :: Num a => Af a -> a -> a
affine (Af a b) x = a*x + b

--------------------------------------------------------------------------------
-- * composite digit matrices
--------------------------------------------------------------------------------

-- | b = base, d = digit
digit :: Num a => a -> a -> M a
digit b d | a <- b-1, c <- b+1 = M (c+d) (a+d) (a-d) (c-d)

-- | b = base, n = number of bits, c = counter
digits :: Num a => a -> Int -> a -> M a
digits b n c = digit (b^n) c

--------------------------------------------------------------------------------
-- * Mobius Transformations
--------------------------------------------------------------------------------

-- | Linear fractional transformation
data M a = M
  a a
  ---
  a a
  deriving (Functor, Show, Traversable)

instance Num a => Semigroup (M a) where
  M a b c d <> M e f g h = M (a*e+b*g) (a*f+b*h) (c*e+d*g) (c*f+d*h)

instance Num a => Monoid (M a) where
  mempty = M 1 0 0 1
  mappend = (<>)

instance Foldable M where
  foldMap f (M a b c d) = f a `mappend` f b `mappend` f c `mappend` f d
  foldl1 f (M a b c d) = f (f (f a b) c) d

instance Columns M where
  columns f (M a b c d) = f (V a c) <> f (V b d)

-- | determinant of the matrix
--
-- @
-- det m * det n = det (m <> n)
-- @
det :: Num a => M a -> a
det (M a b c d) = a*d - b*c

-- | The "tame inverse" of a linear fractional transformation
--
--
-- @
-- inv m <> m = Hom (det m) 0 0 (det m) = mempty, given det m /= 0
-- @
inv :: Num a => M a -> M a
inv (M a b c d) = M (negate d) b c (negate a)

-- | construct a homographic transform from an affine transform
am :: Num a => Af a -> M a
am (Af a b) = M a b 0 1

-- | Apply a Mobius transformation to an extended rational.
mv :: Num a => M a -> V a -> V a
mv (M a b c d) (V e f) = V (a*e+b*f) (c*e+d*f)

-- | Transpose a matrix
transposeM :: M a -> M a
transposeM (M a b c d) = M a c b d

class Informed f where
  -- # of digit matrices we can emit
  most :: f Z -> Int
  least :: f Z -> Int

instance Informed V where
  most _ = maxBound
  least _ = maxBound

instance Informed M where
  most (fmap fromInteger -> m@(M a b c d)) = floor $ logBase 2 $ abs $
    (a+b) * (c+d) / det m
  least m = most m - 1

trace :: Num a => M a -> a
trace (M a _ _ d) = a + d

-- | characteristic polynomial of a linear fractional transformation
--
-- @
-- χ(λ,M) = char M ∈ a[λ]
-- @
char :: Num a => M a -> P a
char m = P [det m,trace m,1]

-- | Compute the invariance in the (needlessly extended) field of fractions of the coefficients.
-- of a non-singular matrix m.
--
-- @
-- invariance m = (trace m)^2 / det m
-- @
invariance :: IntegralDomain a => M a -> V a
invariance m
  | tr <- trace m
  , dt <- det m
  = V (tr*tr) dt

conjugate :: IntegralDomain a => M a -> M a -> Bool
conjugate m n
  | i <- invariance m
  = i /= 4 && i == invariance n

-- | m ∈ M⁺ ∩ M* ?
unsignedM :: M Z -> Bool
unsignedM (M 0 _ 0 _) = False
unsignedM (M _ 0 _ 0) = False
unsignedM (M a b c d) = a >= 0 && b >= 0 && c >= 0 && d >= 0

-- | Compute order of a linear homographic transformation
--
-- @order m == Just n@ means @n@ is the smallest positive integer such that @mtimes n m == mempty@
order :: IntegralDomain a => M a -> Maybe Int -- these are at most 6, return it as an Int
order m = case invariance m of
  0 -> Just 2
  1 -> Just 3
  2 -> Just 4
  3 -> Just 6
  4 -> Just 1
  _ -> Nothing

-- | rotation by @'pi'/2@
--
-- @{'mempty', 'sinf', 'sneg', 'szer'}@ is a finite cyclic group of order 4 generated by 'sinf' or 'szer'
--
-- >>> order sinf == Just 4
-- True
--
-- @
-- mempty([0,∞]) = [0,∞]
-- sinf([0,∞]) = [1,-1]
-- sneg([0,∞]) = [∞,0]
-- szer([0,∞]) = [-1,1]
-- @
sinf :: Num a => M a
sinf = M 1 1 (-1) 1

-- | rotation by pi
--
-- >>> order sneg == Just 2
-- True
--
-- >>> sneg == sinf <> sinf
-- True
sneg :: Num a => M a
sneg = M 0 1 (-1) 0

-- | rotation by 3pi/2
--
-- >>> order szer == Just 4
-- True
--
-- >>> szer == sinf <> sinf <> sinf
-- True
szer :: Num a => M a
szer = M 1 (-1) 1 1

--
-- @{mempty, sh, sl}@ forms a finite cyclic group of order 3 generated by 'sh' or 'sl'
--
-- @
-- x |-> 1/(1-x)
-- @
--
-- >>> order sh == Just 3
-- True
--
-- >>> sh <> sh <> sh
-- M 1 0 0 1
--
-- @
-- mempty([0,∞]) = [0,∞]
-- sh([0,∞]) = [1,0]
-- sl([0,∞]) = [∞,1]
-- @
sh :: Num a => M a
sh = M 0 1 (-1) 1

-- @
-- x |-> x - 1
-- @
--
-- >>> order sl == Just 3
-- True
--
-- >>> sl == sh <> sh
-- True
--
-- >>> sl <> sl <> sl == mempty
-- True
sl :: Num a => M a
sl = M 1 (-1) 1 0

-- |
-- @
-- bounds (M a 1 1 0) = (a, ∞)
-- @
bounds :: (Num a, Ord a) => M a -> (V a, V a)
bounds (M a b c d)
  | a*d > b*c = (V b d, V a c)
  | otherwise = (V a c, V b d)


-- | much tighter bounds assuming we derive from a digits of a continued fraction
--
-- @
-- cfbounds (M a 1 1 0) = (a, a+1)
-- @
cfbounds :: (Num a, Ord a) => M a -> (V a, V a)
cfbounds (M a b c d)
  | a*d > b*c = (m, V a c)
  | otherwise = (V a c, m)
  where
    m | c * d >= 0 = V (a+b) (c+d) -- we agree on the sign, so use the mediant
      | otherwise  = V b d

--------------------------------------------------------------------------------
-- * Bihomographic Transformations
--------------------------------------------------------------------------------

-- |
-- @
-- z = T a b c d e f g h
-- @
--
-- represents the function
--
-- @
-- z(x,y) = axy + bx + cy + d
--          -----------------
--          exy + fx + gy + d
-- @
--
-- and can be viewed as being simultaneously a homographic transformation
-- @z(x)[y]@ with coefficients in @Z[y]@:
--
-- z(x)[y] = (ay + b)x + (cy + d)
--           --------------------
--           (ey + f)x + (gy + h)
--
-- or as @z(y)[x]@ with coefficients in @Z[x]@:
--
-- z(y)[x] = (ax + c)y + (bx + d)
--           --------------------
--           (ey + g)y + (fy + h)
--
-- or in Z[y].
data T a = T
  a a a a
  -------
  a a a a
  deriving (Functor, Show, Traversable)

instance Foldable T where
  foldMap k (T a b c d e f g h) = k a `mappend` k b `mappend` k c `mappend` k d `mappend` k e `mappend` k f `mappend` k g `mappend` k h
  foldl1 k (T a b c d e f g h) = k (k (k (k (k (k (k a b) c) d) e) f) g) h

instance Columns T where
  columns k (T a b c d e f g h) = k (V a e) <> k (V b f) <> k (V c g) <> k (V d h)

-- | @mt f z x y = f(z(x,y))@
mt :: Num a => M a -> T a -> T a
mt (M a b c d) (T e e' f f' g g' h h') = T
  (a*e+b*g) (a*e'+b*g') (a*f+b*h) (a*f'+b*h')
  -------------------------------------------
  (c*e+d*g) (c*e'+d*g') (c*f+d*h) (c*f'+d*h')

-- | @tm1 z f x y = z(f(x),y) = z(f(x))[y]@
tm1 :: Num a => T a -> M a -> T a
tm1 (T a a' b b' c c' d d') (M e f g h) = T
  (a*e+b*g) (a'*e+b'*g) (a*f+b*h) (a'*f+b'*h)
  -------------------------------------------
  (c*e+d*g) (c'*e+d'*g) (c*f+d*h) (c'*f+d'*h)

-- | @tm2 z g x y = z(x,g(y)) = z(g(y))[x]@
tm2 :: Num a => T a -> M a -> T a
tm2 (T a b a' b' c d c' d') (M e f g h) = T
  (a*e+b*g) (a*f+b*h) (a'*e+b'*g) (a'*f+b'*h)
  -------------------------------------------
  (c*e+d*g) (c*f+d*h) (c'*e+d'*g) (c'*f+d'*h)

-- |
-- Apply a bihomographic transformation to an extended rational.
-- The result is a residual homographic transformation.
--
-- @
-- z(k/n,y) = (a(k/n) + c)y + (b(k/n) + d)
--            ----------------------------
--            (e(k/n) + g)y + (f(k/n) + h)
--
--          = (ka + nc)y + (kb+nd)
--            --------------------
--            (ke + ng)y + (kf+nh)
-- @
tv1 :: Num a => T a -> V a -> M a
tv1 (T a b c d e f g h) (V k n) = M
  (k*a+n*c) (k*b+n*d)
  -------------------
  (k*e+n*g) (k*f+n*h)

-- |
--
-- Apply a bihomographic transformation to an extended rational.
-- The result is a residual homographic transformation.
--
-- @
-- z(x,k/n) = ax(k/n) + bx + c(k/n) + d
--            -------------------------
--            ex(k/n) + fx + g(k/n) + d
--
--          = (ka + nb)x + (kc + nd)
--            ----------------------
--            (ke + nf)x + (kg + nh)
-- @
tv2 :: Num a => T a -> V a -> M a
tv2 (T a b c d e f g h) (V k n) = M
  (k*a+n*b) (k*c+n*d)
  -------------------
  (k*e+n*f) (k*g+n*h)

tq :: Num a => T a -> Q a
tq (T a b c d e f g h) = Q a (b+c) d e (f+g) h

transposeT :: T a -> T a
transposeT (T a b c d e f g h) = T a c b d e g f h

componentsT :: T a -> (M a, M a)
componentsT (T a b c d e f g h) = (M a b e f, M c d g h)

-- | best naive homographic approximation
approx :: (IntegralDomain a, Ord a) => T a -> M a
approx (T a b c d e f g h)
  | (i,j) <- minmax (V a e) (V b f)
  , (k,l) <- minmax (V c g) (V d h)
  , V m o <- min i k
  , V n p <- max j l
  = M m n o p

-- True -> X, False -> Y
strategy :: (IntegralDomain a, Ord a) => T a -> Bool
strategy t = overlap
  where (c0, c1) = componentsT $ transposeT t
        (tt0i, tt0s) = bounds c0
        (tt1i, tt1s) = bounds c1
        overlap = not (tt0s < tt1i || tt1s < tt0i)

--------------------------------------------------------------------------------
-- * Binary Quadratic Forms?
--------------------------------------------------------------------------------

-- @
-- q(x,y) = Ax^2 + Bxy + C^2
-- @
data BQF a = BQF a a a deriving (Show, Functor, Foldable, Traversable)

--------------------------------------------------------------------------------
-- * Quadratic Fractional Transformations
--------------------------------------------------------------------------------

-- |
-- @
-- z(x) = ax^2 + bx + c
--        -------------
--        dx^2 + ex + f
-- @
data Q a = Q
  a a a
  -----
  a a a
  deriving (Show, Functor, Traversable)

instance Foldable Q where
  foldMap k (Q a b c d e f) = k a `mappend` k b `mappend` k c `mappend` k d `mappend` k e `mappend` k f
  foldl1 k (Q a b c d e f) = k (k (k (k (k a b) c) d) e) f

instance Columns Q where
  columns k (Q a b c d e f) = k (V a d) <> k (V b e) <> k (V c f)

-- z(g/h) = a(g/h)^2 + b(g/h) + c
--          ---------------------
--          d(g/h)^2 + e(g/h) + f
--        = ag^2 + bgh + ch^2
--          -----------------
--        = dg^2 + egh + eh^2

qv :: Num a => Q a -> V a -> V a
qv (Q a b c d e f) (V g h)
  | gg <- g*g
  , gh <- g*h
  , hh <- h*h
  = V (a*gg + b*gh + c*hh) (d*gg + e*gh + f*hh)

-- |
-- @
-- z(m(x)) = a((gx+h)/(ix+j))^2 + b(gx+h)/(ix+j) + c
--           ---------------------------------------
--           d((gx+h)/(ix+j))^2 + e(gx+h)/(ix+j) + f
--
--         = a(gx+h)^2 + b(gx+h)(ix+j) + c(ix+j)^2
--           -------------------------------------
--           d(gx+h)^2 + e(gx+h)(ix+j) + f(ix+j)^2
--
--         = (agg + bgi + cii)x^2 + (2ahg + b(hi + gj) + 2cij)x  + (ahh + bhj + cjj)
--           ---------------------------------------------------------------------
--         = (dgg + egi + fii)x^2 + (2dhg + e(hi + gj) + 2fij)x  + (dhh + ehj + fjj)
-- @
qm :: Num a => Q a -> M a -> Q a
qm (Q a b c d e f) (M g h i j)
  | gg <- g*g
  , gi <- g*i
  , ii <- i*i
  , hg2 <- 2*h*g
  , hi_gj <- h*i+g*j
  , ij2 <- 2*i*j
  , hh <- h*h
  , hj <- h*j
  , jj <- j*j
  = Q
  (a*gg + b*gi + c*ii) (a*hg2 + b*hi_gj + c*ij2) (a*hh + b*hj + c*jj)
  -------------------------------------------------------------------
  (d*gg + e*gi + f*ii) (d*hg2 + e*hi_gj + f*ij2) (d*hh + e*hj + f*jj)

-- |
-- @
-- m(z(x)) = a(ex^2+fx+g) + b(hx^2+ix+j)
--           ---------------------------
--           c(ex^2+fx+g) + d(hx^2+ix+j)
--
--         = (ae+bh)x^2 + (af+bi)x + ag+bj
--           -----------------------------
--           (ce+dh)x^2 + (cf+di)x + cg+dj
-- @
mq :: Num a => M a -> Q a -> Q a
mq (M a b c d) (Q e f g h i j) = Q
  (a*e+b*h) (a*f+b*i) (a*g+b*j)
  (c*e+d*h) (c*f+d*i) (c*g+d*j)

--------------------------------------------------------------------------------
-- * Exact Real Arithmetic
--------------------------------------------------------------------------------

-- nested linear fractional transformations
--
-- (m :* n :* ...) implies that all matrices from n onward always narrow a suitable interval.
-- (m :* ...) = singular matrices m simplify to Q

data E
  = Quot    {-# UNPACK #-} !(V Z)                             -- extended rational
  | Hom     {-# UNPACK #-} !(M Z) E                           -- unapplied linear fractional transformation
  | Hurwitz {-# UNPACK #-} !Integer !(M (P Z))                -- (generalized) hurwitz numbers
  | Quad    {-# UNPACK #-} !(Q Z) E                           -- quadratic fractional transformation
  | Mero    {-# UNPACK #-} !Integer !(T (P Z)) E              -- nested bihomographic transformations
  | Bihom   {-# UNPACK #-} !(T Z) E E                         -- bihomographic transformation
    deriving (Show)

hom :: M Z -> E -> E
hom m (Quot v) = Quot $ scale $ mv m v
hom m (Hom n x) = Hom (scale $ m <> n) x -- check for efficiency
hom m (Quad q x) = quad (scale $ mq m q) x
--hom m (Mero t x) = Hom m $ Mero t x
hom m (Bihom s x y) = bihom (mt m s) x y
--hom (fmap lift -> m) (Hurwitz o) | det m /= 0 = hurwitz (m <> o <> inv m)
hom m x = Hom (scale m) x -- deferred hom

-- | apply a meromorphic function
--
-- @
--    |
--    s
--   / \
--  x   t 0
--     / \
--    x   t 1
--       / .
--      x   .
--           .
-- @
mero :: T (P Z) -> E -> E
-- TODO: simplify if the matrix has no x component? y component?
mero t (Quot r) = hurwitz (tv1 t (fmap lift r)) -- TODO: This is broken when r is negative
mero t x = Mero 0 (scaleP t) x

-- | apply a bihomographic transformation
bihom :: T Z -> E -> E -> E
bihom m (Quot r) y = hom (tv1 m r) y
bihom m x (Quot r) = hom (tv2 m r) x
bihom m x y = Bihom (scale m) x y
{-# NOINLINE bihom #-}

quad :: Q Z -> E -> E
quad q (Quot v) = Quot (qv q v)
quad (Q 0 a b 0 c d) x = hom (M a b c d) x
quad (Q a b c d e f) x
  | a*e == b*d, a*f == d*c, b*f == c*e, False = undefined
  -- TODO: we can factor our quadratic form into @Q (p*r) (p*s) (p*t) (q*r) (q*s) (q*t)@
  -- do something with that fact
quad q x = Quad q x

-- smart constructor
hurwitz :: M (P Z) -> E
-- hurwitz (fmap at0 -> M a b c d) | a*d == c*b = Quot (V a c) -- singular: TODO: check this
hurwitz m = Hurwitz 0 (scaleP m)

-- -- extract a partial quotient
-- nextF :: F -> Maybe (Z, F)
-- nextF (Quot (V k n)) = case quotRem k n of
--   (q, r) -> Just (q, Quot (V n r))
-- nextF (Hom (M a b 0 0) xs) = Nothing -- ∞ or ⊥
-- nextF (Hom m@(M a b c d) xs)
--   | c /= 0, d /= 0
--   , signum c * signum (c + d) > 0 -- knuth style warmup?
--   , q <- quot a c
--   , q == quot b d
--   , n <- cfdigit q = Just (q, Hom (inv n <> m) xs)
-- nextF (Hom m xs) = nextF (hom m xs) -- fetch more
-- nextF (Hurwitz m) = nextF (Hom (fmap at0 m) $ Hurwitz (fmap (<> P [1,1]) m)) -- explicitly used Hom to keep it from merging back

square :: E -> E
square x = quad (Q 1 0 0 0 0 1) x

-- {-# RULES "bihomographic to quadratic" forall t x. bihom t x x = quad (tq t) x #-}

instance Eq E
instance Ord E

instance Num E where
  -- x + x -> quad (Q 0 2 0 0 0 1) x = hom (2 0 0 1) x = 2x
  x + y = bihom (T 0 1 1 0 0 0 0 1) x y
  {-# INLINE (+) #-}
  -- x - x -> quad (Q 0 0 0 0 0 1) x = hom (0 0 0 1) x = 0x
  x - y = bihom (T 0 1 (-1) 0 0 0 0 1) x y
  {-# INLINE (-) #-}
  -- x * x -> quad (Q 1 0 0 0 0 1) x = x^2
  x * y = bihom (T 1 0 0 0 0 0 0 1) x y
  {-# INLINE (*) #-}
  negate x = hom (M (-1) 0 0 1) x
  abs xs | xs < 0 = negate xs
         | otherwise = xs
  signum xs = fromInteger $ case compare xs 0 of LT -> -1; EQ -> 0; GT -> 1
  fromInteger n = Quot $ V n 1

instance Fractional E where
  -- x / x -> quad (Q 0 1 0 0 1 0) x = hom (1 0 1 0) x = 1 for nice x
  x / y = bihom (T 0 1 0 0 0 0 1 0) x y
  {-# INLINE (/) #-}
  recip x = hom (M 0 1 1 0) x
  fromRational (k :% n) = Quot $ V k n

instance Floating E where
  pi     = M 0 4 1 0 `Hom` hurwitz (M (P [1,2]) (P [1,2,1]) 1 0)
  -- TODO: Range reduce
  exp x  = mero (T (P [2,2]) (P [1,2]) (P [0,2]) (P [1,2])
                   (P [1,2]) (P [0,2]) (P [1,2]) (P [2,2])) ((inv szer) `hom` x)
  -- TODO: Range reduce
  log x  = bihom (T 1 1 (-1) (-1) 0 1 1 0) x $
           mero (T (P [1,1]) (P [3,2]) (P [2,1]) (P [])
                   (P [])    (P [2,1]) (P [3,2]) (P [1,1])) x
  -- TODO: Range reduce
  tan x  = bihom (T 1 1 (-1) (-1) 2 0 0 2) x' $
           mero (T (P [3,2]) (P [1,2]) (P [3,2]) (P [5,2])
                   (P [5,2]) (P [3,2]) (P [1,2]) (P [3,2])) x'
    where x' = inv szer `hom` x
  -- TODO: Range reduce
  atan x = bihom (T 1 1 (-1) (-1) 2 0 0 2) x' $
           mero (T (P [3,2]) (P [1,1]) (P [])    (P [2,1])
                   (P [2,1]) (P [])    (P [1,1]) (P [3,2])) x'
    where x' = inv szer `hom` x
  sqrt x = mero (T 1 2 1 0 0 1 2 1) x

  sin x  = quad (Q 0 2 0 1 0 1)    (tan (x/2))
  cos x  = quad (Q (-1) 0 1 1 0 1) (tan (x/2))
  sinh x = quad (Q 1 0 (-1) 0 2 0) (exp x)
  cosh x = quad (Q 1 0 1 0 2 0)    (exp x)
  tanh x = quad (Q 1 0 (-1) 1 0 1) (exp x)
  asin x = atan $ sqrt $ quad (Q 1 0 0 (-1) 0 1) x
  acos x = atan $ sqrt $ quad (Q (-1) 0 1 1 0 0) x
  asinh x = log $ x + sqrt (x^2 + 1)
  acosh x = log $ x + sqrt (x^2 - 1)
  atanh x = log (hom sinf x) / 2

instance IntegralDomain E

sqrt2 :: E
sqrt2 = cfdigit 1 `hom` hurwitz (M 2 1 1 0)

--------------------------------------------------------------------------------
-- * Continued Fractions
--------------------------------------------------------------------------------

-- continued fraction digit
cfdigit :: Num a => a -> M a
cfdigit a = M a 1 1 0

-- generalized continued fraction digit
gcfdigit :: Num a => a -> a -> M a
gcfdigit a b = M a b 1 0

--------------------------------------------------------------------------------
-- * Redundant Binary Representation
--------------------------------------------------------------------------------

data SignM = Sinf | Sneg | Szer | Spos deriving (Show)

signm :: Num a => SignM -> M a
signm Sinf = sinf
signm Sneg = sneg
signm Szer = szer
signm Spos = mempty

data DigitM = Dneg | Dzer | Dpos deriving (Show)

dneg :: Num a => M a
dneg = M 1 0 2 2

dzer :: Num a => M a
dzer = M 3 1 1 3

dpos :: Num a => M a
dpos = M 2 1 0 1

digitm :: Num a => DigitM -> M a
digitm Dneg = dneg
digitm Dzer = dzer
digitm Dpos = dpos

--------------------------------------------------------------------------------
-- * Information Extraction
--------------------------------------------------------------------------------

data Info = CFDigit Z | BinaryDigit DigitM | AnyHom (M Z) | Term (V Z)
  deriving (Show)

infom :: Info -> M Z
infom (CFDigit q) = cfdigit q
infom (BinaryDigit b) = digitm b
infom (AnyHom h) = h
infom (Term (V n d)) = M n n d d

class Sigma a => Emissive a where
  -- Precompose an (M Z)
  (#>) :: M Z -> a -> a

  quotient    :: a -> Maybe Z

instance Emissive (V Z) where
  (#>) = mv
  quotient _ = Nothing

instance Emissive (M Z) where
  (#>) = (<>)
  quotient (M a b c d)
    | c /= 0, d /= 0,
      q <- a `quot` c,
      q /= 0,
      q == b `quot` d
    = Just q
    | otherwise = Nothing

instance Emissive (T Z) where
  (#>) = mt
  quotient (T a b c d e f g h)
    | e /= 0, f /= 0, g /= 0, h /= 0,
      q <- a `quot` e,
      q /= 0,
      q == b `quot` f,
      q == c `quot` g,
      q == d `quot` h
    = Just q
    | otherwise = Nothing

instance Emissive (T (P Z)) where
  m #> t = fmap lift m `mt` t
  quotient _ = Nothing

instance Emissive (Q Z) where
  (#>) = mq
  quotient (Q a b c d e f)
    | d /= 0, e /= 0, f /= 0,
      q <- a `quot` d,
      q /= 0,
      q == b `quot` e,
      q == c `quot` f
    = Just q
    | otherwise = Nothing

attempt :: (Emissive a) => M Z -> a -> Maybe a
attempt m e = let e' = inv m #> e in
              if pos e' then Just e' else Nothing

topsign :: (Emissive a) => a -> Maybe (SignM, a)
topsign e | Just e' <- attempt szer e = Just (Szer, e')
topsign e | Just e' <- attempt mempty e = Just (Spos, e')
topsign e | Just e' <- attempt sinf e = Just (Sinf, e')
topsign e | Just e' <- attempt sneg e = Just (Sneg, e')
topsign _ | otherwise = Nothing

topinfo :: (Emissive a) => a -> Maybe (Info, a)
topinfo e | Just q       <- quotient e     = Just (CFDigit q, inv (cfdigit q) #> e)
topinfo e | Just e'      <- attempt dpos e = Just (BinaryDigit Dpos, e')
topinfo e | Just e'      <- attempt dneg e = Just (BinaryDigit Dneg, e')
topinfo e | Just e'      <- attempt dzer e = Just (BinaryDigit Dzer, e')
topinfo _ | otherwise                      = Nothing


sign :: E -> (SignM, E)
sign (Quot v) | Just (s, e') <- topsign v = (s, Quot e')
              | otherwise                 = error "impossible"
sign (Hom h e) | Just (s, h'') <- topsign h' = (s, hom h'' e)
               | otherwise                  = sign (pump (hom h' ec))
  where (sc, ec) = sign e
        h' = h <> signm sc
sign (Bihom t x y) | Just (s, t'') <- topsign t' = (s, bihom t'' x' y')
                   | otherwise                   = sign (pump (bihom t' x' y'))
  where (sx, x') = sign x
        (sy, y') = sign y
        t' = tm2 (tm1 t (signm sx)) (signm sy)
sign (Quad q e) | Just (s, q'') <- topsign q' = (s, quad q'' e)
                | otherwise                   = sign (pump (quad q' e'))
  where (se, e') = sign e
        q' = q `qm` signm se
sign (Hurwitz n m) = (Spos, Hurwitz n m)
sign (Mero n t e) = (Spos, Mero n t e)

emit :: E -> (Info, E)
emit (Quot v) = (Term v, error "emit after Term")
emit (Hom h e)     | pos h = (AnyHom h, e)
emit (Hom h e)     | Just (i, h') <- topinfo h = (i, hom h' e)
emit (Hom h e)     | otherwise = emit $ pump (hom h e)
emit (Bihom t x y) | Just (i, t') <- topinfo t = (i, bihom t' x y)
emit (Bihom t x y) | otherwise = emit $ pump (bihom t x y)
emit (Quad r e)    | Just (i, r') <- topinfo r = (i, quad r' e)
emit (Quad r e)    | otherwise = emit $ pump (quad r e)
emit (Hurwitz n m) = (AnyHom $ fmap (at n) m, Hurwitz (n+1) m)
emit (Mero n t e)  | Just (i, _) <- topinfo t
  = let im = fmap lift $ infom i in
    (i, Mero n (scaleP $ inv im `mt` t `tm2` im) e)
emit (Mero n t e)  | otherwise = emit $ pump (Mero n t e)

pump :: E -> E
pump (Quot _) = error "pump Quot"
pump (Hom h e) | (i, e') <- emit e = case i of
                 Term v -> hom h (Quot v)
                 _      -> hom (h <> infom i) e'
pump (Bihom t x y) | strategy t = case emit x of
                     (Term v, _)  -> bihom t (Quot v) y
                     (i,      x') -> bihom (t `tm1` infom i) x' y
pump (Bihom t x y) | otherwise  = case emit y of
                     (Term v, _)  -> bihom t x (Quot v)
                     (i,      y') -> bihom (t `tm2` infom i) x  y'
pump (Quad q x) | (i, e') <- emit x = case i of
                  Term v -> quad q (Quot v)
                  _      -> quad (q `qm` infom i) e'
pump (Hurwitz _ _) = error "pump Hurwitz"
pump (Mero n t e) | strategy $ fmap (at n) t = case emit e of
                    (Term v, _)  -> Hurwitz n (t `tv1` fmap lift v)
                    (i,      e') -> Mero n (t `tm1` fmap lift (infom i)) e'
pump (Mero n t e) | otherwise = bihom (fmap (at n) t) e (Mero (n+1) t e)

data Result = Result SignM [Info] deriving (Show)

result :: E -> Result
result e = Result s (results ue)
  where (s, ue) = sign e
        results e' = case emit e' of
          (Term v, _) -> [Term v]
          (i, next) -> i : results next

approximate :: Integer -> Result -> V Z
approximate n (Result s is) = signm s `mv` unsigned n is
  where unsigned _ [] = V 0 0
        unsigned _ [Term v] = v
        unsigned 0 (i:is) | M a _ c _ <- infom i = V a c -- why not
        unsigned n (i:is) = infom i `mv` unsigned (n-1) is

--------------------------------------------------------------------------------
-- * Decimal
--------------------------------------------------------------------------------
