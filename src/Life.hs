-----------------------------------------------------------------------------
-- |
-- Module      :  Life
-- Copyright   :  (c) Sam Tay 2017
-- License     :  BSD3
-- Maintainer  :  sam.chong.tay@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-----------------------------------------------------------------------------
{-# LANGUAGE ConstrainedClassMethods #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
module Life
  (
  -- * Types and classes
    Board
  , Cell
  , St(..)
  , Zipper(..)
  , Direction(..)
  -- * Construction
  , board
  -- * Running the game
  , step
  , population
  , gameover
  , resize
  -- * Lenses
  , unzz, zl, zc, zi, zix
  ) where

import qualified Data.Foldable as F
import           Data.List (intercalate, nub)
import           Data.Maybe (fromMaybe, mapMaybe)

import           Control.Comonad
import           Data.Sequence (ViewL (..), ViewR (..), (<|), (><), (|>))
import qualified Data.Sequence as S
import           Lens.Micro
import qualified Lens.Micro.Internal as L
import           Lens.Micro.TH

-- | A modular game of life board
--
-- With this interpretation, for a board of size @n x n@
-- the @(n + 1)@th column/row is the same as the boundary at the @1@th column/row.
type Board = ZZ St

-- | Indexer for the 'Board'
type Cell = (Int, Int)

-- | Possible cell states
data St = Alive | Dead
  deriving (Eq)

-- | One dimensional finite list with cursor context
--
-- The first element of the sequence at '_zl' can be thought of
-- as /to the left/ of the cursor, while the last element is /to the right/
-- of the cursor. The cursor value and index are '_zc' and '_zi' respectively.
-- This can be thought of as a circle.
-- Warning: must have length greater than zero!
data Z a = Z
  { _zl :: S.Seq a
  , _zc :: a
  , _zi :: Int
  }
  deriving (Eq, Show)

newtype ZZ a = ZZ { _unzz :: Z (Z a) }
  deriving (Eq) -- TODO possibly implement equality up to shifting

makeLenses ''Z
makeLenses ''ZZ

-- | Class for a modular bounded container
--
-- Examples of functions provided for a simple one dimensional list, where appropriate
class Zipper z where
  type Index z
  data Direction z

  -- | Shift in a direction
  shift :: Direction z -> z a -> z a

  -- | Retrieve current cursor value
  cursor :: z a -> a

  -- | Retrieve current index value
  index :: z a -> Index z

  -- | Retrieve neighborhood of current cursor.
  neighborhood :: z a -> [a]

  -- | Destruct to list maintaining order of @(Index z)@, e.g. @(Z ls c rs) -> ls ++ [c] ++ rs@.
  toList :: z a -> [a]

  -- | Destruct a list into a mapping with indices
  toMap :: (Comonad z) => z a -> [(Index z, a)]
  toMap = toList . extend ((,) <$> index <*> cursor)

  -- | Construct zipper from mapping (provide default value so this is always safe, no bottoms)
  fromMap :: Ord (Index z) => a -> [(Index z, a)] -> z a

  -- | Lookup by possibly denormalised index (still safe from modularity).
  --
  -- e.g. [1,2] ! 2 == 1
  (!) :: z a -> (Index z) -> a

  -- | Adjust value at specified index
  adjust :: (a -> a) -> Index z -> z a -> z a

  -- | Update value at specified index
  update :: a -> Index z -> z a -> z a
  update = adjust . const

  -- | Normalize @Index z@ value with respect to modular boundaries
  normalize :: z a -> (Index z) -> (Index z)

  -- | Get size (maximum of @Index z@).
  size :: z a -> (Index z)

instance Zipper Z where
  type Index Z = Int
  data Direction Z = L | R deriving (Eq, Show)

  cursor = _zc
  index = _zi
  normalize z = (`mod` (size z))
  size (Z l _ _) = S.length l + 1
  (!) z k = z ^. zix k
  adjust f k z = z & zix k %~ f
  neighborhood (Z l _ _)
    | S.length l <= 2 = F.toList l
    | otherwise       = map (S.index l) [0, S.length l - 1]
  toList (Z l c i) = F.toList . S.reverse $ b >< (c <| f)
    where (f,b) = S.splitAt i l
  fromMap _ [] = error "Zipper must have length greater than zero."
  fromMap a m  = Z (S.fromList ys) (iToa 0) 0
    where ys = map iToa rng
          iToa i = fromMaybe a $ lookup i m
          l    = maximum . (0:) $ map fst m
          rng  = if l == 0 then [] else [l,(l-1)..1]
  shift d z@(Z l c i)
    | S.null l = z -- shifting length zero amounts to nothing
    | d == L   = Z (xs |> c) x xi
    | d == R   = Z (c <| ys) y yi
    where
      (x :< xs) = S.viewl l
      (ys :> y) = S.viewr l
      xi        = (i - 1) `mod` size z
      yi        = (i + 1) `mod` size z

instance Functor Z where
  fmap f (Z l c i) = Z (fmap f l) (f c) i

instance Comonad Z where
  extract = cursor
  duplicate z = Z (S.fromFunction (size z - 1) fn) z (z ^. zi)
    where fn k = compose (k + 1) (shift L) $ z

-- | This interpretation is a 2D zipper (Z (Z a)).
--
-- The outer layer is a zipper of columns (x coordinate),
-- and each column is a zipper of @a@ values (y coordinate).
-- Warning: Keep inner column sizes consistent!
instance Zipper ZZ where
  type Index ZZ = (Int, Int)
  data Direction ZZ = N | E | S | W deriving (Eq, Show)

  cursor = _zc . _zc . _unzz
  toList = concatMap toList . toList . _unzz
  adjust f (x, y) z = z & (unzz . zix x . zix y) %~ f
  (!) z (x, y) = z ^. unzz ^. zix x ^. zix y
  normalize z (x,y) = (nx, ny)
    where nx = x `mod` z ^. to size ^. _1
          ny = y `mod` z ^. to size ^. _2
  size z = (x, y)
    where x = z ^. unzz ^. to size
          y = z ^. unzz ^. zc ^. to size
  index z = (x, y)
    where x = z ^. unzz ^. zi
          y = z ^. unzz ^. zc ^. zi
  shift E = (& unzz %~ shift R)
  shift W = (& unzz %~ shift L)
  shift N = (& unzz %~ fmap (shift R))
  shift S = (& unzz %~ fmap (shift L))
  neighborhood (ZZ (Z l c _)) = ns ++ ew
    where ns  = neighborhood c
          ewc = if (S.length l <= 2)
                   then F.toList l
                   else map (S.index l) [0, S.length l - 1]
          ew  = concatMap neighborhood' ewc
          neighborhood' z = (z ^. zc) : neighborhood z
  fromMap _ [] = error "Zipper must have length greater than zero."
  fromMap a m  = ZZ $ Z (S.fromList cs) (iToc 0) 0
    where cs        = map iToc rc
          iToc i    = fromMap a . insDef . map (& _1 %~ snd) $ filter ((==i) . fst . fst) m
          l         = maximum . (0:) $ map (fst . fst) m
          h         = maximum . (0:) $ map (snd . fst) m
          rc        = if l == 0 then [] else [l,(l-1)..1]
          insDef xs = if h `elem` (map fst xs) then xs else (h,a) : xs

instance Functor ZZ where
  fmap f = ZZ . (fmap . fmap) f . _unzz

instance Comonad ZZ where
  extract = cursor
  duplicate z = ZZ $ Z
    (fromF (xT - 1) mkCol) (Z (fromF (yT - 1) (mkRow z)) z y) x
    where
      mkRow zx j = compose (j + 1) (shift S) zx
      mkCol i    = let zx = compose (i + 1) (shift W) z
                    in Z (fromF (yT - 1) (mkRow zx)) zx (zx ^. to index  ^. _2)
      (xT,yT)    = size z
      (x,y)      = index z
      fromF      = S.fromFunction

-- | Create a board with given height, length, and initial state
board :: Int -- ^ Length
      -> Int -- ^ Height
      -> [Cell] -- ^ List of cells initially alive
      -> Board
board l h = fromMap Dead . ins (l-1,h-1) . map (,Alive)
  where ins m cs = if (m, Alive) `elem` cs
                      then cs
                      else ((m, Dead):cs)

-- | Adjusts the number of columns and rows respectively.
--
-- For example @resize (-1) 1@ will remove one column and add one row.
resize :: Int -> Int -> Board -> Board
resize l h = resizeH h . resizeL l
  where resizeL l z
          | l < 0     = z & unzz %~ dropL (-l)
          | l > 0     = z & unzz %~ consLc l
          | otherwise = z
        resizeH h z
          | h < 0     = z & unzz %~ fmap (dropL (-h))
          | h > 0     = z & unzz %~ fmap (consLr h)
          | otherwise = z
        dropL :: Int -> Z a -> Z a
        dropL l = (& zl %~ S.drop l)
        consLr :: Int -> Z St -> Z St
        consLr h = (& zl %~ compose h (Dead <|))
        consLc :: Int -> Z (Z St) -> Z (Z St)
        consLc l z = let c = fmap (const Dead) $ z ^. zc
                      in z & zl %~ compose l (c <|)

-- | Step the game forward
step :: Board -> Board
step = extend rule
  where p = length . filter (==Alive) . neighborhood
        rule z = case (cursor z, p z) of
                   (Alive, 2) -> Alive
                   (Alive, 3) -> Alive
                   (Dead, 3)  -> Alive
                   _          -> Dead

-- | Returns the total number of living cells in a board
population :: Board -> Int
population = length . filter (==Alive) . toList

-- | Check if every cell is dead (i.e., gameover)
gameover :: Board -> Bool
gameover = (== 0) . population

-- Nice when sanity checking or playing in the REPL
--
-- Warning: slow since I implement outer layer as column
-- and this must be rendered first as rows.
instance Show a => Show (ZZ a) where
  show z = unlines $ map mkRow [rowT - 1,rowT - 2..0]
    where (colT, rowT) = size z
          mkRow y      = intercalate "|"
            $ map (show . (z !) . (,y)) [0..colT - 1]

instance Show St where
  show Alive = "X"
  show Dead  = "_"

-------------------- Utility functions --------------------

-- | Transform 'Index z' into the index of the @S.Seq@ that @z@ contains
-- unless it is equivalent to current index.
zToLix :: Z a -> Int -> Maybe Int
zToLix z@(Z _ _ i) k
  | i == n = Nothing
  | i < n  = Just $ s - (n - i) - 1
  | i > n  = Just $ i - n - 1
  where n = k `mod` s
        s = size z

compose :: Int -> (a -> a) -> (a -> a)
compose = (foldr (.) id .) . replicate

-------------------- Some Lens explorations --------------------

type instance L.Index   (Z a) = Int
type instance L.IxValue (Z a) = a

-- | Cool! 'Z' is now 'ix'able!
instance L.Ixed (Z a) where
  ix k f z@(Z l c i) = maybe
    ((\c' -> Z l c' i) <$> f (z ^. zc))
    (\i -> (\l' -> Z l' c i) . (\a -> S.update i a l) <$> f (z ^. zl ^. to (`S.index` i)))
    (zToLix z k)

-- My own lens! Although 'ix' usage is probably more standard than this,
-- it is not possible to use 'ix' as a direct getter: z ^. ix 3
-- does not behave as expected and wants a monoid instance; perhaps is
-- attempting to fold in this context?
-- You can use z ^? ix 3 to get back a Maybe value, but if I know my
-- getter is safe, I don't got time for dat.
--
-- Might be that I want the 'At' instance..
zix :: Int -> Lens' (Z a) a
zix k f z@(Z l c i) = maybe
  ((\x -> Z l x i) <$> f c)
  (\n -> (\x -> Z (S.update n x l) c i) <$> f (S.index l n))
  (zToLix z k)
