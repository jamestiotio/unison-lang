module Unison.Codebase
  ( Codebase,

    -- * Terms
    getTerm,
    unsafeGetTerm,
    unsafeGetTermWithType,
    getTermComponentWithTypes,
    unsafeGetTermComponent,
    getTypeOfTerm,
    getDeclType,
    unsafeGetTypeOfTermById,
    isTerm,
    putTerm,
    putTermComponent,
    termMetadata,

    -- ** Referents (sorta-termlike)
    getTypeOfReferent,

    -- ** Search
    termsOfType,
    termsMentioningType,
    SqliteCodebase.Operations.termReferencesByPrefix,
    termReferentsByPrefix,

    -- * Type declarations
    getTypeDeclaration,
    unsafeGetTypeDeclaration,
    SqliteCodebase.Operations.getDeclComponent,
    putTypeDeclaration,
    putTypeDeclarationComponent,
    SqliteCodebase.Operations.typeReferencesByPrefix,
    isType,

    -- * Branches
    SqliteCodebase.Operations.branchExists,
    getBranchForHash,
    expectBranchForHash,
    putBranch,
    SqliteCodebase.Operations.causalHashesByPrefix,
    lca,
    SqliteCodebase.Operations.before,
    getShallowBranchAtPath,
    getShallowCausalAtPath,
    Operations.expectCausalBranchByCausalHash,
    getShallowCausalFromRoot,
    getShallowRootBranch,
    getShallowRootCausal,

    -- * Root branch
    getRootBranch,
    SqliteCodebase.Operations.getRootBranchExists,
    Operations.expectRootCausalHash,
    putRootBranch,
    SqliteCodebase.Operations.namesAtPath,

    -- * Patches
    SqliteCodebase.Operations.patchExists,
    SqliteCodebase.Operations.getPatch,
    SqliteCodebase.Operations.putPatch,

    -- * Watches
    getWatch,
    lookupWatchCache,
    SqliteCodebase.Operations.watches,
    SqliteCodebase.Operations.putWatch,
    Queries.clearWatches,

    -- * Reflog
    Operations.getReflog,

    -- * Unambiguous hash length
    SqliteCodebase.Operations.hashLength,
    SqliteCodebase.Operations.branchHashLength,

    -- * Dependents
    dependents,
    dependentsOfComponent,

    -- * Sync

    -- ** Local sync
    syncFromDirectory,
    syncToDirectory,

    -- ** Remote sync
    viewRemoteBranch,
    importRemoteBranch,
    Preprocessing (..),
    pushGitBranch,
    PushGitBranchOpts (..),

    -- * Codebase path
    getCodebaseDir,
    CodebasePath,
    SyncToDir,

    -- * Direct codebase access
    runTransaction,
    withConnection,
    withConnectionIO,

    -- * Misc (organize these better)
    addDefsToCodebase,
    componentReferencesForReference,
    installUcmDependencies,
    toCodeLookup,
    typeLookupForDependencies,
    unsafeGetComponentLength,
  )
where

import Control.Monad.Except (ExceptT (ExceptT), runExceptT)
import Control.Monad.Trans.Except (throwE)
import Data.List as List
import Data.Map qualified as Map
import Data.Set qualified as Set
import U.Codebase.Branch qualified as V2
import U.Codebase.Branch qualified as V2Branch
import U.Codebase.Causal qualified as V2Causal
import U.Codebase.HashTags (CausalHash)
import U.Codebase.Referent qualified as V2
import U.Codebase.Sqlite.Operations qualified as Operations
import U.Codebase.Sqlite.Queries qualified as Queries
import Unison.Builtin qualified as Builtin
import Unison.Builtin.Terms qualified as Builtin
import Unison.Codebase.Branch (Branch)
import Unison.Codebase.Branch qualified as Branch
import Unison.Codebase.BuiltinAnnotation (BuiltinAnnotation (builtinAnnotation))
import Unison.Codebase.CodeLookup qualified as CL
import Unison.Codebase.Editor.Git (withStatus)
import Unison.Codebase.Editor.Git qualified as Git
import Unison.Codebase.Editor.RemoteRepo (ReadGitRemoteNamespace)
import Unison.Codebase.GitError qualified as GitError
import Unison.Codebase.Path
import Unison.Codebase.Path qualified as Path
import Unison.Codebase.SqliteCodebase.Conversions qualified as Cv
import Unison.Codebase.SqliteCodebase.Operations qualified as SqliteCodebase.Operations
import Unison.Codebase.SyncMode (SyncMode)
import Unison.Codebase.Type
  ( Codebase (..),
    GitError (GitCodebaseError),
    PushGitBranchOpts (..),
    SyncToDir,
  )
