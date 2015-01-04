{-# LANGUAGE TemplateHaskell, FlexibleInstances, MultiParamTypeClasses, DataKinds #-}
-- |
-- Module: Database.PostgreSQL.Typed.Enum
-- Copyright: 2015 Dylan Simon
-- 
-- Support for PostgreSQL enums.

module Database.PostgreSQL.Typed.Enum 
  ( makePGEnum
  ) where

import Control.Monad (when)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.UTF8 as U
import Data.Foldable (toList)
import qualified Data.Sequence as Seq
import qualified Language.Haskell.TH as TH

import Database.PostgreSQL.Typed.Protocol
import Database.PostgreSQL.Typed.TH
import Database.PostgreSQL.Typed.Types

-- |Create a new enum type corresponding to the given PostgreSQL enum type.
-- For example, if you have @CREATE TYPE foo AS ENUM (\'abc\', \'DEF\');@, then
-- @makePGEnum \"foo\" \"Foo\" (\"Foo_\"++)@ will be equivalent to:
-- 
-- @
-- data Foo = Foo_abc | Foo_DEF deriving (Eq, Ord, Enum, Bounded)
-- instance PGType Foo where ...
-- registerPGType \"foo\" (ConT ''Foo)
-- @
--
-- Requires language extensions: TemplateHaskell, FlexibleInstances, MultiParamTypeClasses, DataKinds
makePGEnum :: String -- ^ PostgreSQL enum type name
  -> String -- ^ Haskell type to create
  -> (String -> String) -- ^ How to generate constructor names from enum values, e.g. @(\"Type_\"++)@
  -> TH.DecsQ
makePGEnum name typs valnf = do
  (_, vals) <- TH.runIO $ withTPGConnection $ \c ->
    pgSimpleQuery c $ "SELECT enumlabel FROM pg_catalog.pg_enum JOIN pg_catalog.pg_type t ON enumtypid = t.oid WHERE typtype = 'e' AND format_type(t.oid, -1) = " ++ pgQuote name ++ " ORDER BY enumsortorder"
  when (Seq.null vals) $ fail $ "makePGEnum: enum " ++ name ++ " not found"
  let 
    valn = map (\[PGTextValue v] -> (TH.StringL (BSC.unpack v), TH.mkName $ valnf (U.toString v))) $ toList vals
  dv <- TH.newName "x"
  ds <- TH.newName "s"
  return
    [ TH.DataD [] typn [] (map (\(_, n) -> TH.NormalC n []) valn) [''Eq, ''Ord, ''Enum, ''Bounded]
    , TH.InstanceD [] (TH.ConT ''PGParameter `TH.AppT` TH.LitT (TH.StrTyLit name) `TH.AppT` typt)
      [ TH.FunD 'pgEncode $ map (\(l, n) -> TH.Clause [TH.WildP, TH.ConP n []]
        (TH.NormalB $ TH.VarE 'BSC.pack `TH.AppE` TH.LitE l) []) valn ]
    , TH.InstanceD [] (TH.ConT ''PGColumn `TH.AppT` TH.LitT (TH.StrTyLit name) `TH.AppT` typt)
      [ TH.FunD 'pgDecode [TH.Clause [TH.WildP, TH.VarP dv]
        (TH.NormalB $ TH.CaseE (TH.VarE 'BSC.unpack `TH.AppE` TH.VarE dv) $ map (\(l, n) ->
          TH.Match (TH.LitP l) (TH.NormalB $ TH.ConE n) []) valn ++
          [TH.Match (TH.VarP ds) (TH.NormalB $ TH.AppE (TH.VarE 'error) $
            TH.InfixE (Just $ TH.LitE (TH.StringL ("pgDecode " ++ name ++ ": "))) (TH.VarE '(++)) (Just $ TH.VarE ds))
            []])
        []] ]
    ]
  where
  typn = TH.mkName typs
  typt = TH.ConT typn