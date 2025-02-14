{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Unison.Runtime.Interface
  ( startRuntime,
    withRuntime,
    standalone,
    runStandalone,
    StoredCache,
    decodeStandalone,
    RuntimeHost (..),
    Runtime (..),
  )
where

import Control.Concurrent.STM as STM
import Control.Monad
import Data.Binary.Get (runGetOrFail)
-- import Data.Bits (shiftL)
import Data.ByteString.Lazy qualified as BL
import Data.Bytes.Get (MonadGet)
import Data.Bytes.Put (MonadPut, runPutL)
import Data.Bytes.Serial
import Data.Foldable
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set as Set
  ( filter,
    fromList,
    map,
    notMember,
    singleton,
    (\\),
  )
import Data.Set qualified as Set
import Data.Text (isPrefixOf, unpack)
import Unison.Builtin.Decls qualified as RF
import Unison.Codebase.CodeLookup (CodeLookup (..))
import Unison.Codebase.MainTerm (builtinMain, builtinTest)
import Unison.Codebase.Runtime (Error, Runtime (..))
import Unison.ConstructorReference (ConstructorReference, GConstructorReference (..))
import Unison.ConstructorReference qualified as RF
import Unison.DataDeclaration (Decl, declFields, declTypeDependencies)
import Unison.Hashing.V2.Convert qualified as Hashing
import Unison.LabeledDependency qualified as RF
import Unison.Parser.Ann (Ann (External))
import Unison.Prelude
import Unison.PrettyPrintEnv
import Unison.PrettyPrintEnv qualified as PPE
import Unison.Reference (Reference)
import Unison.Reference qualified as RF
import Unison.Referent qualified as RF (pattern Ref)
import Unison.Runtime.ANF
import Unison.Runtime.ANF.Rehash (rehashGroups)
import Unison.Runtime.ANF.Serialize (getGroup, putGroup)
import Unison.Runtime.Builtin
import Unison.Runtime.Decompile
import Unison.Runtime.Exception
import Unison.Runtime.MCode
  ( Args (..),
    Combs,
    Instr (..),
    RefNums (..),
    Section (..),
    combDeps,
    combTypes,
    emitComb,
    emptyRNs,
  )
import Unison.Runtime.MCode.Serialize
import Unison.Runtime.Machine
  ( ActiveThreads,
    CCache (..),
    Tracer (..),
    apply0,
    baseCCache,
    cacheAdd,
    cacheAdd0,
    eval0,
    expandSandbox,
    refLookup,
    refNumTm,
    refNumsTm,
    refNumsTy,
  )
import Unison.Runtime.Pattern
import Unison.Runtime.Serialize as SER
import Unison.Runtime.Stack
import Unison.Symbol (Symbol)
import Unison.Syntax.HashQualified qualified as HQ (toString)
import Unison.Syntax.NamePrinter (prettyHashQualified)
import Unison.Syntax.TermPrinter
import Unison.Term qualified as Tm
import Unison.Util.EnumContainers as EC
import Unison.Util.Pretty as P
import UnliftIO qualified
import UnliftIO.Concurrent qualified as UnliftIO

type Term v = Tm.Term v ()

data Remapping = Remap
  { remap :: Map.Map Reference Reference,
    backmap :: Map.Map Reference Reference
  }

instance Semigroup Remapping where
  Remap r1 b1 <> Remap r2 b2 = Remap (r1 <> r2) (b1 <> b2)

instance Monoid Remapping where
  mempty = Remap mempty mempty

data EvalCtx = ECtx
  { dspec :: DataSpec,
    floatRemap :: Remapping,
    intermedRemap :: Remapping,
    decompTm :: Map.Map Reference (Map.Map Word64 (Term Symbol)),
    ccache :: CCache
  }

uncurryDspec :: DataSpec -> Map.Map ConstructorReference Int
uncurryDspec = Map.fromList . concatMap f . Map.toList
  where
    f (r, l) = zipWith (\n c -> (ConstructorReference r n, c)) [0 ..] $ either id id l

cacheContext :: CCache -> EvalCtx
cacheContext =
  ECtx builtinDataSpec mempty mempty
    . Map.fromList
    $ Map.keys builtinTermNumbering
      <&> \r -> (r, Map.singleton 0 (Tm.ref () r))

baseContext :: Bool -> IO EvalCtx
baseContext sandboxed = cacheContext <$> baseCCache sandboxed

resolveTermRef ::
  CodeLookup Symbol IO () ->
  RF.Reference ->
  IO (Term Symbol)
resolveTermRef _ b@(RF.Builtin _) =
  die $ "Unknown builtin term reference: " ++ show b
resolveTermRef cl r@(RF.DerivedId i) =
  getTerm cl i >>= \case
    Nothing -> die $ "Unknown term reference: " ++ show r
    Just tm -> pure tm

allocType ::
  EvalCtx ->
  RF.Reference ->
  Either [Int] [Int] ->
  IO EvalCtx
allocType _ b@(RF.Builtin _) _ =
  die $ "Unknown builtin type reference: " ++ show b
allocType ctx r cons =
  pure $ ctx {dspec = Map.insert r cons $ dspec ctx}

recursiveDeclDeps ::
  Set RF.LabeledDependency ->
  CodeLookup Symbol IO () ->
  Decl Symbol () ->
  -- (type deps, term deps)
  IO (Set Reference, Set Reference)
recursiveDeclDeps seen0 cl d = do
  rec <- for (toList newDeps) $ \case
    RF.DerivedId i ->
      getTypeDeclaration cl i >>= \case
        Just d -> recursiveDeclDeps seen cl d
        Nothing -> pure mempty
    _ -> pure mempty
  pure $ (deps, mempty) <> fold rec
  where
    deps = declTypeDependencies d
    newDeps = Set.filter (\r -> notMember (RF.typeRef r) seen0) deps
    seen = seen0 <> Set.map RF.typeRef deps

categorize :: RF.LabeledDependency -> (Set Reference, Set Reference)
categorize =
  \case
    RF.TypeReference ref -> (Set.singleton ref, mempty)
    RF.ConReference (RF.ConstructorReference ref _conId) _conType -> (Set.singleton ref, mempty)
    RF.TermReference ref -> (mempty, Set.singleton ref)

recursiveTermDeps ::
  Set RF.LabeledDependency ->
  CodeLookup Symbol IO () ->
  Term Symbol ->
  -- (type deps, term deps)
  IO (Set Reference, Set Reference)
recursiveTermDeps seen0 cl tm = do
  rec <- for (toList (deps \\ seen0)) $ \case
    RF.ConReference (RF.ConstructorReference (RF.DerivedId refId) _conId) _conType -> handleTypeReferenceId refId
    RF.TypeReference (RF.DerivedId refId) -> handleTypeReferenceId refId
    RF.TermReference r -> recursiveRefDeps seen cl r
    _ -> pure mempty
  pure $ foldMap categorize deps <> fold rec
  where
    handleTypeReferenceId :: RF.Id -> IO (Set Reference, Set Reference)
    handleTypeReferenceId refId =
      getTypeDeclaration cl refId >>= \case
        Just d -> recursiveDeclDeps seen cl d
        Nothing -> pure mempty
    deps = Tm.labeledDependencies tm
    seen = seen0 <> deps

recursiveRefDeps ::
  Set RF.LabeledDependency ->
  CodeLookup Symbol IO () ->
  Reference ->
  IO (Set Reference, Set Reference)
recursiveRefDeps seen cl (RF.DerivedId i) =
  getTerm cl i >>= \case
    Just tm -> recursiveTermDeps seen cl tm
    Nothing -> pure mempty
recursiveRefDeps _ _ _ = pure mempty

collectDeps ::
  CodeLookup Symbol IO () ->
  Term Symbol ->
  IO ([(Reference, Either [Int] [Int])], [Reference])
collectDeps cl tm = do
  (tys, tms) <- recursiveTermDeps mempty cl tm
  (,toList tms) <$> traverse getDecl (toList tys)
  where
    getDecl ty@(RF.DerivedId i) =
      (ty,) . maybe (Right []) declFields
        <$> getTypeDeclaration cl i
    getDecl r = pure (r, Right [])

collectRefDeps ::
  CodeLookup Symbol IO () ->
  Reference ->
  IO ([(Reference, Either [Int] [Int])], [Reference])
collectRefDeps cl r = do
  tm <- resolveTermRef cl r
  (tyrs, tmrs) <- collectDeps cl tm
  pure (tyrs, r : tmrs)

backrefAdd ::
  Map.Map Reference (Map.Map Word64 (Term Symbol)) ->
  EvalCtx ->
  EvalCtx
backrefAdd m ctx@ECtx {decompTm} =
  ctx {decompTm = m <> decompTm}

remapAdd :: Map.Map Reference Reference -> Remapping -> Remapping
remapAdd m Remap {remap, backmap} =
  Remap {remap = m <> remap, backmap = tm <> backmap}
  where
    tm = Map.fromList . fmap (\(x, y) -> (y, x)) $ Map.toList m

floatRemapAdd :: Map.Map Reference Reference -> EvalCtx -> EvalCtx
floatRemapAdd m ctx@ECtx {floatRemap} =
  ctx {floatRemap = remapAdd m floatRemap}

intermedRemapAdd :: Map.Map Reference Reference -> EvalCtx -> EvalCtx
intermedRemapAdd m ctx@ECtx {intermedRemap} =
  ctx {intermedRemap = remapAdd m intermedRemap}

baseToIntermed :: EvalCtx -> Reference -> Maybe Reference
baseToIntermed ctx r = do
  r <- Map.lookup r . remap $ floatRemap ctx
  Map.lookup r . remap $ intermedRemap ctx

-- Runs references through the forward maps to get intermediate
-- references. Works on both base and floated references.
toIntermed :: EvalCtx -> Reference -> Reference
toIntermed ctx r
  | r <- Map.findWithDefault r r . remap $ floatRemap ctx,
    Just r <- Map.lookup r . remap $ intermedRemap ctx =
      r
toIntermed _ r = r

floatToIntermed :: EvalCtx -> Reference -> Maybe Reference
floatToIntermed ctx r =
  Map.lookup r . remap $ intermedRemap ctx

intermedToBase :: EvalCtx -> Reference -> Maybe Reference
intermedToBase ctx r = do
  r <- Map.lookup r . backmap $ intermedRemap ctx
  Map.lookup r . backmap $ floatRemap ctx

-- Runs references through the backmaps with defaults at all steps.
backmapRef :: EvalCtx -> Reference -> Reference
backmapRef ctx r0 = r2
  where
    r1 = Map.findWithDefault r0 r0 . backmap $ intermedRemap ctx
    r2 = Map.findWithDefault r1 r1 . backmap $ floatRemap ctx

performRehash ::
  Map.Map Reference (SuperGroup Symbol) ->
  EvalCtx ->
  (EvalCtx, Map Reference Reference, [(Reference, SuperGroup Symbol)])
performRehash rgrp0 ctx =
  (intermedRemapAdd rrefs ctx, rrefs, Map.toList rrgrp)
  where
    frs = remap $ floatRemap ctx
    irs = remap $ intermedRemap ctx
    f b r
      | not b,
        r <- Map.findWithDefault r r frs,
        Just r <- Map.lookup r irs =
          r
      | otherwise = r

    (rrefs, rrgrp) =
      case rehashGroups $ fmap (overGroupLinks f) rgrp0 of
        Left (msg, refs) -> error $ unpack msg ++ ": " ++ show refs
        Right p -> p

loadDeps ::
  CodeLookup Symbol IO () ->
  PrettyPrintEnv ->
  EvalCtx ->
  [(Reference, Either [Int] [Int])] ->
  [Reference] ->
  IO EvalCtx
loadDeps cl ppe ctx tyrs tmrs = do
  let cc = ccache ctx
  sand <- readTVarIO (sandbox cc)
  p <-
    refNumsTy cc <&> \m (r, _) -> case r of
      RF.DerivedId {} ->
        r `Map.notMember` dspec ctx
          || r `Map.notMember` m
      _ -> False
  q <-
    refNumsTm (ccache ctx) <&> \m r -> case r of
      RF.DerivedId {}
        | Just r <- baseToIntermed ctx r -> r `Map.notMember` m
        | Just r <- floatToIntermed ctx r -> r `Map.notMember` m
        | otherwise -> True
      _ -> False
  ctx <- foldM (uncurry . allocType) ctx $ Prelude.filter p tyrs
  itms <-
    traverse (\r -> (RF.unsafeId r,) <$> resolveTermRef cl r) $
      Prelude.filter q tmrs
  let im = Tm.unhashComponent (Map.fromList itms)
      (subvs, rgrp0, rbkr) = intermediateTerms ppe ctx im
      lubvs r = case Map.lookup r subvs of
        Just r -> r
        Nothing -> error "loadDeps: variable missing for float refs"
      vm = Map.mapKeys RF.DerivedId . Map.map (lubvs . fst) $ im
      int b r = if b then r else toIntermed ctx r
      (ctx', _, rgrp) =
        performRehash
          (fmap (overGroupLinks int) rgrp0)
          (floatRemapAdd vm ctx)
      tyAdd = Set.fromList $ fst <$> tyrs
  backrefAdd rbkr ctx'
    <$ cacheAdd0 tyAdd rgrp (expandSandbox sand rgrp) cc

backrefLifted ::
  Reference ->
  Term Symbol ->
  [(Reference, Term Symbol)] ->
  Map.Map Reference (Map.Map Word64 (Term Symbol))
backrefLifted ref (Tm.Ann' tm _) dcmp = backrefLifted ref tm dcmp
backrefLifted ref tm dcmp =
  Map.fromList . (fmap . fmap) (Map.singleton 0) $ (ref, tm) : dcmp

intermediateTerms ::
  (HasCallStack) =>
  PrettyPrintEnv ->
  EvalCtx ->
  Map RF.Id (Symbol, Term Symbol) ->
  ( Map.Map Symbol Reference,
    Map.Map Reference (SuperGroup Symbol),
    Map.Map Reference (Map.Map Word64 (Term Symbol))
  )
intermediateTerms ppe ctx rtms =
  case normalizeGroup ctx orig (Map.elems rtms) of
    (subvs, cmbs, dcmp) ->
      (subvs, Map.mapWithKey f cmbs, Map.map (Map.singleton 0) dcmp)
      where
        f ref =
          superNormalize
            . splitPatterns (dspec ctx)
            . addDefaultCases tmName
          where
            tmName = HQ.toString . termName ppe $ RF.Ref ref
  where
    orig =
      Map.fromList
        . fmap (\(x, y) -> (y, RF.DerivedId x))
        . Map.toList
        $ Map.map fst rtms

normalizeTerm ::
  EvalCtx ->
  Term Symbol ->
  ( Reference,
    Map Reference Reference,
    Map Reference (Term Symbol),
    Map Reference (Map.Map Word64 (Term Symbol))
  )
normalizeTerm ctx tm =
  absorb
    . lamLift orig
    . saturate (uncurryDspec $ dspec ctx)
    . inlineAlias
    $ tm
  where
    orig
      | Tm.LetRecNamed' bs _ <- tm =
          fmap (RF.DerivedId . fst)
            . Hashing.hashTermComponentsWithoutTypes
            $ Map.fromList bs
      | otherwise = mempty
    absorb (ll, frem, bs, dcmp) =
      let ref = RF.DerivedId $ Hashing.hashClosedTerm ll
       in (ref, frem, Map.fromList $ (ref, ll) : bs, backrefLifted ref tm dcmp)

normalizeGroup ::
  EvalCtx ->
  Map Symbol Reference ->
  [(Symbol, Term Symbol)] ->
  ( Map Symbol Reference,
    Map Reference (Term Symbol),
    Map Reference (Term Symbol)
  )
normalizeGroup ctx orig gr0 = case lamLiftGroup orig gr of
  (subvis, cmbs, dcmp) ->
    let subvs = (fmap . fmap) RF.DerivedId subvis
        subrs = Map.fromList $ mapMaybe f subvs
     in ( Map.fromList subvs,
          Map.fromList $
            (fmap . fmap) (Tm.updateDependencies subrs mempty) cmbs,
          Map.fromList dcmp
        )
  where
    gr = fmap (saturate (uncurryDspec $ dspec ctx) . inlineAlias) <$> gr0
    f (v, r) = (,RF.Ref r) . RF.Ref <$> Map.lookup v orig

intermediateTerm ::
  (HasCallStack) =>
  PrettyPrintEnv ->
  EvalCtx ->
  Term Symbol ->
  ( Reference,
    Map.Map Reference Reference,
    Map.Map Reference (SuperGroup Symbol),
    Map.Map Reference (Map.Map Word64 (Term Symbol))
  )
intermediateTerm ppe ctx tm =
  case normalizeTerm ctx tm of
    (ref, frem, cmbs, dcmp) -> (ref, frem, fmap f cmbs, dcmp)
      where
        tmName = HQ.toString . termName ppe $ RF.Ref ref
        f =
          superNormalize
            . splitPatterns (dspec ctx)
            . addDefaultCases tmName

prepareEvaluation ::
  (HasCallStack) =>
  PrettyPrintEnv ->
  Term Symbol ->
  EvalCtx ->
  IO (EvalCtx, Word64)
prepareEvaluation ppe tm ctx = do
  missing <- cacheAdd rgrp (ccache ctx')
  when (not . null $ missing) . fail $
    reportBug "E029347" $
      "Error in prepareEvaluation, cache is missing: " <> show missing
  (,) (backrefAdd rbkr ctx') <$> refNumTm (ccache ctx') rmn
  where
    (rmn0, frem, rgrp0, rbkr) = intermediateTerm ppe ctx tm
    int b r = if b then r else toIntermed ctx r
    (ctx', rrefs, rgrp) =
      performRehash
        ((fmap . overGroupLinks) int rgrp0)
        (floatRemapAdd frem ctx)
    rmn = case Map.lookup rmn0 rrefs of
      Just r -> r
      Nothing -> error "prepareEvaluation: could not remap main ref"

watchHook :: IORef Closure -> Stack 'UN -> Stack 'BX -> IO ()
watchHook r _ bstk = peek bstk >>= writeIORef r

backReferenceTm ::
  EnumMap Word64 Reference ->
  Remapping ->
  Remapping ->
  Map.Map Reference (Map.Map Word64 (Term Symbol)) ->
  Word64 ->
  Word64 ->
  Maybe (Term Symbol)
backReferenceTm ws frs irs dcm c i = do
  r <- EC.lookup c ws
  -- backmap intermediate ref to floated ref
  r <- Map.lookup r (backmap irs)
  -- backmap floated ref to original ref
  r <- pure $ Map.findWithDefault r r (backmap frs)
  -- look up original ref in decompile info
  bs <- Map.lookup r dcm
  Map.lookup i bs

evalInContext ::
  PrettyPrintEnv ->
  EvalCtx ->
  ActiveThreads ->
  Word64 ->
  IO (Either Error (Term Symbol))
evalInContext ppe ctx activeThreads w = do
  r <- newIORef BlackHole
  crs <- readTVarIO (combRefs $ ccache ctx)
  let hook = watchHook r
      decom =
        decompile
          (intermedToBase ctx)
          ( backReferenceTm
              crs
              (floatRemap ctx)
              (intermedRemap ctx)
              (decompTm ctx)
          )

      prettyError (PE _ p) = p
      prettyError (BU tr0 nm c) =
        either id (bugMsg ppe tr nm) $ decom c
        where
          tr = first (backmapRef ctx) <$> tr0

      debugText fancy c = case decom c of
        Right dv -> SimpleTrace . (debugTextFormat fancy) $ pretty ppe dv
        Left _ -> MsgTrace ("Couldn't decompile value") (show c)

  result <-
    traverse (const $ readIORef r)
      . first prettyError
      <=< try
      $ apply0 (Just hook) ((ccache ctx) {tracer = debugText}) activeThreads w
  pure $ decom =<< result

executeMainComb ::
  Word64 ->
  CCache ->
  IO (Either (Pretty ColorText) ())
executeMainComb init cc = do
  result <-
    UnliftIO.try
      . eval0 cc Nothing
      . Ins (Pack RF.unitRef 0 ZArgs)
      $ Call True init (BArg1 0)
  case result of
    Left err -> Left <$> formatErr err
    Right () -> pure (Right ())
  where
    formatErr (PE _ msg) = pure msg
    formatErr (BU tr nm c) = do
      crs <- readTVarIO (combRefs cc)
      let ctx = cacheContext cc
          decom =
            decompile
              (intermedToBase ctx)
              ( backReferenceTm
                  crs
                  (floatRemap ctx)
                  (intermedRemap ctx)
                  (decompTm ctx)
              )
      pure . either id (bugMsg PPE.empty tr nm) $ decom c

bugMsg ::
  PrettyPrintEnv ->
  [(Reference, Int)] ->
  Text ->
  Term Symbol ->
  Pretty ColorText
bugMsg ppe tr name tm
  | name == "blank expression" =
      P.callout icon . P.lines $
        [ P.wrap
            ( "I encountered a"
                <> P.red (P.text name)
                <> "with the following name/message:"
            ),
          "",
          P.indentN 2 $ pretty ppe tm,
          "\n",
          stackTrace ppe tr
        ]
  | "pattern match failure" `isPrefixOf` name =
      P.callout icon . P.lines $
        [ P.wrap
            ( "I've encountered a"
                <> P.red (P.text name)
                <> "while scrutinizing:"
            ),
          "",
          P.indentN 2 $ pretty ppe tm,
          "",
          "This happens when calling a function that doesn't handle all \
          \possible inputs",
          "\n",
          stackTrace ppe tr
        ]
  | name == "builtin.raise" =
      P.callout icon . P.lines $
        [ P.wrap ("The program halted with an unhandled exception:"),
          "",
          P.indentN 2 $ pretty ppe tm,
          "\n",
          stackTrace ppe tr
        ]
  | name == "builtin.bug",
    RF.TupleTerm' [Tm.Text' msg, x] <- tm,
    "pattern match failure" `isPrefixOf` msg =
      P.callout icon . P.lines $
        [ P.wrap
            ( "I've encountered a"
                <> P.red (P.text msg)
                <> "while scrutinizing:"
            ),
          "",
          P.indentN 2 $ pretty ppe x,
          "",
          "This happens when calling a function that doesn't handle all \
          \possible inputs",
          "\n",
          stackTrace ppe tr
        ]
bugMsg ppe tr name tm =
  P.callout icon . P.lines $
    [ P.wrap
        ( "I've encountered a call to"
            <> P.red (P.text name)
            <> "with the following value:"
        ),
      "",
      P.indentN 2 $ pretty ppe tm,
      "\n",
      stackTrace ppe tr
    ]

stackTrace :: PrettyPrintEnv -> [(Reference, Int)] -> Pretty ColorText
stackTrace ppe tr = "Stack trace:\n" <> P.indentN 2 (P.lines $ f <$> tr)
  where
    f (rf, n) = name <> count
      where
        count
          | n > 1 = " (" <> fromString (show n) <> " copies)"
          | otherwise = ""
        name =
          syntaxToColor
            . prettyHashQualified
            . PPE.termName ppe
            . RF.Ref
            $ rf

icon :: Pretty ColorText
icon = "💔💥"

catchInternalErrors ::
  IO (Either Error a) ->
  IO (Either Error a)
catchInternalErrors sub = sub `UnliftIO.catch` \(CE _ e) -> pure $ Left e

decodeStandalone ::
  BL.ByteString ->
  Either String (Text, Text, Word64, StoredCache)
decodeStandalone b = bimap thd thd $ runGetOrFail g b
  where
    thd (_, _, x) = x
    g =
      (,,,)
        <$> deserialize
        <*> deserialize
        <*> getNat
        <*> getStoredCache

-- | Whether the runtime is hosted within a persistent session or as a one-off process.
-- This affects the amount of clean-up and book-keeping the runtime does.
data RuntimeHost
  = OneOff
  | Persistent

startRuntime :: Bool -> RuntimeHost -> Text -> IO (Runtime Symbol)
startRuntime sandboxed runtimeHost version = do
  ctxVar <- newIORef =<< baseContext sandboxed
  (activeThreads, cleanupThreads) <- case runtimeHost of
    -- Don't bother tracking open threads when running standalone, they'll all be cleaned up
    -- when the process itself exits.
    OneOff -> pure (Nothing, pure ())
    -- Track all forked threads so that they can be killed when the main process returns,
    -- otherwise they'll be orphaned and left running.
    Persistent -> do
      activeThreads <- newIORef Set.empty
      let cleanupThreads = do
            threads <- readIORef activeThreads
            foldMap UnliftIO.killThread threads
      pure (Just activeThreads, cleanupThreads)
  pure $
    Runtime
      { terminate = pure (),
        evaluate = \cl ppe tm -> catchInternalErrors $ do
          ctx <- readIORef ctxVar
          (tyrs, tmrs) <- collectDeps cl tm
          ctx <- loadDeps cl ppe ctx tyrs tmrs
          (ctx, init) <- prepareEvaluation ppe tm ctx
          writeIORef ctxVar ctx
          evalInContext ppe ctx activeThreads init `UnliftIO.finally` cleanupThreads,
        compileTo = \cl ppe rf path -> tryM $ do
          ctx <- readIORef ctxVar
          (tyrs, tmrs) <- collectRefDeps cl rf
          ctx <- loadDeps cl ppe ctx tyrs tmrs
          let cc = ccache ctx
              lk m = flip Map.lookup m =<< baseToIntermed ctx rf
          Just w <- lk <$> readTVarIO (refTm cc)
          sto <- standalone cc w
          BL.writeFile path . runPutL $ do
            serialize $ version
            serialize $ RF.showShort 8 rf
            putNat w
            putStoredCache sto,
        mainType = builtinMain External,
        ioTestType = builtinTest External
      }

withRuntime :: (MonadUnliftIO m) => Bool -> RuntimeHost -> Text -> (Runtime Symbol -> m a) -> m a
withRuntime sandboxed runtimeHost version action =
  UnliftIO.bracket (liftIO $ startRuntime sandboxed runtimeHost version) (liftIO . terminate) action

tryM :: IO () -> IO (Maybe Error)
tryM = fmap (either (Just . extract) (const Nothing)) . try
  where
    extract (PE _ e) = e
    extract (BU _ _ _) = "impossible"

runStandalone :: StoredCache -> Word64 -> IO (Either (Pretty ColorText) ())
runStandalone sc init =
  restoreCache sc >>= executeMainComb init

data StoredCache
  = SCache
      (EnumMap Word64 Combs)
      (EnumMap Word64 Reference)
      (EnumMap Word64 Reference)
      Word64
      Word64
      (Map Reference (SuperGroup Symbol))
      (Map Reference Word64)
      (Map Reference Word64)
      (Map Reference (Set Reference))
  deriving (Show)

putStoredCache :: (MonadPut m) => StoredCache -> m ()
putStoredCache (SCache cs crs trs ftm fty int rtm rty sbs) = do
  putEnumMap putNat (putEnumMap putNat putComb) cs
  putEnumMap putNat putReference crs
  putEnumMap putNat putReference trs
  putNat ftm
  putNat fty
  putMap putReference (putGroup mempty mempty) int
  putMap putReference putNat rtm
  putMap putReference putNat rty
  putMap putReference (putFoldable putReference) sbs

getStoredCache :: (MonadGet m) => m StoredCache
getStoredCache =
  SCache
    <$> getEnumMap getNat (getEnumMap getNat getComb)
    <*> getEnumMap getNat getReference
    <*> getEnumMap getNat getReference
    <*> getNat
    <*> getNat
    <*> getMap getReference getGroup
    <*> getMap getReference getNat
    <*> getMap getReference getNat
    <*> getMap getReference (fromList <$> getList getReference)

debugTextFormat :: Bool -> Pretty ColorText -> String
debugTextFormat fancy =
  render 50
  where
    render = if fancy then toANSI else toPlain

restoreCache :: StoredCache -> IO CCache
restoreCache (SCache cs crs trs ftm fty int rtm rty sbs) =
  CCache builtinForeigns False debugText
    <$> newTVarIO (cs <> combs)
    <*> newTVarIO (crs <> builtinTermBackref)
    <*> newTVarIO (trs <> builtinTypeBackref)
    <*> newTVarIO ftm
    <*> newTVarIO fty
    <*> newTVarIO int
    <*> newTVarIO (rtm <> builtinTermNumbering)
    <*> newTVarIO (rty <> builtinTypeNumbering)
    <*> newTVarIO (sbs <> baseSandboxInfo)
  where
    decom =
      decompile
        (const Nothing)
        (backReferenceTm crs mempty mempty mempty)
    debugText fancy c = case decom c of
      Right dv -> SimpleTrace . (debugTextFormat fancy) $ pretty PPE.empty dv
      Left _ -> MsgTrace ("Couldn't decompile value") (show c)
    rns = emptyRNs {dnum = refLookup "ty" builtinTypeNumbering}
    rf k = builtinTermBackref ! k
    combs =
      mapWithKey
        (\k v -> emitComb @Symbol rns (rf k) k mempty (0, v))
        numberedTermLookup

traceNeeded ::
  Word64 ->
  EnumMap Word64 Combs ->
  IO (EnumMap Word64 Combs)
traceNeeded init src = fmap (`withoutKeys` ks) $ go mempty init
  where
    ks = keysSet numberedTermLookup
    go acc w
      | hasKey w acc = pure acc
      | Just co <- EC.lookup w src =
          foldlM go (mapInsert w co acc) (foldMap combDeps co)
      | otherwise = die $ "traceNeeded: unknown combinator: " ++ show w

buildSCache ::
  EnumMap Word64 Combs ->
  EnumMap Word64 Reference ->
  EnumMap Word64 Reference ->
  Word64 ->
  Word64 ->
  Map Reference (SuperGroup Symbol) ->
  Map Reference Word64 ->
  Map Reference Word64 ->
  Map Reference (Set Reference) ->
  StoredCache
buildSCache cs crsrc trsrc ftm fty intsrc rtmsrc rtysrc sndbx =
  SCache
    cs
    crs
    trs
    ftm
    fty
    (restrictTmR intsrc)
    (restrictTmR rtmsrc)
    (restrictTyR rtysrc)
    (restrictTmR sndbx)
  where
    combKeys = keysSet cs
    crs = restrictTmW crsrc
    termRefs = foldMap Set.singleton crs

    typeKeys = setFromList $ (foldMap . foldMap) combTypes cs
    trs = restrictTyW trsrc
    typeRefs = foldMap Set.singleton trs

    restrictTmW m = restrictKeys m combKeys
    restrictTmR :: Map Reference a -> Map Reference a
    restrictTmR m = Map.restrictKeys m termRefs

    restrictTyW m = restrictKeys m typeKeys
    restrictTyR m = Map.restrictKeys m typeRefs

standalone :: CCache -> Word64 -> IO StoredCache
standalone cc init =
  buildSCache
    <$> (readTVarIO (combs cc) >>= traceNeeded init)
    <*> readTVarIO (combRefs cc)
    <*> readTVarIO (tagRefs cc)
    <*> readTVarIO (freshTm cc)
    <*> readTVarIO (freshTy cc)
    <*> readTVarIO (intermed cc)
    <*> readTVarIO (refTm cc)
    <*> readTVarIO (refTy cc)
    <*> readTVarIO (sandbox cc)