import Unison.CodebasePath (CodebasePath, getCodebaseDir)
import Unison.ConstructorReference (ConstructorReference, GConstructorReference (..))
import Unison.DataDeclaration (Decl)
import Unison.DataDeclaration qualified as DD
import Unison.Hash (Hash)
import Unison.Hashing.V2.Convert qualified as Hashing
import Unison.NameSegment qualified as NameSegment
import Unison.Parser.Ann (Ann)
import Unison.Parser.Ann qualified as Parser
import Unison.Prelude
import Unison.Reference (Reference)
import Unison.Reference qualified as Reference
import Unison.Referent qualified as Referent
import Unison.Runtime.IOSource qualified as IOSource
import Unison.Sqlite qualified as Sqlite
import Unison.Symbol (Symbol)
import Unison.Term (Term)
import Unison.Term qualified as Term
import Unison.Type (Type)
import Unison.Type qualified as Type
import Unison.Typechecker.TypeLookup (TypeLookup (TypeLookup))
import Unison.Typechecker.TypeLookup qualified as TL
import Unison.UnisonFile qualified as UF
import Unison.Util.Relation qualified as Rel
import Unison.Util.Timing (time)
import Unison.Var (Var)
import Unison.WatchKind qualified as WK

-- | Run a transaction on a codebase.
runTransaction :: (MonadIO m) => Codebase m v a -> Sqlite.Transaction b -> m b
runTransaction Codebase {withConnection} action =
  withConnection \conn -> Sqlite.runTransaction conn action

getShallowCausalFromRoot ::
  -- Optional root branch, if Nothing use the codebase's root branch.
  Maybe CausalHash ->
  Path.Path ->
  Sqlite.Transaction (V2Branch.CausalBranch Sqlite.Transaction)
getShallowCausalFromRoot mayRootHash p = do
  rootCausal <- case mayRootHash of
    Nothing -> getShallowRootCausal
    Just ch -> Operations.expectCausalBranchByCausalHash ch
  getShallowCausalAtPath p (Just rootCausal)

-- | Get the shallow representation of the root branches without loading the children or
-- history.
getShallowRootBranch :: Sqlite.Transaction (V2.Branch Sqlite.Transaction)
getShallowRootBranch = do
  getShallowRootCausal >>= V2Causal.value

-- | Get the shallow representation of the root branches without loading the children or
-- history.
getShallowRootCausal :: Sqlite.Transaction (V2.CausalBranch Sqlite.Transaction)
getShallowRootCausal = do
  hash <- Operations.expectRootCausalHash
  Operations.expectCausalBranchByCausalHash hash

-- | Recursively descend into causals following the given path,
-- Use the root causal if none is provided.
getShallowCausalAtPath ::
  Path ->
  Maybe (V2Branch.CausalBranch Sqlite.Transaction) ->
  Sqlite.Transaction (V2Branch.CausalBranch Sqlite.Transaction)
getShallowCausalAtPath path mayCausal = do
  causal <- whenNothing mayCausal getShallowRootCausal
  case path of
    Path.Empty -> pure causal
    ns Path.:< p -> do
      b <- V2Causal.value causal
      case V2Branch.childAt ns b of
        Nothing -> pure (Cv.causalbranch1to2 Branch.empty)
        Just childCausal -> getShallowCausalAtPath p (Just childCausal)

-- | Recursively descend into causals following the given path,
-- Use the root causal if none is provided.
getShallowBranchAtPath ::
  Path ->
  Maybe (V2Branch.Branch Sqlite.Transaction) ->
  Sqlite.Transaction (V2Branch.Branch Sqlite.Transaction)
getShallowBranchAtPath path mayBranch = do
  branch <- whenNothing mayBranch (getShallowRootCausal >>= V2Causal.value)
  case path of
    Path.Empty -> pure branch
    ns Path.:< p -> do
      case V2Branch.childAt ns branch of
        Nothing -> pure V2Branch.empty
        Just childCausal -> do
          childBranch <- V2Causal.value childCausal
          getShallowBranchAtPath p (Just childBranch)

