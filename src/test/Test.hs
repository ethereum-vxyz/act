{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}

module Main where

import EVM.ABI (AbiType(..))
import Test.Tasty
import Test.Tasty.QuickCheck
import Test.QuickCheck.Instances.ByteString()

import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.Set as Set
import qualified Data.Map as Map (empty)

import ErrM
import Lex (lexer)
import Parse (parse)
import Type (typecheck)
import Print (prettyBehaviour)
import Syntax (Interface(..), EthEnv(..), Decl(..))
import RefinedAst hiding (Mode)

import Debug.Trace
import Text.Pretty.Simple
import Data.Text.Lazy as T (unpack)


-- *** Test Cases *** --


main :: IO ()
main = defaultMain $ testGroup "act"
  [ testGroup "frontend"
    {-
       Generates a random concrete behaviour, prints it, runs it through the frontend
       (lex -> parse -> type), and then checks that the typechecked output matches the
       generated behaviour.

       If the generated behaviour contains some preconditions, then the structure of the
       fail spec is also checked.
    -}
    [ testProperty "single roundtrip" $ do
        behv@(Behaviour name _ contract iface preconds _ _ _) <- sized genBehv
        let actual = parse (lexer $ prettyBehaviour behv) >>= typecheck
            expected = if null preconds then
                [ S $ Map.empty, B behv ]
              else
                [ S $ Map.empty, B behv
                , B $ Behaviour name Fail contract iface [Neg $ mconcat preconds] [] [] Nothing ]
        return $ case actual of
          Ok a -> a == expected
          Bad _ -> False
    ]
  ]


-- ** QuickCheck Generators ** --


data Mode = Concrete | Symbolic deriving (Eq, Show)
data Names = Names { _ints :: [String]
                   , _bools :: [String]
                   , _bytes :: [String]
                   } deriving (Show)

{-
   Generates a random behaviour given a mode and a size.

   Concrete behaviours contain no variables and take no arguments.
   Symbolic behaviours take arguments in the interface and reference them in their expressions.

   Storage conditions are currently not generated.
-}
genBehv :: Int -> Gen Behaviour
genBehv n = do
  name <- ident
  contract <- ident
  ifname <- ident
  abiNames <- genNames
  preconditions <- listOf $ genExpBool abiNames n
  returns <- Just <$> genReturnExp abiNames n
  postconditions <- listOf $ genExpBool abiNames n
  iface <- Interface ifname <$> mkDecls abiNames
  return Behaviour { _name = name
                   , _mode = Pass
                   , _contract = contract
                   , _interface = iface
                   , _preconditions = preconditions
                   , _postconditions = postconditions
                   , _stateUpdates = []
                   , _returns = returns
                   }


mkDecls :: Names -> Gen [Decl]
mkDecls (Names ints bools bytes) = mapM mkDecl names
  where
    mkDecl (n, typ) = ((flip Decl) n) <$> (genType typ)
    names = prepare Integer ints ++ prepare Boolean bools ++ prepare ByteStr bytes
    prepare typ ns = (,typ) <$> ns


genType :: MType -> Gen AbiType
genType typ = case typ of
  Integer -> oneof [ AbiUIntType <$> validIntSize
                   , AbiIntType <$> validIntSize
                   , return AbiAddressType ]
  Boolean -> return AbiBoolType
  ByteStr -> oneof [ AbiBytesType <$> validBytesSize
                   --, return AbiBytesDynamicType -- TODO: needs frontend support
                   , return AbiStringType ]
  where
    validIntSize = elements [ x | x <- [8..256], x `mod` 8 == 0 ]
    validBytesSize = elements [1..32]


genReturnExp :: Names -> Int -> Gen ReturnExp
genReturnExp names n = oneof
  [ ExpInt <$> genExpInt names n
  , ExpBool <$> genExpBool names n
  , ExpBytes <$> genExpBytes names n
  ]


-- TODO: literals, cat slice, ITE, storage, ByStr
genExpBytes :: Names -> Int -> Gen (Exp ByteString)
genExpBytes names _ = oneof
  [ ByVar <$> (selectName ByteStr names)
  , return $ ByEnv Blockhash
  ]


