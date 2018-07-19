{-# Language OverloadedStrings #-}
{-# Language ScopedTypeVariables #-}
{-# Language TupleSections     #-}
{-# Language UnicodeSyntax     #-}

module Unison.FileParsers where

import Data.Maybe
import           Control.Monad.State (evalStateT)
import           Data.ByteString (ByteString)
import           Data.Bytes.Put (runPutS)
import qualified Data.Foldable as Foldable
import           Data.Functor.Identity (runIdentity)
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Unison.Builtin as B
import qualified Unison.Codecs as Codecs
import           Unison.DataDeclaration (DataDeclaration)
import qualified Unison.Parser as Parser
import qualified Unison.Parsers as Parsers
import           Unison.Reference (Reference)
import           Unison.Result (Result(..))
import qualified Unison.Result as Result
import           Unison.Term (Term)
import           Unison.Type (Type)
import qualified Unison.Typechecker as Typechecker
import           Unison.UnisonFile (UnisonFile(..))
import qualified Unison.UnisonFile as UF
import           Unison.Var (Var)
-- import qualified Debug.Trace as Trace

parseAndSynthesizeAsFile :: Var v => FilePath -> String
                         -> Result v () (Term v, Type v)
parseAndSynthesizeAsFile filename s = do
  file <- Result.fromParsing $ Parsers.parseFile filename s Parser.penv0
  synthesizeFile file

synthesizeFile :: ∀ v . Var v => UnisonFile v -> Result v () (Term v, Type v)
synthesizeFile unisonFile =
  let (UnisonFile dds0 eds0 term) =
        UF.bindBuiltins B.builtinTerms B.builtinTypes unisonFile
      dds :: Map Reference (DataDeclaration v)
      dds = Map.fromList $ Foldable.toList dds0
      eds = Map.fromList $ Foldable.toList eds0
      datas = Map.union dds B.builtinDataDecls -- `Map.union` is left-biased
      effects = Map.union eds B.builtinEffectDecls
      env0 = Typechecker.Env () [] typeOf dataDeclaration effectDeclaration
      n = Typechecker.synthesize env0 term
      die s h = error $ "unknown " ++ s ++ " reference " ++ show h
      typeOf r = pure $ fromMaybe (die "value" r) $ Map.lookup r B.builtins
      dataDeclaration r = pure $ fromMaybe (die "data" r) $ Map.lookup r datas
      effectDeclaration r = pure $ fromMaybe (die "effect" r) $ Map.lookup r effects
  in (term,) <$> runIdentity n

synthesizeUnisonFile :: Var v
                     => UnisonFile v
                     -> Result v () (UnisonFile v, Type v)
synthesizeUnisonFile unisonFile@(UnisonFile d e _t) = do
  (t', typ) <- synthesizeFile unisonFile
  pure $ (UnisonFile d e t', typ)

serializeUnisonFile :: Var v => UnisonFile v
                             -> Result v () (UnisonFile v, Type v, ByteString)
serializeUnisonFile unisonFile =
  let r = synthesizeUnisonFile unisonFile
      f (unisonFile', typ) =
        let bs = runPutS $ flip evalStateT 0 $ Codecs.serializeFile unisonFile'
        in (unisonFile', typ, bs)
  in f <$> r
