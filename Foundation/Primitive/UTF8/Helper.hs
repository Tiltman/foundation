-- |
-- Module      : Foundation.Primitive.UTF8.Helper
-- License     : BSD-style
-- Maintainer  : Foundation
--
-- Some low level helpers to use UTF8
--
-- Most helpers are lowlevel and unsafe, don't use
-- directly.
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE CPP                        #-}
module Foundation.Primitive.UTF8.Helper
    where

import           Foundation.Internal.Base
import           Foundation.Internal.Primitive
import           Foundation.Primitive.Types.OffsetSize
import           GHC.Prim
import           GHC.Types
import           GHC.Word

-- | Possible failure related to validating bytes of UTF8 sequences.
data ValidationFailure = InvalidHeader
                       | InvalidContinuation
                       | MissingByte
                       | BuildingFailure
                       deriving (Show,Eq,Typeable)

instance Exception ValidationFailure

-- mask an UTF8 continuation byte (stripping the leading 10 and returning 6 valid bits)
maskContinuation# :: Word# -> Word#
maskContinuation# v = and# v 0x3f##
{-# INLINE maskContinuation# #-}

-- mask a UTF8 header for 2 bytes encoding (110xxxxx and 5 valid bits)
maskHeader2# :: Word# -> Word#
maskHeader2# h = and# h 0x1f##
{-# INLINE maskHeader2# #-}

-- mask a UTF8 header for 3 bytes encoding (1110xxxx and 4 valid bits)
maskHeader3# :: Word# -> Word#
maskHeader3# h = and# h 0xf##
{-# INLINE maskHeader3# #-}

-- mask a UTF8 header for 3 bytes encoding (11110xxx and 3 valid bits)
maskHeader4# :: Word# -> Word#
maskHeader4# h = and# h 0x7##
{-# INLINE maskHeader4# #-}

or3# :: Word# -> Word# -> Word# -> Word#
or3# a b c = or# a (or# b c)
{-# INLINE or3# #-}

or4# :: Word# -> Word# -> Word# -> Word# -> Word#
or4# a b c d = or# (or# a b) (or# c d)
{-# INLINE or4# #-}

toChar# :: Word# -> Char
toChar# w = C# (chr# (word2Int# w))
{-# INLINE toChar# #-}

toChar1 :: Word8 -> Char
toChar1 (W8# w) = toChar# w

toChar2 :: Word8 -> Word8 -> Char
toChar2 (W8# w1) (W8# w2)=
    toChar# (or# (uncheckedShiftL# (maskHeader2# w1) 6#) (maskContinuation# w2))

toChar3 :: Word8 -> Word8 -> Word8 -> Char
toChar3 (W8# w1) (W8# w2) (W8# w3) =
    toChar# (or3# (uncheckedShiftL# (maskHeader3# w1) 12#)
                  (uncheckedShiftL# (maskContinuation# w2) 6#)
                  (maskContinuation# w3)
            )

toChar4 :: Word8 -> Word8 -> Word8 -> Word8 -> Char
toChar4 (W8# w1) (W8# w2) (W8# w3) (W8# w4) =
    toChar# (or4# (uncheckedShiftL# (maskHeader4# w1) 18#)
                  (uncheckedShiftL# (maskContinuation# w2) 12#)
                  (uncheckedShiftL# (maskContinuation# w3) 6#)
                  (maskContinuation# w4)
            )

-- | Different way to encode a Character in UTF8 represented as an ADT
data UTF8Char =
      UTF8_1 {-# UNPACK #-} !Word8
    | UTF8_2 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8
    | UTF8_3 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8
    | UTF8_4 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8

-- | Transform a Unicode code point 'Char' into
--
-- note that we expect here a valid unicode code point in the *allowed* range.
-- bits will be lost if going above 0x10ffff
asUTF8Char :: Char -> UTF8Char
asUTF8Char !c
  | bool# (ltWord# x 0x80##   ) = encode1
  | bool# (ltWord# x 0x800##  ) = encode2
  | bool# (ltWord# x 0x10000##) = encode3
  | otherwise                   = encode4
    where
      !(I# xi) = fromEnum c
      !x       = int2Word# xi

      encode1 = UTF8_1 (W8# x)
      encode2 =
          let !x1 = W8# (or# (uncheckedShiftRL# x 6#) 0xc0##)
              !x2 = toContinuation x
           in UTF8_2 x1 x2
      encode3 =
          let !x1 = W8# (or# (uncheckedShiftRL# x 12#) 0xe0##)
              !x2 = toContinuation (uncheckedShiftRL# x 6#)
              !x3 = toContinuation x
           in UTF8_3 x1 x2 x3
      encode4 =
          let !x1 = W8# (or# (uncheckedShiftRL# x 18#) 0xf0##)
              !x2 = toContinuation (uncheckedShiftRL# x 12#)
              !x3 = toContinuation (uncheckedShiftRL# x 6#)
              !x4 = toContinuation x
           in UTF8_4 x1 x2 x3 x4

      toContinuation :: Word# -> Word8
      toContinuation w = W8# (or# (and# w 0x3f##) 0x80##)
      {-# INLINE toContinuation #-}

-- given the encoding of UTF8 Char, get the number of bytes of this sequence
numBytes :: UTF8Char -> Size8
numBytes UTF8_1{} = CountOf 1
numBytes UTF8_2{} = CountOf 2
numBytes UTF8_3{} = CountOf 3
numBytes UTF8_4{} = CountOf 4

-- given the leading byte of a utf8 sequence, get the number of bytes of this sequence
skipNextHeaderValue :: Word8 -> CountOf Word8
skipNextHeaderValue !x
    | x < 0xC0  = CountOf 1 -- 0b11000000
    | x < 0xE0  = CountOf 2 -- 0b11100000
    | x < 0xF0  = CountOf 3 -- 0b11110000
    | otherwise = CountOf 4
{-# INLINE skipNextHeaderValue #-}

headerIsAscii :: Word8 -> Bool
headerIsAscii x = x < 0x80

charToBytes :: Int -> Size8
charToBytes c
    | c < 0x80     = CountOf 1
    | c < 0x800    = CountOf 2
    | c < 0x10000  = CountOf 3
    | c < 0x110000 = CountOf 4
    | otherwise    = error ("invalid code point: " `mappend` show c)