-- | Get a branch from the codebase.
getBranchForHash :: (Monad m) => Codebase m v a -> CausalHash -> m (Maybe (Branch m))
getBranchForHash codebase h =
  -- Attempt to find the Branch in the current codebase cache and root up to 3 levels deep
  -- If not found, attempt to find it in the Codebase (sqlite)
  let nestedChildrenForDepth :: Int -> Branch m -> [Branch m]
      nestedChildrenForDepth depth b =
        if depth == 0
          then []
          else b : (Map.elems (Branch._children (Branch.head b)) >>= nestedChildrenForDepth (depth - 1))

      headHashEq = (h ==) . Branch.headHash

      find rb = List.find headHashEq (nestedChildrenForDepth 3 rb)
   in do
        rootBranch <- getRootBranch codebase
        maybe (getBranchForHashImpl codebase h) (pure . Just) (find rootBranch)

-- | Like 'getBranchForHash', but for when the hash is known to be in the codebase.
expectBranchForHash :: (Monad m) => Codebase m v a -> CausalHash -> m (Branch m)
expectBranchForHash codebase hash =
  getBranchForHash codebase hash >>= \case
    Just branch -> pure branch
    Nothing -> error $ reportBug "E412939" ("expectBranchForHash: " ++ show hash ++ " not found in codebase")

-- | Get the metadata attached to the term at a given path and name relative to the given branch.
termMetadata ::
  -- | The branch to search inside. Use the current root if 'Nothing'.
  Maybe (V2Branch.Branch Sqlite.Transaction) ->
  Split ->
  -- | There may be multiple terms at the given name. You can specify a Referent to
  -- disambiguate if desired.
  Maybe V2.Referent ->
  Sqlite.Transaction [Map V2Branch.MetadataValue V2Branch.MetadataType]
termMetadata mayBranch (path, nameSeg) ref = do
  b <- getShallowBranchAtPath path mayBranch
  V2Branch.termMetadata b (coerce @NameSegment.NameSegment nameSeg) ref

-- | Get the lowest common ancestor of two branches, i.e. the most recent branch that is an ancestor of both branches.
lca :: (MonadIO m) => Codebase m v a -> Branch m -> Branch m -> m (Maybe (Branch m))
lca code b1@(Branch.headHash -> h1) b2@(Branch.headHash -> h2) = do
  action <-
    runTransaction code do
      eb1 <- SqliteCodebase.Operations.branchExists h1
      eb2 <- SqliteCodebase.Operations.branchExists h2
      if eb1 && eb2
        then do
          Operations.lca h1 h2 >>= \case
            Just h -> pure (getBranchForHash code h)
            Nothing -> pure (pure Nothing) -- no common ancestor
        else pure (Branch.lca b1 b2)
  action

debug :: Bool
debug = False

-- | Write all of UCM's dependencies (builtins types and an empty namespace) into the codebase
installUcmDependencies :: Codebase m Symbol Parser.Ann -> Sqlite.Transaction ()
installUcmDependencies c = do
  let uf =
        ( UF.typecheckedUnisonFile
            (Map.fromList Builtin.builtinDataDecls)
            (Map.fromList Builtin.builtinEffectDecls)
            [Builtin.builtinTermsSrc Parser.Intrinsic]
            mempty
        )
  addDefsToCodebase c uf

-- Feel free to refactor this to use some other type than TypecheckedUnisonFile
-- if it makes sense to later.
addDefsToCodebase ::
  forall m v a.
  (Var v, Show a) =>
  Codebase m v a ->
  UF.TypecheckedUnisonFile v a ->
  Sqlite.Transaction ()
