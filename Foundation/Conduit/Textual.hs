module Foundation.Conduit.Textual
    ( lines
    , words
    , fromBytes
    , toBytes
    ) where

import           Foundation.Internal.Base hiding (throw)
import           Foundation.Array.Unboxed (UArray)
import           Foundation.String (String)
import           Foundation.Collection
import qualified Foundation.String.UTF8 as S
import           Foundation.Conduit.Internal
import           Foundation.Monad
import           Data.Char (isSpace)

-- | Split conduit of string to its lines
--
-- This is very similar to Prelude lines except
-- it work directly on Conduit
--
-- Note that if the newline character is not coming,
-- this function will keep accumulating data until OOM
lines :: Monad m => Conduit String String m ()
lines = await >>= maybe (finish []) (go [])
  where
    mconcatRev = mconcat . reverse

    finish l = if null l then return () else yield (mconcatRev l)

    go prevs nextBuf =
        case S.uncons next' of
            Just (_, rest') -> yield (mconcatRev (line : prevs)) >> go mempty rest'
            Nothing         ->
                let nextCurrent = nextBuf : prevs
                 in await >>= maybe (finish nextCurrent) (go nextCurrent)
      where (line, next') = S.breakElem '\n' nextBuf

words :: Monad m => Conduit String String m ()
words = await >>= maybe (finish []) (go [])
  where
    mconcatRev = mconcat . reverse

    finish l = if null l then return () else yield (mconcatRev l)

    go prevs nextBuf =
        case S.dropWhile isSpace next' of
            rest' 
                | null rest' ->
                    let nextCurrent = nextBuf : prevs
                     in await >>= maybe (finish nextCurrent) (go nextCurrent)
                | otherwise  -> yield (mconcatRev (line : prevs)) >> go mempty rest'
      where (line, next') = S.break isSpace nextBuf

fromBytes :: MonadThrow m => S.Encoding -> Conduit (UArray Word8) String m ()
fromBytes encoding = loop mempty
  where
    loop r = await >>= maybe (finish r) (go r)
    finish buf | null buf  = return ()
               | otherwise = case S.fromBytes encoding buf of
                                    (s, Nothing, _)  -> yield s
                                    (_, Just err, _) -> throw err
    go current nextBuf =
        case S.fromBytes encoding (current `mappend` nextBuf) of
            (s, Nothing           , r) -> yield s >> loop r
            (s, Just S.MissingByte, r) -> yield s >> loop r
            (_, Just err          , _) -> throw err

toBytes :: Monad m => S.Encoding -> Conduit String (UArray Word8) m ()
toBytes encoding = awaitForever $ \a -> pure (S.toBytes encoding a) >>= yield
