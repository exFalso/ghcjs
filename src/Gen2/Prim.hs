{-# LANGUAGE QuasiQuotes,
             TemplateHaskell,
             CPP #-}
module Gen2.Prim where

{-
  unboxed representations:

    Int#               -> number
    Double#            -> number
    Float#             -> number
    Char#              -> number
    Word#              -> number (values > 2^31 are mapped to negative numbers)
    Addr#              -> wrapped buffer + offset (number)
        (with some hacks for pointers to pointers in the .arr property)
    MutVar#            -> h$MutVar object
    TVar#              -> h$TVar object
    MVar#              -> h$MVar object
    Weak#              -> h$Weak object
    ThreadId#          -> h$Thread object
    State#             -> nothing
    StablePtr#         -> wrapped buffer / offset (base pkg expects unsafeCoerce to Addr# to work)
    MutableArrayArray# -> array
    MutableByteArray#  -> wrapped buffer
    ByteArray#         -> wrapped buffer
    Array#             -> array

  Pointers to pointers use a special representation with the .arr property
-}

import           PrimOp
import           TcType
import           Type
import           TyCon

import           Data.Monoid
import qualified Data.Set as S

import           Compiler.JMacro (j, JExpr(..), JStat(..))

import           Gen2.RtsTypes
import           Gen2.Utils


data PrimRes = PrimInline JStat  -- ^ primop is inline, result is assigned directly
             | PRPrimCall JStat  -- ^ primop is async call, primop returns the next
                                 --     function to run. result returned to stack top in registers

isInlinePrimOp :: PrimOp -> Bool
isInlinePrimOp p = p `S.notMember` notInlinePrims
  where
    -- all primops that might block the thread or manipulate stack directly
    -- (and therefore might return PRPrimCall) must be listed here
    notInlinePrims = S.fromList
      [ CatchOp, RaiseOp, RaiseIOOp
      , MaskAsyncExceptionsOp, MaskUninterruptibleOp, UnmaskAsyncExceptionsOp
      , AtomicallyOp, RetryOp, CatchRetryOp, CatchSTMOp
      , TakeMVarOp, PutMVarOp, ReadMVarOp
      , DelayOp
      , WaitReadOp, WaitWriteOp
      , KillThreadOp
      , YieldOp
      , SeqOp
      ]


genPrim :: Type
        -> PrimOp   -- ^ the primitive operation
        -> [JExpr]  -- ^ where to store the result
        -> [JExpr]  -- ^ arguments
        -> PrimRes
genPrim _ CharGtOp          [r] [x,y] = PrimInline [j| `r` = (`x` > `y`) ? 1 : 0; |]
genPrim _ CharGeOp          [r] [x,y] = PrimInline [j| `r` = (`x` >= `y`) ? 1 : 0; |]
genPrim _ CharEqOp          [r] [x,y] = PrimInline [j| `r` = (`x` === `y`) ? 1 : 0; |]
genPrim _ CharNeOp          [r] [x,y] = PrimInline [j| `r` = (`x` !== `y`) ? 1 : 0; |]
genPrim _ CharLtOp          [r] [x,y] = PrimInline [j| `r` = (`x` < `y`) ? 1 : 0; |]
genPrim _ CharLeOp          [r] [x,y] = PrimInline [j| `r` = (`x` <= `y`) ? 1 : 0; |]
genPrim _ OrdOp             [r] [x]   = PrimInline [j| `r` = `x` |]

genPrim _ IntAddOp          [r] [x,y] = PrimInline [j| `r` = (`x` + `y`)|0 |]
genPrim _ IntSubOp          [r] [x,y] = PrimInline [j| `r` = (`x` - `y`)|0 |]
genPrim _ IntMulOp          [r] [x,y] =
    PrimInline [j| `r` = h$mulInt32(`x`,`y`); |]
-- fixme may will give the wrong result in case of overflow
genPrim _ IntMulMayOfloOp   [r] [x,y] =
    PrimInline [j| var tmp = (`x`*`y`); `r` = (tmp===(tmp|0))?0:1; |]
genPrim _ IntQuotOp         [r] [x,y] = PrimInline [j| `r` = (`x`/`y`)|0; |]
genPrim _ IntRemOp          [r] [x,y] = PrimInline [j| `r` = `x` % `y` |]
genPrim _ IntQuotRemOp    [q,r] [x,y] = PrimInline [j| `q` = (`x`/`y`)|0;
                                                       `r` = `x`-`y`*`q`;
                                                     |]
genPrim _ AndIOp [r] [x,y]            = PrimInline [j| `r` = `x` & `y`; |]
genPrim _ OrIOp  [r] [x,y]            = PrimInline [j| `r` = `x` | `y`; |]
genPrim _ XorIOp [r] [x,y]            = PrimInline [j| `r` = `x` ^ `y`; |]
genPrim _ NotIOp [r] [x]              = PrimInline [j| `r` = ~`x`; |]

genPrim _ IntNegOp          [r] [x]   = PrimInline [j| `r` = `jneg x`|0; |]
-- add with carry: overflow == 0 iff no overflow
genPrim _ IntAddCOp         [r,overf] [x,y] =
  PrimInline [j| var rt = `x`+`y`; `r` = rt|0; `overf` = (`r`!=rt)?1:0; |]
genPrim _ IntSubCOp         [r,overf] [x,y] =
  PrimInline [j| var rt = `x`-`y`; `r` = rt|0; `overf` = (`r`!=rt)?1:0; |]
genPrim _ IntGtOp           [r] [x,y] = PrimInline [j| `r` = (`x` > `y`) ? 1 : 0 |]
genPrim _ IntGeOp           [r] [x,y] = PrimInline [j| `r`= (`x` >= `y`) ? 1 : 0 |]
genPrim _ IntEqOp           [r] [x,y] = PrimInline [j| `r` = (`x` === `y`) ? 1 : 0 |]
genPrim _ IntNeOp           [r] [x,y] = PrimInline [j| `r` = (`x` !== `y`) ? 1 : 0 |]
genPrim _ IntLtOp           [r] [x,y] = PrimInline [j| `r` = (`x` < `y`) ? 1 : 0 |]
genPrim _ IntLeOp           [r] [x,y] = PrimInline [j| `r` = (`x` <= `y`) ? 1 : 0 |]
genPrim _ ChrOp             [r] [x]   = PrimInline [j| `r` = `x` |]
genPrim _ Int2WordOp        [r] [x]   = PrimInline [j| `r` = `x` |]
genPrim _ Int2FloatOp       [r] [x]   = PrimInline [j| `r` = `x` |]
genPrim _ Int2DoubleOp      [r] [x]   = PrimInline [j| `r` = `x` |]
genPrim _ ISllOp            [r] [x,y] = PrimInline [j| `r` = `x` << `y` |]
genPrim _ ISraOp            [r] [x,y] = PrimInline [j| `r` = `x` >> `y` |]
genPrim _ ISrlOp            [r] [x,y] = PrimInline [j| `r` = `x` >>> `y` |]
genPrim _ WordAddOp         [r] [x,y] = PrimInline [j| `r` = (`x` + `y`)|0; |]
genPrim _ WordAdd2Op      [h,l] [x,y] = PrimInline [j| `h` = h$wordAdd2(`x`,`y`);
                                                       `l` = `Ret1`;
                                                     |]
genPrim _ WordSubOp         [r] [x,y] = PrimInline [j| `r` = (`x` - `y`)|0 |]
genPrim _ WordMulOp         [r] [x,y] =
  PrimInline [j| `r` = h$mulWord32(`x`,`y`); |]
genPrim _ WordMul2Op      [h,l] [x,y] =
  PrimInline [j| `h` = h$mul2Word32(`x`,`y`);
                 `l` = `Ret1`;
               |]
genPrim _ WordQuotOp        [q] [x,y] = PrimInline [j| `q` = h$quotWord32(`x`,`y`); |]
genPrim _ WordRemOp         [r] [x,y] = PrimInline [j| `r`= h$remWord32(`x`,`y`); |]
genPrim _ WordQuotRemOp   [q,r] [x,y] = PrimInline [j| `q` = h$quotWord32(`x`,`y`);
                                                     `r` = h$remWord32(`x`, `y`);
                                                  |]
genPrim _ WordQuotRem2Op   [q,r] [xh,xl,y] = PrimInline [j| `q` = h$quotRem2Word32(`xh`,`xl`,`y`);
                                                            `r` = `Ret1`;
                                                          |]
genPrim _ AndOp             [r] [x,y] = PrimInline [j| `r` = `x` & `y` |]
genPrim _ OrOp              [r] [x,y] = PrimInline [j| `r` = `x` | `y` |]
genPrim _ XorOp             [r] [x,y] = PrimInline [j| `r` = `x` ^ `y` |]
genPrim _ NotOp             [r] [x]   = PrimInline [j| `r` = ~`x` |]
genPrim _ SllOp             [r] [x,y] = PrimInline [j| `r` = `x` << `y` |]
genPrim _ SrlOp             [r] [x,y] = PrimInline [j| `r` = `x` >>> `y` |]
genPrim _ Word2IntOp        [r] [x]   = PrimInline [j| `r` = `x` |]
genPrim _ WordGtOp          [r] [x,y] =
  PrimInline [j| `r` = ((`x`>>>1) > (`y`>>>1) || ((`x`>>>1) == (`y`>>>1) && (`x`&1) > (`y`&1))) ? 1 : 0 |]
genPrim _ WordGeOp          [r] [x,y] =
  PrimInline [j| `r` = ((`x`>>>1) > (`y`>>>1) || ((`x`>>>1) == (`y`>>>1) && (`x`&1) >= (`y`&1))) ? 1 : 0 |]
genPrim _ WordEqOp          [r] [x,y] = PrimInline [j| `r` = (`x` === `y`) ? 1 : 0 |]
genPrim _ WordNeOp          [r] [x,y] = PrimInline [j| `r` = (`x` !== `y`) ? 1 : 0 |]
genPrim _ WordLtOp          [r] [x,y] =
  PrimInline [j| `r` = ((`x`>>>1) < (`y`>>>1) || ((`x`>>>1) == (`y`>>>1) && (`x`&1) < (`y`&1))) ? 1 : 0 |]
genPrim _ WordLeOp          [r] [x,y] =
  PrimInline [j| `r` = ((`x`>>>1) < (`y`>>>1) || ((`x`>>>1) == (`y`>>>1) && (`x`&1) <= (`y`&1))) ? 1 : 0 |]
genPrim _ Word2DoubleOp     [r] [x] = PrimInline [j| `r` = (`x` & 0x7FFFFFFF) + (`x` >>> 31) * 2147483648 |]
genPrim _ Word2FloatOp      [r] [x] = PrimInline [j| `r` = (`x` & 0x7FFFFFFF) + (`x` >>> 31) * 2147483648 |]
genPrim _ PopCnt8Op         [r] [x]   = PrimInline [j| `r` = h$popCntTab[`x` & 0xFF] |]
genPrim _ PopCnt16Op        [r] [x]   =
  PrimInline [j| `r` = h$popCntTab[`x`&0xFF] +
                       h$popCntTab[(`x`>>>8)&0xFF]
               |]
genPrim _ PopCnt32Op        [r] [x]   = PrimInline [j| `r` = h$popCnt32(`x`); |]
genPrim _ PopCnt64Op        [r] [x1,x2] = PrimInline [j| `r` = h$popCnt64(`x1`,`x2`); |]
genPrim t PopCntOp          [r] [x]   = genPrim t PopCnt32Op [r] [x]

genPrim _ BSwap16Op         [r] [x]   = PrimInline [j| `r` = ((`x` & 0xFF) << 8) | ((`x` & 0xFF00) >> 8); |] -- ab -> ba
genPrim _ BSwap32Op         [r] [x]   = PrimInline [j| `r` = (`x` << 24) | ((`x` & 0xFF00) << 8)
                                                           | ((`x` & 0xFF0000) >> 8) | (`x` >>> 24);
                                                     |] -- abcd -> dcba
genPrim _ BSwap64Op     [r1,r2] [x,y] = PrimInline [j| `r1` = h$bswap64(`x`,`y`);
                                                       `r2` = `Ret1`;
                                                     |]
genPrim t BSwapOp           [r] [x]   = genPrim t BSwap32Op [r] [x]

genPrim _ Narrow8IntOp      [r] [x]   = PrimInline [j| `r` = (`x` & 0x7F)-(`x` & 0x80) |]
genPrim _ Narrow16IntOp     [r] [x]   = PrimInline [j| `r` = (`x` & 0x7FFF)-(`x` & 0x8000) |]
genPrim _ Narrow32IntOp     [r] [x]   = PrimInline [j| `r` = `x`|0 |]
genPrim _ Narrow8WordOp     [r] [x]   = PrimInline [j| `r` = (`x` & 0xFF) |]
genPrim _ Narrow16WordOp    [r] [x]   = PrimInline [j| `r` = (`x` & 0xFFFF) |]
genPrim _ Narrow32WordOp    [r] [x]   = PrimInline [j| `r` = `x`|0 |]
genPrim _ DoubleGtOp        [r] [x,y] = PrimInline [j| `r` = (`x` > `y`) ? 1 : 0 |]
genPrim _ DoubleGeOp        [r] [x,y] = PrimInline [j| `r` = (`x` >= `y`) ? 1 : 0 |]
genPrim _ DoubleEqOp        [r] [x,y] = PrimInline [j| `r` = (`x` === `y`) ? 1 : 0 |]
genPrim _ DoubleNeOp        [r] [x,y] = PrimInline [j| `r` = (`x` !== `y`) ? 1 : 0 |]
genPrim _ DoubleLtOp        [r] [x,y] = PrimInline [j| `r` = (`x` < `y`) ? 1 : 0 |]
genPrim _ DoubleLeOp        [r] [x,y] = PrimInline [j| `r` = (`x` <= `y`) ? 1 : 0 |]
genPrim _ DoubleAddOp       [r] [x,y] = PrimInline [j| `r` = `x` + `y` |]
genPrim _ DoubleSubOp       [r] [x,y] = PrimInline [j| `r` = `x` - `y` |]
genPrim _ DoubleMulOp       [r] [x,y] = PrimInline [j| `r` = `x` * `y` |]
genPrim _ DoubleDivOp       [r] [x,y] = PrimInline [j| `r` = `x` / `y` |]
genPrim _ DoubleNegOp       [r] [x]   = PrimInline [j| `r` = `jneg x` |] -- fixme negate
genPrim _ Double2IntOp      [r] [x]   = PrimInline [j| `r` = `x`|0; |]
genPrim _ Double2FloatOp    [r] [x]   = PrimInline [j| `r` = `x` |]
genPrim _ DoubleExpOp       [r] [x]   = PrimInline [j| `r` = Math.exp(`x`) |]
genPrim _ DoubleLogOp       [r] [x]   = PrimInline [j| `r` = Math.log(`x`) |]
genPrim _ DoubleSqrtOp      [r] [x]   = PrimInline [j| `r` = Math.sqrt(`x`) |]
genPrim _ DoubleSinOp       [r] [x]   = PrimInline [j| `r` = Math.sin(`x`) |]
genPrim _ DoubleCosOp       [r] [x]   = PrimInline [j| `r` = Math.cos(`x`) |]
genPrim _ DoubleTanOp       [r] [x]   = PrimInline [j| `r` = Math.tan(`x`) |]
genPrim _ DoubleAsinOp      [r] [x]   = PrimInline [j| `r` = Math.asin(`x`) |]
genPrim _ DoubleAcosOp      [r] [x]   = PrimInline [j| `r` = Math.acos(`x`) |]
genPrim _ DoubleAtanOp      [r] [x]   = PrimInline [j| `r` = Math.atan(`x`) |]
genPrim _ DoubleSinhOp      [r] [x]   = PrimInline [j| `r` = (Math.exp(`x`)-Math.exp(`jneg x`))/2 |]
genPrim _ DoubleCoshOp      [r] [x]   = PrimInline [j| `r` = (Math.exp(`x`)+Math.exp(`jneg x`))/2 |]
genPrim _ DoubleTanhOp      [r] [x]   = PrimInline [j| `r` = (Math.exp(2*`x`)-1)/(Math.exp(2*`x`)+1) |]
genPrim _ DoublePowerOp     [r] [x,y] = PrimInline [j| `r` = Math.pow(`x`,`y`) |]
genPrim _ DoubleDecode_2IntOp [s,h,l,e] [x] =
  PrimInline [j| `s` = h$decodeDouble2Int(`x`);
                 `h` = `Ret1`;
                 `l` = `Ret2`;
                 `e` = `Ret3`;
               |]
genPrim _ FloatGtOp         [r] [x,y] = PrimInline [j| `r` = (`x` > `y`) ? 1 : 0 |]
genPrim _ FloatGeOp         [r] [x,y] = PrimInline [j| `r` = (`x` >= `y`) ? 1 : 0 |]
genPrim _ FloatEqOp         [r] [x,y] = PrimInline [j| `r` = (`x` === `y`) ? 1 : 0 |]
genPrim _ FloatNeOp         [r] [x,y] = PrimInline [j| `r` = (`x` !== `y`) ? 1 : 0 |]
genPrim _ FloatLtOp         [r] [x,y] = PrimInline [j| `r` = (`x` < `y`) ? 1 : 0 |]
genPrim _ FloatLeOp         [r] [x,y] = PrimInline [j| `r` = (`x` <= `y`) ? 1 : 0 |]
genPrim _ FloatAddOp        [r] [x,y] = PrimInline [j| `r` = `x` + `y` |]
genPrim _ FloatSubOp        [r] [x,y] = PrimInline [j| `r` = `x` - `y` |]
genPrim _ FloatMulOp        [r] [x,y] = PrimInline [j| `r` = `x` * `y` |]
genPrim _ FloatDivOp        [r] [x,y] = PrimInline [j| `r` = `x` / `y` |]
genPrim _ FloatNegOp        [r] [x]   = PrimInline [j| `r` = `jneg x`  |]
genPrim _ Float2IntOp       [r] [x]   = PrimInline [j| `r` = `x`|0 |]
genPrim _ FloatExpOp        [r] [x]   = PrimInline [j| `r` = Math.exp(`x`) |]
genPrim _ FloatLogOp        [r] [x]   = PrimInline [j| `r` = Math.log(`x`) |]
genPrim _ FloatSqrtOp       [r] [x]   = PrimInline [j| `r` = Math.sqrt(`x`) |]
genPrim _ FloatSinOp        [r] [x]   = PrimInline [j| `r` = Math.sin(`x`) |]
genPrim _ FloatCosOp        [r] [x]   = PrimInline [j| `r` = Math.cos(`x`) |]
genPrim _ FloatTanOp        [r] [x]   = PrimInline [j| `r` = Math.tan(`x`) |]
genPrim _ FloatAsinOp       [r] [x]   = PrimInline [j| `r` = Math.asin(`x`) |]
genPrim _ FloatAcosOp       [r] [x]   = PrimInline [j| `r` = Math.acos(`x`) |]
genPrim _ FloatAtanOp       [r] [x]   = PrimInline [j| `r` = Math.atan(`x`) |]
genPrim _ FloatSinhOp       [r] [x]   = PrimInline [j| `r` = (Math.exp(`x`)-Math.exp(`jneg x`))/2 |]
genPrim _ FloatCoshOp       [r] [x]   = PrimInline [j| `r` = (Math.exp(`x`)+Math.exp(`jneg x`))/2 |]
genPrim _ FloatTanhOp       [r] [x]   = PrimInline [j| `r` = (Math.exp(2*`x`)-1)/(Math.exp(2*`x`)+1) |]
genPrim _ FloatPowerOp      [r] [x,y] = PrimInline [j| `r` = Math.pow(`x`,`y`) |]
genPrim _ Float2DoubleOp    [r] [x]   = PrimInline [j| `r` = `x` |]
genPrim _ FloatDecode_IntOp [s,e] [x] = PrimInline [j| `s` = h$decodeFloatInt(`x`); `e` = `Ret1`; |]
genPrim _ NewArrayOp          [r] [l,e]   = PrimInline (newArray r l e)
genPrim _ SameMutableArrayOp  [r] [a1,a2] = PrimInline [j| `r` = (`a1` === `a2`) ? 1 : 0 |]
genPrim _ ReadArrayOp         [r] [a,i]   = PrimInline [j| `r` = `a`[`i`]; |]
genPrim _ WriteArrayOp        []  [a,i,v] = PrimInline [j| `a`[`i`] = `v`; |]
genPrim _ SizeofArrayOp       [r] [a]     = PrimInline [j| `r` = `a`.length; |]
genPrim _ SizeofMutableArrayOp [r] [a]    = PrimInline [j| `r` = `a`.length; |]
genPrim _ IndexArrayOp        [r] [a,i]   = PrimInline [j| `r` = `a`[`i`]; |]
genPrim _ UnsafeFreezeArrayOp [r] [a]     = PrimInline [j| `r` = `a`; |]
genPrim _ UnsafeThawArrayOp   [r] [a]     = PrimInline [j| `r` = `a`; |]
genPrim _ CopyArrayOp         [] [a,o1,ma,o2,n] =
  PrimInline [j| for(var i=0;i<`n`;i++) {
                   `ma`[i+`o2`] = `a`[i+`o1`];
                 }
               |]
genPrim t CopyMutableArrayOp  [] [a1,o1,a2,o2,n] = genPrim t CopyArrayOp [] [a1,o1,a2,o2,n]
genPrim _ CloneArrayOp        [r] [a,start,n] =
  PrimInline [j| `r` = h$sliceArray(`a`,`start`,`n`) |]
genPrim t CloneMutableArrayOp [r] [a,start,n] = genPrim t CloneArrayOp [r] [a,start,n]
genPrim _ FreezeArrayOp       [r] [a,start,n] =
  PrimInline [j| `r` = h$sliceArray(`a`,`start`,`n`); |]
genPrim _ ThawArrayOp         [r] [a,start,n] =
  PrimInline [j| `r` = h$sliceArray(`a`,`start`,`n`); |]
genPrim _ NewByteArrayOp_Char [r] [l] = PrimInline (newByteArray r l)
genPrim _ NewPinnedByteArrayOp_Char [r] [l] = PrimInline (newByteArray r l)
genPrim _ NewAlignedPinnedByteArrayOp_Char [r] [l,align] = PrimInline (newByteArray r l)
genPrim _ ByteArrayContents_Char [a,o] [b] = PrimInline [j| `a` = `b`; `o` = 0; |]
genPrim _ SameMutableByteArrayOp [r] [a,b] = PrimInline [j| `r` = (`a` === `b`) ? 1 : 0 |]
genPrim _ UnsafeFreezeByteArrayOp [a] [b] = PrimInline [j| `a` = `b`; |]
genPrim _ SizeofByteArrayOp [r] [a] = PrimInline [j| `r` = `a`.len; |]
genPrim _ SizeofMutableByteArrayOp [r] [a] = PrimInline [j| `r` = `a`.len; |]
genPrim _ IndexByteArrayOp_Char [r] [a,i] = PrimInline [j| `r` = `a`.u8[`i`]; |]
genPrim _ IndexByteArrayOp_WideChar [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ IndexByteArrayOp_Int [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ IndexByteArrayOp_Word [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ IndexByteArrayOp_Addr [r1,r2] [a,i] = PrimInline [j| if(`a`.arr && `a`.arr[`i`<<2]) {
                                                                 `r1` = `a`.arr[`i`<<2][0];
                                                                 `r2` = `a`.arr[`i`<<2][1];
                                                               } else {
                                                                 `r1` = null;
                                                                 `r2` = 0;
                                                               }
                                                             |]
genPrim _ IndexByteArrayOp_Float [r] [a,i] = PrimInline [j| `r` = `a`.f3[`i`]; |]
genPrim _ IndexByteArrayOp_Double [r] [a,i] = PrimInline [j| `r` = `a`.f6[`i`]; |]
-- genPrim _ IndexByteArrayOp_StablePtr
genPrim _ IndexByteArrayOp_Int8 [r] [a,i] = PrimInline [j| `r` = `a`.dv.getInt8(`i`,true); |]
genPrim _ IndexByteArrayOp_Int16 [r] [a,i] = PrimInline [j| `r` = `a`.dv.getInt16(`i`<<1,true); |]
genPrim _ IndexByteArrayOp_Int32 [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ IndexByteArrayOp_Int64 [r1,r2] [a,i] =
  PrimInline [j| `r1` = `a`.i3[`i`<<1];
                 `r2` = `a`.i3[(`i`<<1)+1];
               |]
genPrim _ IndexByteArrayOp_Word8 [r] [a,i] = PrimInline [j| `r` = `a`.u8[`i`]; |]
genPrim _ IndexByteArrayOp_Word16 [r] [a,i] = PrimInline [j| `r` = `a`.dv.getUint16(`i`<<1,true); |]
genPrim _ IndexByteArrayOp_Word32 [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ IndexByteArrayOp_Word64 [r1,r2] [a,i] =
  PrimInline [j| `r1` = `a`.i3[`i`<<1];
                 `r2` = `a`.i3[(`i`<<1)+1];
               |]
genPrim _ ReadByteArrayOp_Char [r] [a,i] = PrimInline [j| `r` = `a`.u8[`i`]; |]
genPrim _ ReadByteArrayOp_WideChar [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ ReadByteArrayOp_Int [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ ReadByteArrayOp_Word [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ ReadByteArrayOp_Addr [r1,r2] [a,i] = PrimInline [j| var x = `i`<<2;
                                                            if(`a`.arr && `a`.arr[x]) {
                                                              `r1` = `a`.arr[x][0];
                                                              `r2` = `a`.arr[x][1];
                                                            } else {
                                                              `r1` = null;
                                                              `r2` = 0;
                                                            }
                                                          |]
genPrim _ ReadByteArrayOp_Float [r] [a,i] = PrimInline [j| `r` = `a`.f3[`i`]; |]
genPrim _ ReadByteArrayOp_Double [r] [a,i] = PrimInline [j| `r` = `a`.f6[`i`]; |]
-- genPrim _ ReadByteArrayOp_StablePtr
genPrim _ ReadByteArrayOp_Int8 [r] [a,i] = PrimInline [j| `r` = `a`.dv.getInt8(`i`,true); |]
genPrim _ ReadByteArrayOp_Int16 [r] [a,i] = PrimInline [j| `r` = `a`.dv.getInt16(`i`<<1,true); |]
genPrim _ ReadByteArrayOp_Int32 [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ ReadByteArrayOp_Int64 [r1,r2] [a,i] =
  PrimInline [j| `r1` = `a`.i3[`i`<<1];
                 `r2` = `a`.i3[(`i`<<1)+1];
              |]
genPrim _ ReadByteArrayOp_Word8 [r] [a,i] = PrimInline [j| `r` = `a`.u8[`i`]; |]
genPrim _ ReadByteArrayOp_Word16 [r] [a,i] = PrimInline [j| `r` = `a`.u1[`i`]; |]
genPrim _ ReadByteArrayOp_Word32 [r] [a,i] = PrimInline [j| `r` = `a`.i3[`i`]; |]
genPrim _ ReadByteArrayOp_Word64 [r1,r2] [a,i] =
  PrimInline [j| `r1` = `a`.i3[`i`<<1];
                 `r2` = `a`.i3[(`i`<<1)+1];
               |]
genPrim _ WriteByteArrayOp_Char [] [a,i,e] = PrimInline [j| `a`.u8[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_WideChar [] [a,i,e] = PrimInline [j| `a`.i3[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_Int [] [a,i,e] = PrimInline [j| `a`.i3[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_Word [] [a,i,e] = PrimInline [j| `a`.i3[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_Addr [] [a,i,e1,e2] = PrimInline [j| if(!`a`.arr) { `a`.arr = []; }
                                                              `a`.arr[`i`<<2] = [`e1`,`e2`];
                                                            |]
genPrim _ WriteByteArrayOp_Float [] [a,i,e] = PrimInline [j| `a`.f3[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_Double [] [a,i,e] = PrimInline [j| `a`.f6[`i`] = `e`; |]
-- genPrim _ WriteByteArrayOp_StablePtr
genPrim _ WriteByteArrayOp_Int8 [] [a,i,e] = PrimInline [j| `a`.dv.setInt8(`i`, `e`, false); |]
genPrim _ WriteByteArrayOp_Int16 [] [a,i,e]     = PrimInline [j| `a`.dv.setInt16(`i`<<1, `e`, false); |]
genPrim _ WriteByteArrayOp_Int32 [] [a,i,e]     = PrimInline [j| `a`.i3[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_Int64 [] [a,i,e1,e2] =
  PrimInline [j| `a`.i3[`i`<<1] = `e1`;
                 `a`.i3[(`i`<<1)+1] = `e2`;
               |]
genPrim _ WriteByteArrayOp_Word8 [] [a,i,e]     = PrimInline [j| `a`.u8[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_Word16 [] [a,i,e]     = PrimInline [j| `a`.u1[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_Word32 [] [a,i,e]     = PrimInline [j| `a`.i3[`i`] = `e`; |]
genPrim _ WriteByteArrayOp_Word64 [] [a,i,e1,e2] =
  PrimInline [j| `a`.i3[`i`<<1] = `e1`;
                 `a`.i3[(`i`<<1)+1] = `e2`;
               |]
-- fixme we can do faster by copying 32 bit ints or doubles
genPrim _ CopyByteArrayOp [] [a1,o1,a2,o2,n] =
  PrimInline [j| for(var i=`n` - 1; i >= 0; i--) {
                   `a2`.u8[i+`o2`] = `a1`.u8[i+`o1`];
                 }
               |]
genPrim t CopyMutableByteArrayOp [] xs@[a1,o1,a2,o2,n] = genPrim t CopyByteArrayOp [] xs
genPrim _ SetByteArrayOp [] [a,o,n,v] =
  PrimInline [j| for(var i=0;i<`n`;i++) {
                   `a`.u8[`o`+i] = `v`;
                 }
               |]
genPrim _ NewArrayArrayOp [r] [n] = PrimInline (newArray r n jnull)
genPrim _ SameMutableArrayArrayOp [r] [a1,a2] = PrimInline [j| `r` = (`a1` === `a2`) ? 1 : 0 |]
genPrim _ UnsafeFreezeArrayArrayOp [r] [a] = PrimInline [j| `r` = `a` |]
genPrim _ SizeofArrayArrayOp [r] [a] = PrimInline [j| `r` = `a`.length; |]
genPrim _ SizeofMutableArrayArrayOp [r] [a] = PrimInline [j| `r` = `a`.length; |]
genPrim _ IndexArrayArrayOp_ByteArray [r] [a,n] = PrimInline [j| `r` = `a`[`n`] |]
genPrim _ IndexArrayArrayOp_ArrayArray [r] [a,n] = PrimInline [j| `r` = `a`[`n`] |]
genPrim _ ReadArrayArrayOp_ByteArray [r] [a,n] = PrimInline [j| `r` = `a`[`n`] |]
genPrim _ ReadArrayArrayOp_MutableByteArray [r] [a,n] = PrimInline [j| `r` = `a`[`n`] |]
genPrim _ ReadArrayArrayOp_ArrayArray [r] [a,n] = PrimInline [j| `r` = `a`[`n`] |]
genPrim _ ReadArrayArrayOp_MutableArrayArray [r] [a,n] = PrimInline [j| `r` = `a`[`n`] |]
genPrim _ WriteArrayArrayOp_ByteArray [] [a,n,v] = PrimInline [j| `a`[`n`] = `v` |]
genPrim _ WriteArrayArrayOp_MutableByteArray [] [a,n,v] = PrimInline [j| `a`[`n`] = `v` |]
genPrim _ WriteArrayArrayOp_ArrayArray [] [a,n,v] = PrimInline [j| `a`[`n`] = `v` |]
genPrim _ WriteArrayArrayOp_MutableArrayArray [] [a,n,v] = PrimInline [j| `a`[`n`] = `v` |]
genPrim _ CopyArrayArrayOp [] [a1,o1,a2,o2,n] =
  PrimInline [j| for(var i=0;i<`n`;i++) { `a2`[i+`o2`]=`a1`[i+`o1`]; } |]
genPrim _ CopyMutableArrayArrayOp [] [a1,o1,a2,o2,n] =
  PrimInline [j| for(var i=0;i<`n`;i++) { `a2`[i+`o2`]=`a1`[i+`o1`]; } |]

genPrim _ AddrAddOp  [a',o'] [a,o,i]   = PrimInline [j| `a'` = `a`; `o'` = `o` + `i`;|]
genPrim _ AddrSubOp  [i] [a1,o1,a2,o2] = PrimInline [j| `i` = `o1` - `o2` |]
genPrim _ AddrRemOp  [r] [a,o,i]   = PrimInline [j| `r` = `o` % `i` |]
genPrim _ Addr2IntOp [i]     [a,o]     = PrimInline [j| `i` = `o`; |] -- only usable for comparisons within one range
genPrim _ Int2AddrOp [a,o]   [i]       = PrimInline [j| `a` = []; `o` = `i`; |] -- unsupported
genPrim _ AddrGtOp   [r] [a1,o1,a2,o2] = PrimInline [j| `r` = (`o1` >  `o2`) ? 1 : 0; |]
genPrim _ AddrGeOp   [r] [a1,o1,a2,o2] = PrimInline [j| `r` = (`o1` >= `o2`) ? 1 : 0; |]
genPrim _ AddrEqOp   [r] [a1,o1,a2,o2] = PrimInline [j| `r` = (`a1` === `a2` && `o1` === `o2`) ? 1 : 0; |]
genPrim _ AddrNeOp   [r] [a1,o1,a2,o2] = PrimInline [j| `r` = (`a1` === `a2` && `o1` === `o2`) ? 1 : 0; |]
genPrim _ AddrLtOp   [r] [a1,o1,a2,o2] = PrimInline [j| `r` = (`o1` <  `o2`) ? 1 : 0; |]
genPrim _ AddrLeOp   [r] [a1,o1,a2,o2] = PrimInline [j| `r` = (`o1` <= `o2`) ? 1 : 0; |]

-- addr indexing: unboxed arrays
genPrim _ IndexOffAddrOp_Char [c] [a,o,i] = PrimInline [j| `c` = `a`.u8[`o`+`i`]; |]
genPrim _ IndexOffAddrOp_WideChar [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getUint32(`o`+(`i`<<2),true); |]

genPrim _ IndexOffAddrOp_Int [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt32(`o`+(`i`<<2),true); |]
genPrim _ IndexOffAddrOp_Word [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt32(`o`+(`i`<<2),true); |]
genPrim _ IndexOffAddrOp_Addr [ca,co] [a,o,i] =
  PrimInline [j| if(`a`.arr && `a`.arr[`o`+(`i`<<2)]) {
                   `ca` = `a`.arr[`o`+(`i`<<2)][0];
                   `co` = `a`.arr[`o`+(`i`<<2)][1];
                 } else {
                   `ca` = null;
                   `co` = 0;
                 }
              |]
genPrim _ IndexOffAddrOp_Float [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getFloat32(`o`+(`i`<<2),true); |]
genPrim _ IndexOffAddrOp_Double [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getFloat64(`o`+(`i`<<3),true); |]
{-
IndexOffAddrOp_StablePtr
-}
genPrim _ IndexOffAddrOp_Int8 [c] [a,o,i] = PrimInline [j| `c` = `a`.u8[`o`+`i`]; |]
genPrim _ IndexOffAddrOp_Int16 [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt16(`o`+(`i`<<1),true); |]
genPrim _ IndexOffAddrOp_Int32 [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt32(`o`+(`i`<<2),true); |]
genPrim _ IndexOffAddrOp_Int64 [c1,c2] [a,o,i] =
   PrimInline [j| `c1` = `a`.dv.getInt32(`o`+(`i`<<3),true);
                  `c2` = `a`.dv.getInt32(`o`+(`i`<<3)+4,true);
                |]
genPrim _ IndexOffAddrOp_Word8 [c] [a,o,i] = PrimInline [j| `c` = `a`.u8[`o`+`i`]; |]
genPrim _ IndexOffAddrOp_Word16 [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getUint16(`o`+(`i`<<1),true); |]
genPrim _ IndexOffAddrOp_Word32 [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt32(`o`+(`i`<<2),true); |]
genPrim _ IndexOffAddrOp_Word64 [c1,c2] [a,o,i] =
   PrimInline [j| `c1` = `a`.dv.getInt32(`o`+(`i`<<3),true);
                  `c2` = `a`.dv.getInt32(`o`+(`i`<<3)+4,true);
                |]
genPrim _ ReadOffAddrOp_Char [c] [a,o,i] =
   PrimInline [j| `c` = `a`.u8[`o`+`i`]; |]
genPrim _ ReadOffAddrOp_WideChar [c] [a,o,i] =
   PrimInline [j| `c` = `a`.dv.getUint32(`o`+(`i`<<2),true); |]
genPrim _ ReadOffAddrOp_Int [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt32(`o`+(`i`<<2),true); |]
genPrim _ ReadOffAddrOp_Word [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getUint32(`o`+(`i`<<2),true); |]
genPrim _ ReadOffAddrOp_Addr [c1,c2] [a,o,i] =
  PrimInline [j| var x = `i`<<2;
                 if(`a`.arr && `a`.arr[`o`+ x]) {
                   `c1` = `a`.arr[`o`+ x][0];
                   `c2` = `a`.arr[`o`+ x][1];
                 } else {
                   `c1` = null;
                   `c2` = 0;
                 }
               |]
genPrim _ ReadOffAddrOp_Float [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getFloat32(`o`+(`i`<2),true); |]
genPrim _ ReadOffAddrOp_Double [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getFloat64(`o`+(`i`<<3),true); |]
-- ReadOffAddrOp_StablePtr -- fixme
genPrim _ ReadOffAddrOp_Int8   [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt8(`o`+`i`); |]
genPrim _ ReadOffAddrOp_Int16  [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt16(`o`+(`i`<<1),true); |]
genPrim _ ReadOffAddrOp_Int32  [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getInt32(`o`+(`i`<<2),true); |]
genPrim _ ReadOffAddrOp_Word8  [c] [a,o,i] = PrimInline [j| `c` = `a`.u8[`o`+`i`]; |]
genPrim _ ReadOffAddrOp_Word16 [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getUint16(`o`+(`i`<<1),true); |]
genPrim _ ReadOffAddrOp_Word32 [c] [a,o,i] = PrimInline [j| `c` = `a`.dv.getUint32(`o`+(`i`<<2),true); |]
genPrim _ ReadOffAddrOp_Word64 [c1,c2] [a,o,i] =
   PrimInline [j| `c1` = `a`.dv.getInt32(`o`+(`i`<<3),true);
                  `c2` = `a`.dv.getInt32(`o`+(`i`<<3)+4,true);
                |]
genPrim _ WriteOffAddrOp_Char [] [a,o,i,v]     = PrimInline [j| `a`.u8[`o`+`i`] = `v`; |]
genPrim _ WriteOffAddrOp_WideChar [] [a,o,i,v] = PrimInline [j| `a`.dv.setUint32(`o`+(`i`<<2), `v`,true); |]
genPrim _ WriteOffAddrOp_Int [] [a,o,i,v]     = PrimInline [j| `a`.dv.setInt32(`o`+(`i`<<2), `v`,true); |]
genPrim _ WriteOffAddrOp_Word [] [a,o,i,v]    = PrimInline [j| `a`.dv.setInt32(`o`+(`i`<<2), `v`,true); |]
genPrim _ WriteOffAddrOp_Addr [] [a,o,i,va,vo] =
  PrimInline [j| if(!`a`.arr) { `a`.arr = []; }
                 `a`.arr[`o`+(`i`<<2)] = [`va`,`vo`];
               |]
genPrim _ WriteOffAddrOp_Float [] [a,o,i,v]   = PrimInline [j| `a`.dv.setFloat32(`o`+(`i`<<2), `v`,true); |]
genPrim _ WriteOffAddrOp_Double [] [a,o,i,v]  = PrimInline [j| `a`.dv.setFloat64(`o`+(`i`<<3),`v`,true); |]
-- WriteOffAddrOp_StablePtr
genPrim _ WriteOffAddrOp_Int8 [] [a,o,i,v]    = PrimInline [j| `a`.dv.setInt8(`o`+`i`, `v`); |]
genPrim _ WriteOffAddrOp_Int16 [] [a,o,i,v]   = PrimInline [j| `a`.dv.setInt16(`o`+(`i`<<1), `v`, true); |]
genPrim _ WriteOffAddrOp_Int32 [] [a,o,i,v]   = PrimInline [j| `a`.dv.setInt32(`o`+(`i`<<2), `v`, true); |]
genPrim _ WriteOffAddrOp_Int64 [] [a,o,i,v1,v2] = PrimInline [j| `a`.dv.setInt32(`o`+(`i`<<3), `v1`, true);
                                                               `a`.dv.setInt32(`o`+(`i`<<3)+4, `v2`, true);
                                                             |]
genPrim _ WriteOffAddrOp_Word8 [] [a,o,i,v]   = PrimInline [j| `a`.u8[`o`+`i`] = `v`; |]
genPrim _ WriteOffAddrOp_Word16 [] [a,o,i,v]  = PrimInline [j| `a`.dv.setUint16(`o`+(`i`<<1), `v`, true); |]
genPrim _ WriteOffAddrOp_Word32 [] [a,o,i,v]  = PrimInline [j| `a`.dv.setUint32(`o`+(`i`<<2), `v`, true); |]
genPrim _ WriteOffAddrOp_Word64 [] [a,o,i,v1,v2] = PrimInline [j| `a`.dv.setUint32(`o`+(`i`<<3), `v1`, true);
                                                                 `a`.dv.setUint32(`o`+(`i`<<3)+4, `v2`, true);
                                                               |]
genPrim _ NewMutVarOp       [r] [x]   = PrimInline [j| `r` = new h$MutVar(`x`);  |]
genPrim _ ReadMutVarOp      [r] [m]   = PrimInline [j| `r` = `m`.val; |]
genPrim _ WriteMutVarOp     [] [m,x]  = PrimInline [j| `m`.val = `x`; |]
genPrim _ SameMutVarOp      [r] [x,y] =
  PrimInline [j| `r` = (`x` === `y`) ? 1 : 0; |]
genPrim _ AtomicModifyMutVarOp [r] [m,f] =
  PrimInline [j| `r` = h$atomicModifyMutVar(`m`,`f`); |]
genPrim _ CasMutVarOp [status,r] [mv,o,n] =
  PrimInline [j| if(`mv`.val === `o`) {
                    `status` = 0;
                    `r` = `mv`.val;
                    `mv`.val = `n`;
                 } else {
                    `status` = 1;
                    `r` = `mv`.val;
                 }
               |]
genPrim _ CatchOp [r] [a,handler] = PRPrimCall
  [j| return h$catch(`a`, `handler`); |]
genPrim _ RaiseOp         [b] [a] = PRPrimCall [j| return h$throw(`a`,false); |]
genPrim _ RaiseIOOp       [b] [a] = PRPrimCall [j| return h$throw(`a`,false); |]

genPrim _ MaskAsyncExceptionsOp [r] [a] =
  PRPrimCall [j| return h$maskAsync(`a`); |]
genPrim _ MaskUninterruptibleOp [r] [a] =
  PRPrimCall [j| return h$maskUnintAsync(`a`); |]
genPrim _ UnmaskAsyncExceptionsOp [r] [a] =
  PRPrimCall [j| return h$unmaskAsync(`a`); |]

genPrim _ MaskStatus [r] [] = PrimInline [j| `r` = h$maskStatus(); |]

genPrim _ AtomicallyOp [r] [a] = PRPrimCall [j| return h$atomically(`a`); |]
genPrim _ RetryOp [r] [] = PRPrimCall [j| return h$stmRetry(); |]
genPrim _ CatchRetryOp [r] [a,b] = PRPrimCall [j| return h$stmCatchRetry(`a`,`b`); |]
genPrim _ CatchSTMOp [r] [a,h] = PRPrimCall [j| return h$catchStm(`a`,`h`); |]
genPrim _ Check [r] [a] = PrimInline [j| `r` = h$stmCheck(`a`); |]
genPrim _ NewTVarOp [tv] [v] = PrimInline [j| `tv` = h$newTVar(`v`); |]
genPrim _ ReadTVarOp [r] [tv] = PrimInline [j| `r` = h$readTVar(`tv`); |]
genPrim _ ReadTVarIOOp [r] [tv] = PrimInline [j| `r` = h$readTVarIO(`tv`); |]
genPrim _ WriteTVarOp [] [tv,v] = PrimInline [j| h$writeTVar(`tv`,`v`); |]
genPrim _ SameTVarOp [r] [tv1,tv2] = PrimInline [j| `r` = h$sameTVar(`tv1`,`tv2`) ? 1 : 0; |]

genPrim _ NewMVarOp [r] []   = PrimInline [j| `r` = new h$MVar(); |]
genPrim _ TakeMVarOp [r] [m] = PRPrimCall [j| return h$takeMVar(`m`); |]
genPrim _ TryTakeMVarOp [r,v] [m] = PrimInline [j| `r` = h$tryTakeMVar(`m`);
                                                 `v` = `Ret1`;
                                              |]
genPrim _ PutMVarOp [] [m,v] = PRPrimCall [j| return h$putMVar(`m`,`v`); |]
genPrim _ TryPutMVarOp [r] [m,v] = PrimInline [j| `r` = h$tryPutMVar(`m`,`v`) |]
genPrim _ ReadMVarOp [r] [m] = PRPrimCall [j| return h$readMVar(`m`); |]
genPrim _ TryReadMVarOp [r,v] [m] = PrimInline [j| `v` = `m`.val;
                                                 `r` = (`v`===null) ? 0 : 1;
                                               |]
genPrim _ SameMVarOp [r] [m1,m2] =
   PrimInline [j| `r` = (`m1` === `m2`) ? 1 : 0; |]
genPrim _ IsEmptyMVarOp [r] [m]  =
  PrimInline [j| `r` = (`m`.val === null) ? 1 : 0; |]

genPrim _ DelayOp [] [t] = PRPrimCall [j| return h$delayThread(`t`); |]
genPrim _ WaitReadOp [] [fd] = PRPrimCall [j| return h$waitRead(`fd`); |]
genPrim _ WaitWriteOp [] [fd] = PRPrimCall [j| return h$waitWrite(`fd`); |]
genPrim _ ForkOp [tid] [x] = PrimInline [j| `tid` = h$fork(`x`, true); |]
genPrim _ ForkOnOp [tid] [p,x] = PrimInline [j| `tid` = h$fork(`x`, true); |] -- ignore processor argument
genPrim _ KillThreadOp [] [tid,ex] =
  PRPrimCall [j| return h$killThread(`tid`,`ex`); |]
genPrim _ YieldOp [] [] = PRPrimCall [j| return h$yield(); |]
genPrim _ MyThreadIdOp [r] [] = PrimInline [j| `r` = h$currentThread; |]
genPrim _ LabelThreadOp [] [t,la,lo] = PrimInline [j| `t`.label = [la,lo]; |]
genPrim _ IsCurrentThreadBoundOp [r] [] = PrimInline [j| `r` = 1; |]
genPrim _ NoDuplicateOp [] [] = PrimInline mempty -- don't need to do anything as long as we have eager blackholing
genPrim _ ThreadStatusOp [stat,cap,locked] [tid] = PrimInline
  [j| `stat` = h$threadStatus(`tid`);
      `cap` = `Ret1`;
      `locked` = `Ret2`;
    |]
genPrim _ MkWeakOp [r] [o,b,c] = PrimInline [j| `r` = h$makeWeak(`o`,`b`,`c`); |]
genPrim _ MkWeakNoFinalizerOp [r] [o,b] = PrimInline [j| `r` = h$makeWeakNoFinalizer(`o`,`b`); |]
genPrim _ AddCFinalizerToWeakOp [r] [a1,a1o,a2,a2o,i,a3,a3o,w] =
  PrimInline [j| `r` = 1; |]
genPrim _ DeRefWeakOp        [f,v] [w] = PrimInline [j| `v` = `w`.val;
                                                      `f` = (`v`===null) ? 0 : 1;
                                                    |]
genPrim _ FinalizeWeakOp     [fl,fin] [w] =
  PrimInline [j| `fin` = h$finalizeWeak(`w`);
                 `fl`  = `Ret1`;
               |]
genPrim _ TouchOp [] [e] = PrimInline mempty -- fixme what to do?

genPrim _ MakeStablePtrOp [s1,s2] [a] = PrimInline [j| `s1` = h$makeStablePtr(`a`); `s2` = `Ret1`; |]
genPrim _ DeRefStablePtrOp [r] [s1,s2] = PrimInline [j| `r` = `s1`.arr[`s2`]; |]
genPrim _ EqStablePtrOp [r] [sa1,sa2,sb1,sb2] = PrimInline [j| `r` = (`sa1` === `sb1` && `sa2` === `sb2`) ? 1 : 0; |]

genPrim _ MakeStableNameOp [r] [a] = PrimInline [j| `r` = h$makeStableName(`a`); |]
genPrim _ EqStableNameOp [r] [s1,s2] = PrimInline [j| `r` = h$eqStableName(`s1`, `s2`); |]
genPrim _ StableNameToIntOp [r] [s] = PrimInline [j| `r` = h$stableNameInt(`s`); |]

genPrim _ ReallyUnsafePtrEqualityOp [r] [p1,p2] = PrimInline [j| `r` = `p1`===`p2`?1:0; |]
genPrim _ ParOp [r] [a] = PrimInline [j| `r` = 0; |]
{-
SparkOp
-}
genPrim _ SeqOp [r] [e] = PRPrimCall [j| return h$e(`e`); |]
{-
GetSparkOp
-}
genPrim _ NumSparks [r] [] = PrimInline [j| `r` = 0 |]
{-
ParGlobalOp
ParLocalOp
ParAtOp
ParAtAbsOp
ParAtRelOp
ParAtForNowOp
CopyableOp
NowFollowOp
-}
-- data may be the following:
-- false/true: bool
-- number: tag 0 (single constructor primitive data)
-- object: haskell heap object
genPrim t DataToTagOp [r] [d]
  | isBoolTy t        = PrimInline [j| `r` = `d`?1:0; |]
  | Just (tc, _) <- splitTyConApp_maybe t, isProductTyCon tc
                      = PrimInline [j| `r` = 0; |]
  | isAlgType t && not (isUnLiftedType t)
                      = PrimInline [j| `r` = `d`.f.a-1; |]
  | otherwise         =
      PrimInline [j| `r` = (`d`===true)?1:((typeof `d` === 'object')?(`d`.f.a-1):0) |]

genPrim t TagToEnumOp [r] [tag]
  | isBoolTy t = PrimInline [j| `r` = `tag`?true:false;  |]
  | otherwise  = PrimInline [j| `r` = h$tagToEnum(`tag`) |]
{-
AddrToAnyOp
MkApUpd0_Op
NewBCOOp
UnpackClosureOp
GetApStackValOp
GetCCSOfOp
GetCurrentCCSOp
-}
genPrim _ TraceEventOp [] [ed,eo] = PrimInline [j| h$traceEvent(`ed`,`eo`); |]
genPrim _ TraceMarkerOp [] [ed,eo] = PrimInline [j| h$traceMarker(`ed`, `eo`); |]

genPrim _ op rs as = PrimInline [j| throw `"unhandled primop: "++show op++" "++show (length rs, length as)`; |]
{-
genPrim _ op rs as = PrimInline [j| log(`"warning, unhandled primop: "++show op++" "++show (length rs, length as)`);
  `f`;
  `copyRes`;
|]
  where
    f = ApplStat (iex . TxtI . T.pack $ "h$prim_" ++ show op) as
    copyRes = mconcat $ zipWith (\r reg -> [j| `r` = `reg`; |]) rs (enumFrom Ret1)
-}

newByteArray :: JExpr -> JExpr -> JStat
newByteArray tgt len = [j| `tgt` = h$newByteArray(`len`); |]

newArray :: JExpr -> JExpr -> JExpr -> JStat
newArray tgt len elem = [j| `tgt` = h$newArray(`len`,`elem`); |]

two_24 :: Int
two_24 = 2^(24::Int)
