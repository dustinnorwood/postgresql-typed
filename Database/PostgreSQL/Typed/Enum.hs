{-# LANGUAGE TemplateHaskell, FlexibleInstances, MultiParamTypeClasses, DataKinds #-}
-- |
-- Module: Database.PostgreSQL.Typed.Enum
-- Copyright: 2015 Dylan Simon
-- 
-- Support for PostgreSQL enums.

module Database.PostgreSQL.Typed.Enum 
  ( PGEnum
  , pgEnumValues
  , makePGEnum
  ) where

import Control.Monad (when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.UTF8 as U
import Data.Typeable (Typeable)
import qualified Language.Haskell.TH as TH

import Database.PostgreSQL.Typed.Protocol
import Database.PostgreSQL.Typed.TH
import Database.PostgreSQL.Typed.Types
import Database.PostgreSQL.Typed.Dynamic

-- |A type based on a PostgreSQL enum. Automatically instantiated by 'makePGEnum'.
class (Eq a, Ord a, Enum a, Bounded a, Show a) => PGEnum a

-- |List of all the values in the enum along with their database names.
pgEnumValues :: PGEnum a => [(a, String)]
pgEnumValues = map (\e -> (e, show e)) $ enumFromTo minBound maxBound

-- |Create a new enum type corresponding to the given PostgreSQL enum type.
-- For example, if you have @CREATE TYPE foo AS ENUM (\'abc\', \'DEF\');@, then
-- @makePGEnum \"foo\" \"Foo\" (\"Foo_\"++)@ will be equivalent to:
-- 
-- > data Foo = Foo_abc | Foo_DEF deriving (Eq, Ord, Enum, Bounded, Typeable)
-- > instance Show Foo where show Foo_abc = "abc" ...
-- > instance PGType "foo"
-- > instance PGParameter "foo" Foo where ...
-- > instance PGColumn "foo" Foo where ...
-- > instance PGRep "foo" Foo
-- > instance PGEnum Foo where pgEnumValues = [(Foo_abc, "abc"), (Foo_DEF, "DEF")]
--
-- Requires language extensions: TemplateHaskell, FlexibleInstances, MultiParamTypeClasses, DeriveDataTypeable, DataKinds
makePGEnum :: String -- ^ PostgreSQL enum type name
  -> String -- ^ Haskell type to create
  -> (String -> String) -- ^ How to generate constructor names from enum values, e.g. @(\"Type_\"++)@
  -> TH.DecsQ
makePGEnum name typs valnf = do
  (_, vals) <- TH.runIO $ withTPGConnection $ \c ->
    pgSimpleQuery c $ "SELECT enumlabel FROM pg_catalog.pg_enum JOIN pg_catalog.pg_type t ON enumtypid = t.oid WHERE typtype = 'e' AND format_type(t.oid, -1) = " ++ pgQuote name ++ " ORDER BY enumsortorder"
  when (null vals) $ fail $ "makePGEnum: enum " ++ name ++ " not found"
  let 
    valn = map (\[PGTextValue v] -> let u = U.toString v in (TH.mkName $ valnf u, map (TH.IntegerL . fromIntegral) $ BS.unpack v, TH.StringL u)) vals
  dv <- TH.newName "x"
  return
    [ TH.DataD [] typn [] (map (\(n, _, _) -> TH.NormalC n []) valn) [''Eq, ''Ord, ''Enum, ''Bounded, ''Typeable]
    , TH.InstanceD [] (TH.ConT ''Show `TH.AppT` typt)
      [ TH.FunD 'show $ map (\(n, _, v) -> TH.Clause [TH.ConP n []]
        (TH.NormalB $ TH.LitE v) []) valn
      ]
    , TH.InstanceD [] (TH.ConT ''PGType `TH.AppT` typl) []
    , TH.InstanceD [] (TH.ConT ''PGParameter `TH.AppT` typl `TH.AppT` typt)
      [ TH.FunD 'pgEncode $ map (\(n, l, _) -> TH.Clause [TH.WildP, TH.ConP n []]
        (TH.NormalB $ TH.VarE 'BS.pack `TH.AppE` TH.ListE (map TH.LitE l)) []) valn
      ]
    , TH.InstanceD [] (TH.ConT ''PGColumn `TH.AppT` typl `TH.AppT` typt)
      [ TH.FunD 'pgDecode [TH.Clause [TH.WildP, TH.VarP dv]
        (TH.NormalB $ TH.CaseE (TH.VarE 'BS.unpack `TH.AppE` TH.VarE dv) $ map (\(n, l, _) ->
          TH.Match (TH.ListP (map TH.LitP l)) (TH.NormalB $ TH.ConE n) []) valn ++
          [TH.Match TH.WildP (TH.NormalB $ TH.AppE (TH.VarE 'error) $
            TH.InfixE (Just $ TH.LitE (TH.StringL ("pgDecode " ++ name ++ ": "))) (TH.VarE '(++)) (Just $ TH.VarE 'BSC.unpack `TH.AppE` TH.VarE dv))
            []])
        []] 
      ]
    , TH.InstanceD [] (TH.ConT ''PGRep `TH.AppT` typl `TH.AppT` typt) []
    , TH.InstanceD [] (TH.ConT ''PGEnum `TH.AppT` typt) []
    ]
  where
  typn = TH.mkName typs
  typt = TH.ConT typn
  typl = TH.LitT (TH.StrTyLit name)