-- TODO: ITE, storage
genExpBool :: Names -> Int -> Gen (Exp Bool)
genExpBool names 0 = oneof
  [ BoolVar <$> (selectName Boolean names)
  , LitBool <$> arbitrary
  ]
genExpBool names n = oneof
  [ liftM2 And subExpBool subExpBool
  , liftM2 Or subExpBool subExpBool
  , liftM2 Impl subExpBool subExpBool
  , liftM2 Eq subExpInt subExpInt
  , liftM2 NEq subExpInt subExpInt
  , liftM2 LE subExpInt subExpInt
  , liftM2 LEQ subExpInt subExpInt
  , liftM2 GEQ subExpInt subExpInt
  , liftM2 GE subExpInt subExpInt
  , Neg <$> subExpBool
  ]
  where subExpBool = genExpBool names (n `div` 2)
        subExpInt = genExpInt names (n `div` 2)


-- TODO: storage
genExpInt :: Names -> Int -> Gen (Exp Integer)
genExpInt names 0 = oneof
  [ LitInt <$> arbitrary
  , IntVar <$> (selectName Integer names)
  , return $ IntEnv Caller
  , return $ IntEnv Callvalue
  , return $ IntEnv Calldepth
  , return $ IntEnv Origin
  , return $ IntEnv Blocknumber
  , return $ IntEnv Difficulty
  , return $ IntEnv Chainid
  , return $ IntEnv Gaslimit
  , return $ IntEnv Coinbase
  , return $ IntEnv Timestamp
  , return $ IntEnv This
  , return $ IntEnv Nonce
  ]
genExpInt names n = oneof
  [ liftM2 Add subExpInt subExpInt
  , liftM2 Sub subExpInt subExpInt
  , liftM2 Mul subExpInt subExpInt
  , liftM2 Div subExpInt subExpInt
  , liftM2 Mod subExpInt subExpInt
  , liftM2 Exp subExpInt subExpInt
  , liftM3 ITE subExpBool subExpInt subExpInt
  ]
  where subExpInt = genExpInt names (n `div` 2)
        subExpBool = genExpBool names (n `div` 2)


selectName :: MType -> Names -> Gen String
selectName typ (Names ints bools bytes) = do
  let names = case typ of
                Integer -> ints
                Boolean -> bools
                ByteStr -> bytes
  idx <- elements [0..((length names)-1)]
  return $ names!!idx


-- |Generates a record type containing identifier names.
-- Ensures each generated name appears once only.
-- Names are seperated by type to ensure that e.g. an int expression does not reference a bool
genNames :: Gen Names
genNames = mkNames <$> (split <$> unique)
  where
    mkNames :: [[String]] -> Names
    mkNames cs = Names { _ints = cs!!0
                       , _bools = cs!!1
                       , _bytes = cs!!2
                       }

    unique :: Gen [String]
    unique = (Set.toList . Set.fromList <$> (listOf1 ident))
                `suchThat` (\l -> (length l) > 3)

    split :: Show a => [a] -> [[a]]
    split l = go (length l `div` 3) l
      where
        go _ [] = []
        go n xs = as : go n bs
          where (as,bs) = splitAt n xs


ident :: Gen String
ident = liftM2 (<>) (listOf1 (elements chars)) (listOf (elements $ chars <> digits))
          `suchThat` (`notElem` reserved)
  where
    chars = ['a'..'z'] <> ['A'..'Z']
    digits = ['0'..'9']
    reserved = -- TODO: add uintX intX and bytesX type names
      [ "behaviour", "of", "interface", "creates", "case", "returns", "storage", "noop", "iff"
      , "and", "not", "or", "true", "false", "mapping", "ensures", "invariants", "if", "then"
      , "else", "at", "uint", "int", "bytes", "address", "bool", "string", "newAddr" ]


-- ** Debugging Utils ** --


traceb :: Behaviour -> Behaviour
traceb b = trace (prettyBehaviour b) b

tracec :: String -> [Claim] -> [Claim]
tracec msg cs = trace ("\n" <> msg <> "\n\n" <> unpack (pShow cs)) cs

trace' :: Show a => a -> a
trace' x = trace (show x) x