addDefsToCodebase c uf = do
  traverse_ (goType Right) (UF.dataDeclarationsId' uf)
  traverse_ (goType Left) (UF.effectDeclarationsId' uf)
  -- put terms
  traverse_ goTerm (UF.hashTermsId uf)
  where
    goTerm t | debug && trace ("Codebase.addDefsToCodebase.goTerm " ++ show t) False = undefined
    goTerm (_, r, Nothing, tm, tp) = putTerm c r tm tp
    goTerm (_, r, Just WK.TestWatch, tm, tp) = putTerm c r tm tp
    goTerm _ = pure ()
    goType :: (Show t) => (t -> Decl v a) -> (Reference.Id, t) -> Sqlite.Transaction ()
    goType _f pair | debug && trace ("Codebase.addDefsToCodebase.goType " ++ show pair) False = undefined
    goType f (ref, decl) = putTypeDeclaration c ref (f decl)

getTypeOfConstructor :: (Ord v) => Codebase m v a -> ConstructorReference -> Sqlite.Transaction (Maybe (Type v a))
getTypeOfConstructor codebase (ConstructorReference r0 cid) =
  case r0 of
    Reference.DerivedId r -> do
      maybeDecl <- getTypeDeclaration codebase r
      pure $ case maybeDecl of
        Nothing -> Nothing
        Just decl -> DD.typeOfConstructor (either DD.toDataDecl id decl) cid
    Reference.Builtin _ -> error (reportBug "924628772" "Attempt to load a type declaration which is a builtin!")

-- | Like 'getWatch', but first looks up the given reference as a regular watch, then as a test watch.
--
-- @
-- lookupWatchCache codebase ref =
--   runMaybeT do
--     MaybeT (getWatch codebase RegularWatch ref)
--       <|> MaybeT (getWatch codebase TestWatch ref))
-- @
lookupWatchCache :: Codebase m v a -> Reference.Id -> Sqlite.Transaction (Maybe (Term v a))
lookupWatchCache codebase h = do
  m1 <- getWatch codebase WK.RegularWatch h
  maybe (getWatch codebase WK.TestWatch h) (pure . Just) m1

-- | Make a @TypeLookup@ that is suitable for looking up information about all of the given type-or-term references,
-- and all of their type dependencies, including builtins.
typeLookupForDependencies ::
  Codebase IO Symbol Ann ->
  Set Reference ->
  Sqlite.Transaction (TL.TypeLookup Symbol Ann)
typeLookupForDependencies codebase s = do
  when debug $ traceM $ "typeLookupForDependencies " ++ show s
  (<> Builtin.typeLookup) <$> depthFirstAccum mempty s
  where
    depthFirstAccum :: TL.TypeLookup Symbol Ann -> Set Reference -> Sqlite.Transaction (TL.TypeLookup Symbol Ann)
    depthFirstAccum tl refs = foldM go tl (Set.filter (unseen tl) refs)

    -- We need the transitive dependencies of data decls
    -- that are scrutinized in a match expression for
    -- pattern match coverage checking (specifically for
    -- the inhabitation check). We ensure these are found
    -- by collecting all transitive type dependencies.
    go tl ref@(Reference.DerivedId id) =
      getTypeOfTerm codebase ref >>= \case
        Just typ ->
          let z = tl <> TypeLookup (Map.singleton ref typ) mempty mempty
           in depthFirstAccum z (Type.dependencies typ)
        Nothing ->
          getTypeDeclaration codebase id >>= \case
            Just (Left ed) ->
              let z = tl <> TypeLookup mempty mempty (Map.singleton ref ed)
               in depthFirstAccum z (DD.typeDependencies $ DD.toDataDecl ed)
            Just (Right dd) ->
              let z = tl <> TypeLookup mempty (Map.singleton ref dd) mempty
               in depthFirstAccum z (DD.typeDependencies dd)
            Nothing -> pure tl
    go tl Reference.Builtin {} = pure tl -- codebase isn't consulted for builtins
    unseen :: TL.TypeLookup Symbol a -> Reference -> Bool
    unseen tl r =
      isNothing
        ( Map.lookup r (TL.dataDecls tl) $> ()
            <|> Map.lookup r (TL.typeOfTerms tl) $> ()
            <|> Map.lookup r (TL.effectDecls tl) $> ()
        )

toCodeLookup :: (MonadIO m) => Codebase m Symbol Parser.Ann -> CL.CodeLookup Symbol m Parser.Ann
toCodeLookup c =
  CL.CodeLookup (runTransaction c . getTerm c) (runTransaction c . getTypeDeclaration c)
    <> Builtin.codeLookup
    <> IOSource.codeLookupM

-- | Get the type of a term.
--
-- Note that it is possible to call 'putTerm', then 'getTypeOfTerm', and receive @Nothing@, per the semantics of
-- 'putTerm'.
getTypeOfTerm ::
  (BuiltinAnnotation a) =>
  Codebase m Symbol a ->
  Reference ->
  Sqlite.Transaction (Maybe (Type Symbol a))
getTypeOfTerm _c r | debug && trace ("Codebase.getTypeOfTerm " ++ show r) False = undefined
getTypeOfTerm c r = case r of
  Reference.DerivedId h -> getTypeOfTermImpl c h
  r@Reference.Builtin {} ->
    pure $
      fmap (const builtinAnnotation)
        <$> Map.lookup r Builtin.termRefTypes

-- | Get the type of a referent.
getTypeOfReferent ::
  (BuiltinAnnotation a) =>
  Codebase m Symbol a ->
  Referent.Referent ->
  Sqlite.Transaction (Maybe (Type Symbol a))
getTypeOfReferent c = \case
  Referent.Ref r -> getTypeOfTerm c r
  Referent.Con r _ -> getTypeOfConstructor c r

componentReferencesForReference :: Reference -> Sqlite.Transaction (Set Reference)
componentReferencesForReference = \case
  r@Reference.Builtin {} -> pure (Set.singleton r)
  Reference.Derived h _i ->
    Set.mapMonotonic Reference.DerivedId . Reference.componentFromLength h <$> unsafeGetComponentLength h

-- | Get the set of terms, type declarations, and builtin types that depend on the given term, type declaration, or
-- builtin type.
dependents :: Queries.DependentsSelector -> Reference -> Sqlite.Transaction (Set Reference)
dependents selector r =
  Set.union (Builtin.builtinTypeDependents r)
    . Set.map Reference.DerivedId
    <$> SqliteCodebase.Operations.dependentsImpl selector r

dependentsOfComponent :: Hash -> Sqlite.Transaction (Set Reference)
dependentsOfComponent h =
  Set.union (Builtin.builtinTypeDependentsOfComponent h)
    . Set.map Reference.DerivedId
    <$> SqliteCodebase.Operations.dependentsOfComponentImpl h

-- | Get the set of terms-or-constructors that have the given type.
termsOfType :: (Var v) => Codebase m v a -> Type v a -> Sqlite.Transaction (Set Referent.Referent)
termsOfType c ty = termsOfTypeByReference c $ Hashing.typeToReference ty

-- | Get all terms which match the exact type the provided reference points to.
termsOfTypeByReference :: (Var v) => Codebase m v a -> Reference -> Sqlite.Transaction (Set Referent.Referent)
termsOfTypeByReference c r =
  Set.union (Rel.lookupDom r Builtin.builtinTermsByType)
    . Set.map (fmap Reference.DerivedId)
    <$> termsOfTypeImpl c r

-- | Get the set of terms-or-constructors mention the given type anywhere in their signature.
termsMentioningType :: (Var v) => Codebase m v a -> Type v a -> Sqlite.Transaction (Set Referent.Referent)
termsMentioningType c ty =
  Set.union (Rel.lookupDom r Builtin.builtinTermsByTypeMention)
    . Set.map (fmap Reference.DerivedId)
    <$> termsMentioningTypeImpl c r
  where
    r = Hashing.typeToReference ty

-- | Check whether a reference is a term.
isTerm ::
  (BuiltinAnnotation a) =>
  Codebase m Symbol a ->
  Reference ->
  Sqlite.Transaction Bool
isTerm code = fmap isJust . getTypeOfTerm code

isType :: Codebase m v a -> Reference -> Sqlite.Transaction Bool
isType c r = case r of
  Reference.Builtin {} -> pure $ Builtin.isBuiltinType r
  Reference.DerivedId r -> isJust <$> getTypeDeclaration c r

-- * Git stuff

-- | An optional preprocessing step to run on branches
-- before they're imported into the local codebase.
data Preprocessing m
  = Unmodified
  | Preprocessed (Branch m -> m (Branch m))

-- | Sync elements as needed from a remote git codebase into the local one.
-- If `sch` is supplied, we try to load the specified branch hash;
-- otherwise we try to load the root branch.
importRemoteBranch ::
  forall m v a.
  (MonadUnliftIO m) =>
  Codebase m v a ->
  ReadGitRemoteNamespace ->
  SyncMode ->
  Preprocessing m ->
  m (Either GitError (Branch m))
importRemoteBranch codebase ns mode preprocess = runExceptT $ do
  branchHash <- ExceptT . viewRemoteBranch' codebase ns Git.RequireExistingBranch $ \(branch, cacheDir) -> do
    withStatus "Importing downloaded files into local codebase..." $ do
      processedBranch <- preprocessOp branch
      time "SyncFromDirectory" $ do
        syncFromDirectory codebase cacheDir mode processedBranch
        pure $ Branch.headHash processedBranch
  time "load fresh local branch after sync" $ do
    lift (getBranchForHash codebase branchHash) >>= \case
      Nothing -> throwE . GitCodebaseError $ GitError.CouldntLoadSyncedBranch ns branchHash
      Just result -> pure $ result
  where
    preprocessOp :: Branch m -> m (Branch m)
    preprocessOp = case preprocess of
      Preprocessed f -> f
      Unmodified -> pure

-- | Pull a git branch and view it from the cache, without syncing into the
-- local codebase.
viewRemoteBranch ::
  (MonadIO m) =>
  Codebase m v a ->
  ReadGitRemoteNamespace ->
  Git.GitBranchBehavior ->
  (Branch m -> m r) ->
  m (Either GitError r)
viewRemoteBranch codebase ns gitBranchBehavior action =
  viewRemoteBranch' codebase ns gitBranchBehavior (\(b, _dir) -> action b)

unsafeGetComponentLength :: (HasCallStack) => Hash -> Sqlite.Transaction Reference.CycleSize
unsafeGetComponentLength h =
  Operations.getCycleLen h >>= \case
    Nothing -> error (reportBug "E713350" ("component with hash " ++ show h ++ " not found"))
    Just size -> pure size

-- | Like 'getTerm', for when the term is known to exist in the codebase.
unsafeGetTerm :: (HasCallStack) => Codebase m v a -> Reference.Id -> Sqlite.Transaction (Term v a)
unsafeGetTerm codebase rid =
  getTerm codebase rid >>= \case
    Nothing -> error (reportBug "E520818" ("term " ++ show rid ++ " not found"))
    Just term -> pure term

-- | Like 'getTypeDeclaration', for when the type declaration is known to exist in the codebase.
unsafeGetTypeDeclaration :: (HasCallStack) => Codebase m v a -> Reference.Id -> Sqlite.Transaction (Decl v a)
unsafeGetTypeDeclaration codebase rid =
  getTypeDeclaration codebase rid >>= \case
    Nothing -> error (reportBug "E129043" ("type decl " ++ show rid ++ " not found"))
    Just decl -> pure decl

-- | Like 'getTypeOfTerm', but for when the term is known to exist in the codebase.
unsafeGetTypeOfTermById :: (HasCallStack) => Codebase m v a -> Reference.Id -> Sqlite.Transaction (Type v a)
unsafeGetTypeOfTermById codebase rid =
  getTypeOfTermImpl codebase rid >>= \case
    Nothing -> error (reportBug "E377910" ("type of term " ++ show rid ++ " not found"))
    Just ty -> pure ty

-- | Like 'unsafeGetTerm', but returns the type of the term, too.
unsafeGetTermWithType :: (HasCallStack) => Codebase m v a -> Reference.Id -> Sqlite.Transaction (Term v a, Type v a)
unsafeGetTermWithType codebase rid = do
  term <- unsafeGetTerm codebase rid
  ty <-
    -- A term is sometimes stored with a type annotation (specifically, when the annotation is different from the
    -- inferred type). In this case, we can avoid looking up the type separately.
    case term of
      Term.Ann' _ ty -> pure ty
      _ -> unsafeGetTypeOfTermById codebase rid
  pure (term, ty)

-- | Like 'getTermComponentWithTypes', for when the term component is known to exist in the codebase.
unsafeGetTermComponent ::
  (HasCallStack) =>
  Codebase m v a ->
  Hash ->
  Sqlite.Transaction [(Term v a, Type v a)]
unsafeGetTermComponent codebase hash =
  getTermComponentWithTypes codebase hash <&> \case
    Nothing -> error (reportBug "E769004" ("term component " ++ show hash ++ " not found"))
    Just terms -> terms
