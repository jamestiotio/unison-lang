{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

module Unison.Server.Backend
  ( -- * Types
    BackendError (..),
    Backend (..),
    ShallowListEntry (..),
    BackendEnv (..),
    TypeEntry (..),
    FoundRef (..),
    NameScoping (..),
    IncludeCycles (..),
    DefinitionResults (..),

    -- * Endpoints
    fuzzyFind,

    -- * Utilities
    basicSuffixifiedNames,
    bestNameForTerm,
    bestNameForType,
    definitionsBySuffixes,
    displayType,
    docsInBranchToHtmlFiles,
    expandShortCausalHash,
    findDocInBranch,
    formatSuffixedType,
    getCurrentParseNames,
    getCurrentPrettyNames,
    getShallowCausalAtPathFromRootHash,
    getTermTag,
    getTypeTag,
    hoistBackend,
    hqNameQuery,
    loadReferentType,
    loadSearchResults,
    lsAtPath,
    lsBranch,
    mungeSyntaxText,
    namesForBranch,
    parseNamesForBranch,
    prettyNamesForBranch,
    resolveCausalHashV2,
    resolveRootBranchHashV2,
    scopedNamesForBranchHash,
    termEntryDisplayName,
    termEntryHQName,
    termEntryToNamedTerm,
    termEntryType,
    termEntryLabeledDependencies,
    termListEntry,
    termReferentsByShortHash,
    typeDeclHeader,
    typeEntryDisplayName,
    typeEntryHQName,
    typeEntryToNamedType,
    typeEntryLabeledDependencies,
    typeListEntry,
    typeReferencesByShortHash,
    typeToSyntaxHeader,
    renderDocRefs,
    docsForDefinitionName,
    normaliseRootCausalHash,
    causalHashForProjectBranchName,

    -- * Unused, could remove?
    resolveRootBranchHash,
    shallowPPE,
    isTestResultList,
    toAllNames,
    fixupNamesRelative,

    -- * Re-exported for Share Server
    termsToSyntax,
    typesToSyntax,
    definitionResultsDependencies,
    termEntryTag,
    evalDocRef,
    mkTermDefinition,
    mkTypeDefinition,
    displayTerm,
  )
where

import Control.Error.Util (hush)
import Control.Lens hiding ((??))
import Control.Lens.Cons qualified as Cons
import Control.Monad.Except
import Control.Monad.Reader
import Data.Containers.ListUtils (nubOrdOn)
import Data.List qualified as List
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextE
import Data.Text.Lazy (toStrict)
import Data.Tuple.Extra (dupe)
import Data.Yaml qualified as Yaml
import Lucid qualified
import System.Directory
import System.FilePath
import Text.FuzzyFind qualified as FZF
import U.Codebase.Branch (NamespaceStats (..))
import U.Codebase.Branch qualified as V2Branch
import U.Codebase.Causal qualified as V2Causal
import U.Codebase.HashTags (BranchHash, CausalHash (..))
import U.Codebase.Referent qualified as V2Referent
import U.Codebase.Sqlite.Operations qualified as Operations
import U.Codebase.Sqlite.Operations qualified as Ops
import U.Codebase.Sqlite.ProjectBranch (ProjectBranch (..))
import U.Codebase.Sqlite.Queries qualified as Q
import Unison.ABT qualified as ABT
import Unison.Builtin qualified as B
import Unison.Builtin.Decls qualified as Decls
import Unison.Codebase (Codebase)
import Unison.Codebase qualified as Codebase
import Unison.Codebase qualified as UCodebase
import Unison.Codebase.Branch (Branch)
import Unison.Codebase.Branch qualified as Branch
import Unison.Codebase.Branch.Names qualified as Branch
import Unison.Codebase.Editor.DisplayObject
import Unison.Codebase.Editor.DisplayObject qualified as DisplayObject
import Unison.Codebase.Path (Path)
import Unison.Codebase.Path qualified as Path
import Unison.Codebase.Runtime qualified as Rt
import Unison.Codebase.ShortCausalHash
  ( ShortCausalHash,
  )
import Unison.Codebase.ShortCausalHash qualified as SCH
import Unison.Codebase.SqliteCodebase.Conversions qualified as Cv
import Unison.ConstructorReference (GConstructorReference (..))
import Unison.ConstructorReference qualified as ConstructorReference
import Unison.ConstructorType qualified as CT
import Unison.DataDeclaration qualified as DD
import Unison.HashQualified qualified as HQ
import Unison.HashQualified' qualified as HQ'
import Unison.Hashing.V2.Convert qualified as Hashing
import Unison.LabeledDependency qualified as LD
import Unison.Name (Name)
import Unison.Name qualified as Name
import Unison.NameSegment (NameSegment (..))
import Unison.NameSegment qualified as NameSegment
import Unison.Names (Names (Names))
import Unison.Names qualified as Names
import Unison.Names.Scoped qualified as ScopedNames
import Unison.NamesWithHistory (NamesWithHistory (..))
import Unison.NamesWithHistory qualified as NamesWithHistory
import Unison.Parser.Ann (Ann)
import Unison.Prelude
import Unison.PrettyPrintEnv qualified as PPE
import Unison.PrettyPrintEnv.Util qualified as PPE
import Unison.PrettyPrintEnvDecl qualified as PPED
import Unison.PrettyPrintEnvDecl.Names qualified as PPED
import Unison.Project (ProjectAndBranch (..), ProjectBranchName, ProjectName)
import Unison.Project.Util qualified as ProjectUtils
import Unison.Reference (Reference, TermReference)
import Unison.Reference qualified as Reference
import Unison.Referent (Referent)
import Unison.Referent qualified as Referent
import Unison.Runtime.IOSource qualified as DD
import Unison.Server.Doc qualified as Doc
import Unison.Server.Doc.AsHtml qualified as DocHtml
import Unison.Server.NameSearch (NameSearch (..), Search (..), applySearch)
import Unison.Server.NameSearch.Sqlite (termReferentsByShortHash, typeReferencesByShortHash)
import Unison.Server.QueryResult
import Unison.Server.SearchResult qualified as SR
import Unison.Server.SearchResult' qualified as SR'
import Unison.Server.Syntax qualified as Syntax
import Unison.Server.Types
import Unison.Server.Types qualified as ServerTypes
import Unison.ShortHash
import Unison.ShortHash qualified as SH
import Unison.Sqlite qualified as Sqlite
import Unison.Symbol (Symbol)
import Unison.Syntax.DeclPrinter qualified as DeclPrinter
import Unison.Syntax.HashQualified' qualified as HQ' (toText)
import Unison.Syntax.Name as Name (toText, unsafeFromText)
import Unison.Syntax.NamePrinter qualified as NP
import Unison.Syntax.TermPrinter qualified as TermPrinter
import Unison.Syntax.TypePrinter qualified as TypePrinter
import Unison.Term (Term)
import Unison.Term qualified as Term
import Unison.Type (Type)
import Unison.Type qualified as Type
import Unison.Typechecker qualified as Typechecker
import Unison.Util.AnnotatedText (AnnotatedText)
import Unison.Util.List (uniqueBy)
import Unison.Util.Map qualified as Map
import Unison.Util.Monoid (foldMapM)
import Unison.Util.Monoid qualified as Monoid
import Unison.Util.Pretty (Width)
import Unison.Util.Pretty qualified as Pretty
import Unison.Util.Relation qualified as R
import Unison.Util.Set qualified as Set
import Unison.Util.SyntaxText qualified as UST
import Unison.Var (Var)
import Unison.WatchKind qualified as WK
import UnliftIO.Environment qualified as Env

type SyntaxText = UST.SyntaxText' Reference

data ShallowListEntry v a
  = ShallowTermEntry (TermEntry v a)
  | ShallowTypeEntry TypeEntry
  | ShallowBranchEntry NameSegment CausalHash NamespaceStats
  | ShallowPatchEntry NameSegment
  deriving (Eq, Ord, Show, Generic)

listEntryName :: ShallowListEntry v a -> Text
listEntryName = \case
  ShallowTermEntry te -> termEntryDisplayName te
  ShallowTypeEntry te -> typeEntryDisplayName te
  ShallowBranchEntry n _ _ -> NameSegment.toText n
  ShallowPatchEntry n -> NameSegment.toText n

data BackendError
  = NoSuchNamespace Path.Absolute
  | -- Failed to parse path
    BadNamespace
      String
      -- ^ error message
      String
      -- ^ namespace
  | CouldntExpandBranchHash ShortCausalHash
  | AmbiguousBranchHash ShortCausalHash (Set ShortCausalHash)
  | AmbiguousHashForDefinition ShortHash
  | NoBranchForHash CausalHash
  | CouldntLoadBranch CausalHash
  | MissingSignatureForTerm Reference
  | NoSuchDefinition (HQ.HashQualified Name)
  | -- We needed a name lookup index we didn't have.
    ExpectedNameLookup BranchHash
  | -- The inferred project root for a given perspective is neither a parent nor child
    -- of the perspective. This shouldn't happen and indicates a bug.
    -- (perspective, project root)
    DisjointProjectAndPerspective Path Path
  | ProjectBranchNameNotFound ProjectName ProjectBranchName
  deriving stock (Show)

newtype BackendEnv = BackendEnv
  { -- | Whether to use the sqlite name-lookup table to generate Names objects rather than building Names from the root branch.
    useNamesIndex :: Bool
  }

newtype Backend m a = Backend {runBackend :: ReaderT BackendEnv (ExceptT BackendError m) a}
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader BackendEnv, MonadError BackendError)

instance MonadTrans Backend where
  lift m = Backend (lift . lift $ m)

hoistBackend :: (forall x. m x -> n x) -> Backend m a -> Backend n a
hoistBackend f (Backend m) =
  Backend (mapReaderT (mapExceptT f) m)

suffixifyNames :: Int -> Names -> PPE.PrettyPrintEnv
suffixifyNames hashLength names =
  PPED.suffixifiedPPE . PPED.fromNamesDecl hashLength $ NamesWithHistory.fromCurrentNames names

-- implementation detail of parseNamesForBranch and prettyNamesForBranch
-- Returns (parseNames, prettyNames, localNames)
namesForBranch :: Branch m -> NameScoping -> (Names, Names, Names)
namesForBranch root scope =
  (parseNames0, prettyPrintNames0, currentPathNames)
  where
    path :: Path
    includeAllNames :: Bool
    (path, includeAllNames) = case scope of
      AllNames path -> (path, True)
      Within path -> (path, False)
      WithinStrict path -> (path, False)
    root0 = Branch.head root
    currentBranch = fromMaybe Branch.empty $ Branch.getAt path root
    absoluteRootNames = Names.makeAbsolute (Branch.toNames root0)
    currentBranch0 = Branch.head currentBranch
    currentPathNames = Branch.toNames currentBranch0
    -- all names, but with local names in their relative form only, rather
    -- than absolute; external names appear as absolute
    currentAndExternalNames =
      currentPathNames
        `Names.unionLeft` Names.mapNames Name.makeAbsolute externalNames
      where
        externalNames = rootNames `Names.difference` pathPrefixed currentPathNames
        rootNames = Branch.toNames root0
        pathPrefixed = case Path.toName path of
          Nothing -> const mempty
          Just pathName -> Names.prefix0 pathName
    -- parsing should respond to local and absolute names
    parseNames0 = currentPathNames <> Monoid.whenM includeAllNames absoluteRootNames
    -- pretty-printing should use local names where available
    prettyPrintNames0 =
      if includeAllNames
        then currentAndExternalNames
        else currentPathNames

basicSuffixifiedNames :: Int -> Branch m -> NameScoping -> PPE.PrettyPrintEnv
basicSuffixifiedNames hashLength root nameScope =
  let names0 = prettyNamesForBranch root nameScope
   in suffixifyNames hashLength names0

parseNamesForBranch :: Branch m -> NameScoping -> Names
parseNamesForBranch root = namesForBranch root <&> \(n, _, _) -> n

prettyNamesForBranch :: Branch m -> NameScoping -> Names
prettyNamesForBranch root = namesForBranch root <&> \(_, n, _) -> n

shallowPPE :: (MonadIO m) => Codebase m v a -> V2Branch.Branch m -> m PPE.PrettyPrintEnv
shallowPPE codebase b = do
  (hashLength, names) <- Codebase.runTransaction codebase do
    hl <- Codebase.hashLength
    names <- shallowNames codebase b
    pure (hl, names)
  pure $ PPED.suffixifiedPPE . PPED.fromNamesDecl hashLength $ NamesWithHistory names mempty

-- | A 'Names' which only includes mappings for things _directly_ accessible from the branch.
--
-- I.e. names in nested children are omitted.
-- This should probably live elsewhere, but the package dependency graph makes it hard to find
-- a good place.
shallowNames :: forall m v a. (Monad m) => Codebase m v a -> V2Branch.Branch m -> Sqlite.Transaction Names
shallowNames codebase b = do
  newTerms <-
    V2Branch.terms b
      & Map.mapKeys Name.fromSegment
      & fmap Map.keysSet
      & traverse . Set.traverse %%~ Cv.referent2to1 (Codebase.getDeclType codebase)

  let newTypes =
        V2Branch.types b
          & Map.mapKeys Name.fromSegment
          & fmap Map.keysSet
          & traverse . Set.traverse %~ Cv.reference2to1
  pure (Names (R.fromMultimap newTerms) (R.fromMultimap newTypes))

loadReferentType ::
  Codebase m Symbol Ann ->
  Referent ->
  Sqlite.Transaction (Maybe (Type Symbol Ann))
loadReferentType codebase = \case
  Referent.Ref r -> Codebase.getTypeOfTerm codebase r
  Referent.Con r _ -> getTypeOfConstructor r
  where
    -- Mitchell wonders: why was this definition copied from Unison.Codebase?
    getTypeOfConstructor (ConstructorReference (Reference.DerivedId r) cid) = do
      maybeDecl <- Codebase.getTypeDeclaration codebase r
      pure $ case maybeDecl of
        Nothing -> Nothing
        Just decl -> DD.typeOfConstructor (either DD.toDataDecl id decl) cid
    getTypeOfConstructor r =
      error $
        "Don't know how to getTypeOfConstructor "
          ++ show r

data TermEntry v a = TermEntry
  { termEntryReferent :: V2Referent.Referent,
    termEntryHash :: ShortHash,
    termEntryName :: NameSegment,
    termEntryConflicted :: Bool,
    termEntryType :: Maybe (Type v a),
    termEntryTag :: TermTag
  }
  deriving (Eq, Ord, Show, Generic)

termEntryLabeledDependencies :: Ord v => TermEntry v a -> Set LD.LabeledDependency
termEntryLabeledDependencies TermEntry {termEntryType, termEntryReferent, termEntryTag} =
  foldMap Type.labeledDependencies termEntryType
    <> Set.singleton (LD.TermReferent (Cv.referent2to1UsingCT ct termEntryReferent))
  where
    ct :: V2Referent.ConstructorType
    ct = case termEntryTag of
      ServerTypes.Constructor ServerTypes.Ability -> V2Referent.EffectConstructor
      ServerTypes.Constructor ServerTypes.Data -> V2Referent.DataConstructor
      _ -> error "termEntryLabeledDependencies: not a constructor, but one was required"

termEntryDisplayName :: TermEntry v a -> Text
termEntryDisplayName = HQ'.toTextWith NameSegment.toText . termEntryHQName

termEntryHQName :: TermEntry v a -> HQ'.HashQualified NameSegment
termEntryHQName TermEntry {termEntryName, termEntryConflicted, termEntryHash} =
  if termEntryConflicted
    then HQ'.HashQualified termEntryName termEntryHash
    else HQ'.NameOnly termEntryName

data TypeEntry = TypeEntry
  { typeEntryReference :: Reference,
    typeEntryHash :: ShortHash,
    typeEntryName :: NameSegment,
    typeEntryConflicted :: Bool,
    typeEntryTag :: TypeTag
  }
  deriving (Eq, Ord, Show, Generic)

typeEntryLabeledDependencies :: TypeEntry -> Set LD.LabeledDependency
typeEntryLabeledDependencies TypeEntry {typeEntryReference} =
  Set.singleton (LD.TypeReference typeEntryReference)

typeEntryDisplayName :: TypeEntry -> Text
typeEntryDisplayName = HQ'.toTextWith NameSegment.toText . typeEntryHQName

typeEntryHQName :: TypeEntry -> HQ'.HashQualified NameSegment
typeEntryHQName TypeEntry {typeEntryName, typeEntryConflicted, typeEntryReference} =
  if typeEntryConflicted
    then HQ'.HashQualified typeEntryName (Reference.toShortHash typeEntryReference)
    else HQ'.NameOnly typeEntryName

data FoundRef
  = FoundTermRef Referent
  | FoundTypeRef Reference
  deriving (Eq, Ord, Show, Generic)

-- After finding a search results with fuzzy find we do some post processing to
-- refine the result:
--  * Sort:
--      we sort both on the FZF score and the number of segments in the FQN
--      preferring shorter FQNs over longer. This helps with things like forks
--      of base.
--  * Dedupe:
--      we dedupe on the found refs to avoid having several rows of a
--      definition with different names in the result set.
fuzzyFind ::
  Names ->
  String ->
  [(FZF.Alignment, UnisonName, [FoundRef])]
fuzzyFind printNames query =
  let fzfNames =
        Names.fuzzyFind Name.toText (words query) printNames

      toFoundRef =
        fmap (fmap (either FoundTermRef FoundTypeRef) . toList)

      -- Remove dupes based on refs
      dedupe =
        nubOrdOn (\(_, _, refs) -> refs)

      -- Prefer shorter FQNs
      rank (alignment, name, _) =
        ( Name.countSegments (Name.unsafeFromText name),
          negate (FZF.score alignment)
        )

      refine =
        dedupe . sortOn rank
   in refine $ toFoundRef . over _2 Name.toText <$> fzfNames

-- List the immediate children of a namespace
lsAtPath ::
  (MonadIO m) =>
  Codebase m Symbol Ann ->
  -- The root to follow the path from.
  Maybe (V2Branch.Branch Sqlite.Transaction) ->
  -- Path from the root to the branch to 'ls'
  Path.Absolute ->
  m [ShallowListEntry Symbol Ann]
lsAtPath codebase mayRootBranch absPath = do
  b <- Codebase.runTransaction codebase (Codebase.getShallowBranchAtPath (Path.unabsolute absPath) mayRootBranch)
  lsBranch codebase b

findDocInBranch ::
  Set NameSegment ->
  V2Branch.Branch m ->
  Maybe TermReference
findDocInBranch names namespaceBranch =
  let -- choose the first term (among conflicted terms) matching any of these names, in this order.
      -- we might later want to return all of them to let the front end decide
      toCheck = Set.toList names
      readmeRef :: Maybe Reference
      readmeRef = listToMaybe $ do
        name <- toCheck
        term <- toList $ Map.lookup name termsMap
        k <- Map.keys term
        case k of
          -- This shouldn't ever happen unless someone puts a non-doc as their readme.
          V2Referent.Con {} -> empty
          V2Referent.Ref ref -> pure $ Cv.reference2to1 ref
        where
          termsMap = V2Branch.terms namespaceBranch
   in readmeRef

isDoc :: Codebase m Symbol Ann -> Referent.Referent -> Sqlite.Transaction Bool
isDoc codebase ref = do
  ot <- loadReferentType codebase ref
  pure $ isDoc' ot

isDoc' :: (Var v, Monoid loc) => Maybe (Type v loc) -> Bool
isDoc' typeOfTerm = do
  -- A term is a dococ if its type conforms to the `Doc` type.
  case typeOfTerm of
    Just t ->
      Typechecker.isSubtype t doc1Type
        || Typechecker.isSubtype t doc2Type
    Nothing -> False

doc1Type :: (Ord v, Monoid a) => Type v a
doc1Type = Type.ref mempty Decls.docRef

doc2Type :: (Ord v, Monoid a) => Type v a
doc2Type = Type.ref mempty DD.doc2Ref

isTestResultList :: forall v a. (Var v, Monoid a) => Maybe (Type v a) -> Bool
isTestResultList typ = case typ of
  Nothing -> False
  Just t -> Typechecker.isSubtype t resultListType

resultListType :: (Ord v, Monoid a) => Type v a
resultListType = Type.app mempty (Type.list mempty) (Type.ref mempty Decls.testResultRef)

termListEntry ::
  (MonadIO m) =>
  Codebase m Symbol Ann ->
  -- | Optional branch to check if the term is conflicted.
  -- If omitted, all terms are just listed as not conflicted.
  Maybe (V2Branch.Branch n) ->
  ExactName NameSegment V2Referent.Referent ->
  m (TermEntry Symbol Ann)
termListEntry codebase mayBranch (ExactName nameSegment ref) = do
  ot <- Codebase.runTransaction codebase $ do
    v1Referent <- Cv.referent2to1 (Codebase.getDeclType codebase) ref
    ot <- loadReferentType codebase v1Referent
    pure (ot)
  tag <- getTermTag codebase ref ot
  pure $
    TermEntry
      { termEntryReferent = ref,
        termEntryName = nameSegment,
        termEntryType = ot,
        termEntryTag = tag,
        termEntryConflicted = isConflicted,
        termEntryHash = Cv.referent2toshorthash1 Nothing ref
      }
  where
    isConflicted = case mayBranch of
      Nothing -> False
      Just branch ->
        branch
          & V2Branch.terms
          & Map.lookup nameSegment
          & maybe 0 Map.size
          & (> 1)

getTermTag ::
  (Var v, MonadIO m) =>
  Codebase m v a ->
  V2Referent.Referent ->
  Maybe (Type v Ann) ->
  m TermTag
getTermTag codebase r sig = do
  -- A term is a doc if its type conforms to the `Doc` type.
  let isDoc = case sig of
        Just t ->
          Typechecker.isSubtype t (Type.ref mempty Decls.docRef)
            || Typechecker.isSubtype t (Type.ref mempty DD.doc2Ref)
        Nothing -> False
  -- A term is a test if it has the type [test.Result]
  let isTest = case sig of
        Just t ->
          Typechecker.isSubtype t (Decls.testResultType mempty)
        Nothing -> False
  constructorType <- case r of
    V2Referent.Ref {} -> pure Nothing
    V2Referent.Con ref _ -> Just <$> Codebase.runTransaction codebase (Codebase.getDeclType codebase ref)
  pure $
    if
        | isDoc -> Doc
        | isTest -> Test
        | Just CT.Effect <- constructorType -> Constructor Ability
        | Just CT.Data <- constructorType -> Constructor Data
        | otherwise -> Plain

getTypeTag ::
  (Var v) =>
  Codebase m v Ann ->
  Reference ->
  Sqlite.Transaction TypeTag
getTypeTag codebase r = do
  case Reference.toId r of
    Just r -> do
      decl <- Codebase.getTypeDeclaration codebase r
      pure $ case decl of
        Just (Left _) -> Ability
        _ -> Data
    _ -> pure (if Set.member r Type.builtinAbilities then Ability else Data)

typeListEntry ::
  (Var v) =>
  Codebase m v Ann ->
  -- | Optional branch to check if the term is conflicted.
  -- If omitted, all terms are just listed as not conflicted.
  Maybe (V2Branch.Branch n) ->
  ExactName NameSegment Reference ->
  Sqlite.Transaction TypeEntry
typeListEntry codebase mayBranch (ExactName nameSegment ref) = do
  hashLength <- Codebase.hashLength
  tag <- getTypeTag codebase ref
  pure $
    TypeEntry
      { typeEntryReference = ref,
        typeEntryName = nameSegment,
        typeEntryConflicted = isConflicted,
        typeEntryTag = tag,
        typeEntryHash = SH.take hashLength $ Reference.toShortHash ref
      }
  where
    isConflicted = case mayBranch of
      Nothing -> False
      Just branch ->
        branch
          & V2Branch.types
          & Map.lookup nameSegment
          & maybe 0 Map.size
          & (> 1)

typeDeclHeader ::
  forall v m.
  (Var v) =>
  Codebase m v Ann ->
  PPE.PrettyPrintEnv ->
  Reference ->
  Sqlite.Transaction (DisplayObject Syntax.SyntaxText Syntax.SyntaxText)
typeDeclHeader code ppe r = case Reference.toId r of
  Just rid ->
    Codebase.getTypeDeclaration code rid <&> \case
      Nothing -> DisplayObject.MissingObject (Reference.toShortHash r)
      Just decl ->
        DisplayObject.UserObject $
          Syntax.convertElement
            <$> Pretty.render defaultWidth (DeclPrinter.prettyDeclHeader name decl)
  Nothing ->
    pure (DisplayObject.BuiltinObject (formatTypeName ppe r))
  where
    name = PPE.typeName ppe r

formatTypeName :: PPE.PrettyPrintEnv -> Reference -> Syntax.SyntaxText
formatTypeName ppe =
  fmap Syntax.convertElement . formatTypeName' ppe

formatTypeName' :: PPE.PrettyPrintEnv -> Reference -> SyntaxText
formatTypeName' ppe r =
  Pretty.renderUnbroken
    . NP.styleHashQualified id
    $ PPE.typeName ppe r

termEntryToNamedTerm ::
  (Var v) => PPE.PrettyPrintEnv -> Maybe Width -> TermEntry v a -> NamedTerm
termEntryToNamedTerm ppe typeWidth te@TermEntry {termEntryType = mayType, termEntryTag = tag, termEntryHash} =
  NamedTerm
    { termName = termEntryHQName te,
      termHash = termEntryHash,
      termType = formatType ppe (mayDefaultWidth typeWidth) <$> mayType,
      termTag = tag
    }

typeEntryToNamedType :: TypeEntry -> NamedType
typeEntryToNamedType te@TypeEntry {typeEntryTag, typeEntryHash} =
  NamedType
    { typeName = typeEntryHQName $ te,
      typeHash = typeEntryHash,
      typeTag = typeEntryTag
    }

-- | Find all definitions and children reachable from the given 'V2Branch.Branch',
lsBranch ::
  (MonadIO m) =>
  Codebase m Symbol Ann ->
  V2Branch.Branch n ->
  m [ShallowListEntry Symbol Ann]
lsBranch codebase b0 = do
  let flattenRefs :: Map NameSegment (Map ref v) -> [(ref, NameSegment)]
      flattenRefs m = do
        (ns, refs) <- Map.toList m
        r <- Map.keys refs
        pure (r, ns)
  termEntries <- for (flattenRefs $ V2Branch.terms b0) $ \(r, ns) -> do
    ShallowTermEntry <$> termListEntry codebase (Just b0) (ExactName ns r)
  typeEntries <-
    Codebase.runTransaction codebase do
      for (flattenRefs $ V2Branch.types b0) \(r, ns) -> do
        let v1Ref = Cv.reference2to1 r
        ShallowTypeEntry <$> typeListEntry codebase (Just b0) (ExactName ns v1Ref)
  childrenWithStats <- Codebase.runTransaction codebase (V2Branch.childStats b0)
  let branchEntries :: [ShallowListEntry Symbol Ann] = do
        (ns, (h, stats)) <- Map.toList $ childrenWithStats
        guard $ V2Branch.hasDefinitions stats
        pure $ ShallowBranchEntry ns (V2Causal.causalHash h) stats
      patchEntries :: [ShallowListEntry Symbol Ann] = do
        (ns, _h) <- Map.toList $ V2Branch.patches b0
        pure $ ShallowPatchEntry ns
  pure . List.sortOn listEntryName $
    termEntries
      ++ typeEntries
      ++ branchEntries
      ++ patchEntries

-- currentPathNames :: Path -> Names
-- currentPathNames = Branch.toNames . Branch.head . Branch.getAt

-- | Configure how names will be constructed and filtered.
--   this is typically used when fetching names for printing source code or when finding
--   definitions by name.
data NameScoping
  = -- | Find all names, making any names which are children of this path,
    -- otherwise leave them absolute.
    AllNames Path
  | -- | Filter returned names to only include names within this path.
    Within Path
  | -- | Like `Within`, but does not include a fallback
    WithinStrict Path

toAllNames :: NameScoping -> NameScoping
toAllNames (AllNames p) = AllNames p
toAllNames (Within p) = AllNames p
toAllNames (WithinStrict p) = AllNames p

getCurrentPrettyNames :: Int -> NameScoping -> Branch m -> PPED.PrettyPrintEnvDecl
getCurrentPrettyNames hashLen scope root =
  case scope of
    WithinStrict _ -> primary
    _ ->
      PPED.PrettyPrintEnvDecl
        (PPED.unsuffixifiedPPE primary `PPE.addFallback` PPED.unsuffixifiedPPE backup)
        (PPED.suffixifiedPPE primary `PPE.addFallback` PPED.suffixifiedPPE backup)
      where
        backup = PPED.fromNamesDecl hashLen $ NamesWithHistory (parseNamesForBranch root (AllNames mempty)) mempty
  where
    primary = PPED.fromNamesDecl hashLen $ NamesWithHistory (parseNamesForBranch root scope) mempty

getCurrentParseNames :: NameScoping -> Branch m -> NamesWithHistory
getCurrentParseNames scope root =
  NamesWithHistory (parseNamesForBranch root scope) mempty

-- Any absolute names in the input which have `root` as a prefix
-- are converted to names relative to current path. All other names are
-- converted to absolute names. For example:
--
-- e.g. if currentPath = .foo.bar
--      then name foo.bar.baz becomes baz
--           name cat.dog     becomes .cat.dog
fixupNamesRelative :: Path.Absolute -> Names -> Names
fixupNamesRelative root names =
  case Path.toName $ Path.unabsolute root of
    Nothing -> names
    Just prefix -> Names.map (fixName prefix) names
  where
    fixName prefix n =
      if root == Path.absoluteEmpty
        then n
        else fromMaybe (Name.makeAbsolute n) (Name.stripNamePrefix prefix n)

hqNameQuery ::
  Codebase m v Ann ->
  NameSearch Sqlite.Transaction ->
  [HQ.HashQualified Name] ->
  Sqlite.Transaction QueryResult
hqNameQuery codebase NameSearch {typeSearch, termSearch} hqs = do
  -- Split the query into hash-only and hash-qualified-name queries.
  let (hashes, hqnames) = partitionEithers (map HQ'.fromHQ2 hqs)
  -- Find the terms with those hashes.
  termRefs <-
    filter (not . Set.null . snd) . zip hashes
      <$> traverse
        (termReferentsByShortHash codebase)
        hashes
  -- Find types with those hashes.
  typeRefs <-
    filter (not . Set.null . snd) . zip hashes
      <$> traverse
        typeReferencesByShortHash
        hashes
  -- Now do the name queries.
  let mkTermResult sh r = SR.termResult (HQ.HashOnly sh) r Set.empty
      mkTypeResult sh r = SR.typeResult (HQ.HashOnly sh) r Set.empty
      -- Transform the hash results a bit
      termResults =
        (\(sh, tms) -> mkTermResult sh <$> toList tms) <$> termRefs
      typeResults =
        (\(sh, tps) -> mkTypeResult sh <$> toList tps) <$> typeRefs

  -- Now do the actual name query
  resultss <- for hqnames (\name -> liftA2 (<>) (applySearch typeSearch name) (applySearch termSearch name))
  let (misses, hits) =
        zipWith
          ( \hqname results ->
              (if null results then Left hqname else Right results)
          )
          hqnames
          resultss
          & partitionEithers
      -- Handle query misses correctly
      missingRefs =
        [ HQ.HashOnly x
          | x <- hashes,
            isNothing (lookup x termRefs) && isNothing (lookup x typeRefs)
        ]
      -- Gather the results
      results =
        List.sort
          . uniqueBy SR.toReferent
          . concat
          $ (hits ++ termResults ++ typeResults)
  pure
    QueryResult
      { misses = missingRefs ++ map HQ'.toHQ misses,
        hits = results
      }

-- TODO: Move this to its own module
data DefinitionResults = DefinitionResults
  { termResults :: Map Reference (DisplayObject (Type Symbol Ann) (Term Symbol Ann)),
    typeResults :: Map Reference (DisplayObject () (DD.Decl Symbol Ann)),
    noResults :: [HQ.HashQualified Name]
  }
  deriving stock (Show)

-- | Finds ALL direct references contained within a 'DefinitionResults' so we can
-- build a pretty printer for them.
definitionResultsDependencies :: DefinitionResults -> Set LD.LabeledDependency
definitionResultsDependencies (DefinitionResults {termResults, typeResults}) =
  let topLevelTerms = Set.fromList . fmap LD.TermReference $ Map.keys termResults
      topLevelTypes = Set.fromList . fmap LD.TypeReference $ Map.keys typeResults
      termDeps =
        termResults
          & foldOf
            ( folded
                . beside
                  (to Type.labeledDependencies)
                  (to Term.labeledDependencies)
            )
      typeDeps =
        typeResults
          & ifoldMap \typeRef ddObj ->
            foldMap (DD.labeledDeclDependenciesIncludingSelf typeRef) ddObj
   in termDeps <> typeDeps <> topLevelTerms <> topLevelTypes

expandShortCausalHash :: ShortCausalHash -> Backend Sqlite.Transaction CausalHash
expandShortCausalHash hash = do
  hashSet <- lift $ Codebase.causalHashesByPrefix hash
  len <- lift $ Codebase.branchHashLength
  case Set.toList hashSet of
    [] -> throwError $ CouldntExpandBranchHash hash
    [h] -> pure h
    _ ->
      throwError . AmbiguousBranchHash hash $ Set.map (SCH.fromHash len) hashSet

-- | Efficiently resolve a root hash and path to a shallow branch's causal.
getShallowCausalAtPathFromRootHash ::
  Maybe CausalHash ->
  Path ->
  Sqlite.Transaction (V2Branch.CausalBranch Sqlite.Transaction)
getShallowCausalAtPathFromRootHash mayRootHash path = do
  shallowRoot <- case mayRootHash of
    Nothing -> Codebase.getShallowRootCausal
    Just h -> Codebase.expectCausalBranchByCausalHash h
  Codebase.getShallowCausalAtPath path (Just shallowRoot)

formatType' :: (Var v) => PPE.PrettyPrintEnv -> Width -> Type v a -> SyntaxText
formatType' ppe w =
  Pretty.render w . TypePrinter.prettySyntax ppe

formatType :: (Var v) => PPE.PrettyPrintEnv -> Width -> Type v a -> Syntax.SyntaxText
formatType ppe w = mungeSyntaxText . formatType' ppe w

formatSuffixedType ::
  (Var v) =>
  PPED.PrettyPrintEnvDecl ->
  Width ->
  Type v Ann ->
  Syntax.SyntaxText
formatSuffixedType ppe = formatType (PPED.suffixifiedPPE ppe)

mungeSyntaxText ::
  (Functor g) => g (UST.Element Reference) -> g Syntax.Element
mungeSyntaxText = fmap Syntax.convertElement

mkTypeDefinition ::
  MonadIO m =>
  Codebase IO Symbol Ann ->
  PPED.PrettyPrintEnvDecl ->
  Path.Path ->
  V2Branch.CausalBranch Sqlite.Transaction ->
  Width ->
  Reference ->
  [(HashQualifiedName, UnisonHash, Doc.Doc)] ->
  DisplayObject
    (AnnotatedText (UST.Element Reference))
    (AnnotatedText (UST.Element Reference)) ->
  m TypeDefinition
mkTypeDefinition codebase pped namesRoot rootCausal width r docs tp = do
  let bn = bestNameForType @Symbol (PPED.suffixifiedPPE pped) width r
  tag <-
    liftIO $ Codebase.runTransaction codebase do
      causalAtPath <- Codebase.getShallowCausalAtPath namesRoot (Just rootCausal)
      branchAtPath <- V2Causal.value causalAtPath
      typeEntryTag <$> typeListEntry codebase (Just branchAtPath) (ExactName (NameSegment bn) r)
  pure $
    TypeDefinition
      (HQ'.toText <$> PPE.allTypeNames fqnPPE r)
      bn
      tag
      (bimap mungeSyntaxText mungeSyntaxText tp)
      docs
  where
    fqnPPE = PPED.unsuffixifiedPPE pped

mkTermDefinition ::
  Codebase IO Symbol Ann ->
  PPED.PrettyPrintEnvDecl ->
  Path.Path ->
  V2Branch.CausalBranch Sqlite.Transaction ->
  Width ->
  Reference ->
  [(HashQualifiedName, UnisonHash, Doc.Doc)] ->
  DisplayObject
    (AnnotatedText (UST.Element Reference))
    (AnnotatedText (UST.Element Reference)) ->
  Backend IO TermDefinition
mkTermDefinition codebase termPPED namesRoot rootCausal width r docs tm = do
  let referent = Referent.Ref r
  (ts, branchAtPath) <- liftIO $ Codebase.runTransaction codebase do
    ts <- Codebase.getTypeOfTerm codebase r
    causalAtPath <- Codebase.getShallowCausalAtPath namesRoot (Just rootCausal)
    branchAtPath <- V2Causal.value causalAtPath
    pure (ts, branchAtPath)
  let bn = bestNameForTerm @Symbol (PPED.suffixifiedPPE termPPED) width (Referent.Ref r)
  tag <-
    lift
      ( termEntryTag
          <$> termListEntry codebase (Just branchAtPath) (ExactName (NameSegment bn) (Cv.referent1to2 referent))
      )
  mk ts bn tag
  where
    fqnTermPPE = PPED.unsuffixifiedPPE termPPED
    mk Nothing _ _ = throwError $ MissingSignatureForTerm r
    mk (Just typeSig) bn tag = do
      -- We don't ever display individual constructors (they're shown as part of their
      -- type), so term references are never constructors.
      let referent = Referent.Ref r
      pure $
        TermDefinition
          (HQ'.toText <$> PPE.allTermNames fqnTermPPE referent)
          bn
          tag
          (bimap mungeSyntaxText mungeSyntaxText tm)
          (formatSuffixedType termPPED width typeSig)
          docs

-- | Evaluate the doc at the given reference and return its evaluated-but-not-rendered form.
evalDocRef ::
  Rt.Runtime Symbol ->
  Codebase IO Symbol Ann ->
  TermReference ->
  IO (Doc.EvaluatedDoc Symbol)
evalDocRef rt codebase r = do
  let tm = Term.ref () r
  Doc.evalDoc terms typeOf eval decls tm
  where
    terms r@(Reference.Builtin _) = pure (Just (Term.ref () r))
    terms (Reference.DerivedId r) =
      fmap Term.unannotate <$> Codebase.runTransaction codebase (Codebase.getTerm codebase r)

    typeOf r = fmap void <$> Codebase.runTransaction codebase (Codebase.getTypeOfReferent codebase r)
    eval (Term.amap (const mempty) -> tm) = do
      -- We use an empty ppe for evalutation, it's only used for adding additional context to errors.
      let evalPPE = PPE.empty
      let codeLookup = Codebase.toCodeLookup codebase
      let cache r = fmap Term.unannotate <$> Codebase.runTransaction codebase (Codebase.lookupWatchCache codebase r)
      r <- fmap hush . liftIO $ Rt.evaluateTerm' codeLookup cache evalPPE rt tm
      -- Only cache watches when we're not in readonly mode
      Env.lookupEnv "UNISON_READONLY" >>= \case
        Just (_ : _) -> pure ()
        _ -> do
          case r of
            Just tmr ->
              Codebase.runTransaction codebase do
                Codebase.putWatch
                  WK.RegularWatch
                  (Hashing.hashClosedTerm tm)
                  (Term.amap (const mempty) tmr)
            Nothing -> pure ()
      pure $ r <&> Term.amap (const mempty)

    decls (Reference.DerivedId r) =
      fmap (DD.amap (const ())) <$> Codebase.runTransaction codebase (Codebase.getTypeDeclaration codebase r)
    decls _ = pure Nothing

-- | Fetch the docs associated with the given name.
-- Returns all references with a Doc type which are at the name provided, or at '<name>.doc'.
docsForDefinitionName ::
  Codebase IO Symbol Ann ->
  NameSearch Sqlite.Transaction ->
  Name ->
  IO [TermReference]
docsForDefinitionName codebase (NameSearch {termSearch}) name = do
  let potentialDocNames = [name, name Cons.:> "doc"]
  Codebase.runTransaction codebase do
    refs <-
      potentialDocNames & foldMapM \name ->
        -- TODO: Should replace this with an exact name lookup.
        lookupRelativeHQRefs' termSearch (HQ'.NameOnly name)
    filterForDocs (toList refs)
  where
    filterForDocs :: [Referent] -> Sqlite.Transaction [TermReference]
    filterForDocs rs = do
      rts <- fmap join . for rs $ \case
        Referent.Ref r ->
          maybe [] (pure . (r,)) <$> Codebase.getTypeOfTerm codebase r
        _ -> pure []
      pure [r | (r, t) <- rts, Typechecker.isSubtype t (Type.ref mempty DD.doc2Ref)]

-- | Evaluate and render the given docs
renderDocRefs ::
  (Traversable t) =>
  PPED.PrettyPrintEnvDecl ->
  Width ->
  Codebase IO Symbol Ann ->
  Rt.Runtime Symbol ->
  t TermReference ->
  IO (t (HashQualifiedName, UnisonHash, Doc.Doc))
renderDocRefs pped width codebase rt docRefs = do
  eDocs <- for docRefs \ref -> (ref,) <$> (evalDocRef rt codebase ref)
  for eDocs \(ref, eDoc) -> do
    let name = bestNameForTerm @Symbol (PPED.suffixifiedPPE pped) width (Referent.Ref ref)
    let hash = Reference.toText ref
    let renderedDoc = Doc.renderDoc pped eDoc
    pure (name, hash, renderedDoc)

docsInBranchToHtmlFiles ::
  Rt.Runtime Symbol ->
  Codebase IO Symbol Ann ->
  Branch IO ->
  Path ->
  FilePath ->
  IO ()
docsInBranchToHtmlFiles runtime codebase root currentPath directory = do
  let currentBranch = Branch.getAt' currentPath root
  let allTerms = (R.toList . Branch.deepTerms . Branch.head) currentBranch
  -- ignores docs inside lib namespace, recursively
  let notLib (_, name) = "lib" `notElem` Name.segments name
  (docTermsWithNames, hqLength) <-
    Codebase.runTransaction codebase do
      docTermsWithNames <- filterM (isDoc codebase . fst) (filter notLib allTerms)
      hqLength <- Codebase.hashLength
      pure (docTermsWithNames, hqLength)
  let docNamesByRef = Map.fromList docTermsWithNames
  let printNames = prettyNamesForBranch root (AllNames currentPath)
  let printNamesWithHistory = NamesWithHistory {currentNames = printNames, oldNames = mempty}
  let ppe = PPED.fromNamesDecl hqLength printNamesWithHistory
  docs <- for docTermsWithNames (renderDoc' ppe runtime codebase)
  liftIO $ traverse_ (renderDocToHtmlFile docNamesByRef directory) docs
  where
    renderDoc' ppe runtime codebase (docReferent, name) = do
      let docReference = Referent.toReference docReferent
      doc <- evalDocRef runtime codebase docReference <&> Doc.renderDoc ppe
      let hash = Reference.toText docReference
      pure (name, hash, doc)

    cleanPath :: FilePath -> FilePath
    cleanPath filePath =
      filePath <&> \case
        '#' -> '@'
        c -> c

    docFilePath :: FilePath -> Name -> FilePath
    docFilePath destination docFQN =
      let (dir, fileName) =
            case unsnoc . map NameSegment.toString . toList . Name.segments $ docFQN of
              Just (path, leafName) ->
                (directoryPath path, docFileName leafName)
              Nothing ->
                error "Could not parse doc name"

          directoryPath p =
            destination </> joinPath p

          docFileName n =
            cleanPath $ n <> ".html"
       in dir </> fileName

    renderDocToHtmlFile :: Map Referent Name -> FilePath -> (Name, UnisonHash, Doc.Doc) -> IO ()
    renderDocToHtmlFile docNamesByRef destination (docName, _, doc) = do
      let fullPath =
            docFilePath destination docName

          directoryPath =
            takeDirectory fullPath

          (DocHtml.FrontMatterData frontmatter, html) =
            DocHtml.toHtml docNamesByRef doc

          go [v] = Yaml.String v
          go vs = Yaml.array $ map Yaml.String vs

          frontMatterToYaml fm =
            fmap go fm

          frontmatterTxt =
            if Map.null frontmatter
              then ""
              else "---\n" <> TextE.decodeUtf8 (Yaml.encode $ frontMatterToYaml frontmatter) <> "---\n"

          htmlAsText =
            Lucid.renderText html

          fileContents =
            frontmatterTxt <> toStrict htmlAsText
       in do
            -- Ensure all directories exists
            _ <- createDirectoryIfMissing True directoryPath
            writeFile fullPath (Text.unpack fileContents)

bestNameForTerm ::
  forall v. (Var v) => PPE.PrettyPrintEnv -> Width -> Referent -> Text
bestNameForTerm ppe width =
  Text.pack
    . Pretty.render width
    . fmap UST.toPlain
    . TermPrinter.runPretty ppe
    . TermPrinter.pretty0 @v TermPrinter.emptyAc
    . Term.fromReferent mempty

bestNameForType ::
  forall v. (Var v) => PPE.PrettyPrintEnv -> Width -> Reference -> Text
bestNameForType ppe width =
  Text.pack
    . Pretty.render width
    . fmap UST.toPlain
    . TypePrinter.prettySyntax @v ppe
    . Type.ref ()

-- | Returns (parse, pretty, local, ppe) where:
--
-- - 'parse' includes ALL fully qualified names from the root, and ALSO all names from within the provided path, relative to that path.
-- - 'pretty' includes names within the provided path, relative to that path, and also all globally scoped names _outside_ of the path
-- - 'local' includes ONLY the names within the provided path
-- - 'ppe' is a ppe which searches for a name within the path first, but falls back to a global name search.
--     The 'suffixified' component of this ppe will search for the shortest unambiguous suffix within the scope in which the name is found (local, falling back to global)
scopedNamesForBranchHash ::
  forall m n v a.
  (MonadIO m) =>
  Codebase m v a ->
  Maybe (V2Branch.CausalBranch n) ->
  Path ->
  Backend m (Names, PPED.PrettyPrintEnvDecl)
scopedNamesForBranchHash codebase mbh path = do
  shouldUseNamesIndex <- asks useNamesIndex
  (rootBranchHash, rootCausalHash) <- case mbh of
    Just cb -> pure (V2Causal.valueHash cb, V2Causal.causalHash cb)
    Nothing -> lift $ do
      cb <- Codebase.runTransaction codebase Operations.expectRootCausal
      pure (V2Causal.valueHash cb, V2Causal.causalHash cb)
  haveNameLookupForRoot <- lift $ Codebase.runTransaction codebase (Ops.checkBranchHashNameLookupExists rootBranchHash)
  hashLen <- lift $ Codebase.runTransaction codebase Codebase.hashLength
  (parseNames, localNames) <-
    if shouldUseNamesIndex
      then do
        when (not haveNameLookupForRoot) . throwError $ ExpectedNameLookup rootBranchHash
        lift . Codebase.runTransaction codebase $ indexNames rootBranchHash
      else do
        (parseNames, _pretty, localNames) <- flip namesForBranch (AllNames path) <$> resolveCausalHash (Just rootCausalHash) codebase
        pure (parseNames, localNames)

  let localPPE = PPED.fromNamesDecl hashLen (NamesWithHistory.fromCurrentNames localNames)
  let globalPPE = PPED.fromNamesDecl hashLen (NamesWithHistory.fromCurrentNames parseNames)
  pure (localNames, mkPPE localPPE globalPPE)
  where
    mkPPE :: PPED.PrettyPrintEnvDecl -> PPED.PrettyPrintEnvDecl -> PPED.PrettyPrintEnvDecl
    mkPPE primary addFallback =
      PPED.PrettyPrintEnvDecl
        (PPED.unsuffixifiedPPE primary `PPE.addFallback` PPED.unsuffixifiedPPE addFallback)
        (PPED.suffixifiedPPE primary `PPE.addFallback` PPED.suffixifiedPPE addFallback)
    indexNames :: BranchHash -> Sqlite.Transaction (Names, Names)
    indexNames bh = do
      scopedNames <- Codebase.namesAtPath bh path
      pure (ScopedNames.parseNames scopedNames, ScopedNames.namesAtPath scopedNames)

resolveCausalHash ::
  (Monad m) => Maybe CausalHash -> Codebase m v a -> Backend m (Branch m)
resolveCausalHash h codebase = case h of
  Nothing -> lift (Codebase.getRootBranch codebase)
  Just bhash -> do
    mayBranch <- lift $ Codebase.getBranchForHash codebase bhash
    whenNothing mayBranch (throwError $ NoBranchForHash bhash)

resolveCausalHashV2 :: Maybe CausalHash -> Sqlite.Transaction (V2Branch.CausalBranch Sqlite.Transaction)
resolveCausalHashV2 h = case h of
  Nothing -> Codebase.getShallowRootCausal
  Just ch -> Codebase.expectCausalBranchByCausalHash ch

resolveRootBranchHash ::
  (MonadIO m) => Maybe ShortCausalHash -> Codebase m v a -> Backend m (Branch m)
resolveRootBranchHash mayRoot codebase = case mayRoot of
  Nothing ->
    lift (Codebase.getRootBranch codebase)
  Just sch -> do
    h <- hoistBackend (Codebase.runTransaction codebase) (expandShortCausalHash sch)
    resolveCausalHash (Just h) codebase

resolveRootBranchHashV2 ::
  Maybe ShortCausalHash -> Backend Sqlite.Transaction (V2Branch.CausalBranch Sqlite.Transaction)
resolveRootBranchHashV2 mayRoot = case mayRoot of
  Nothing -> lift Codebase.getShallowRootCausal
  Just sch -> do
    h <- expandShortCausalHash sch
    lift (resolveCausalHashV2 (Just h))

normaliseRootCausalHash :: Maybe (Either ShortCausalHash CausalHash) -> Backend Sqlite.Transaction (V2Branch.CausalBranch Sqlite.Transaction)
normaliseRootCausalHash mayCh = case mayCh of
  Nothing -> lift $ resolveCausalHashV2 Nothing
  Just (Left sch) -> do
    ch <- expandShortCausalHash sch
    lift $ resolveCausalHashV2 (Just ch)
  Just (Right ch) -> lift $ resolveCausalHashV2 (Just ch)

-- | Determines whether we include full cycles in the results, (e.g. if I search for `isEven`, will I find `isOdd` too?)
--
-- This was once used for both term and decl components, but now is only used for decl components, because 'update' does
-- The Right Thing for terms (i.e. propagates changes to all dependents, including component-mates, which are de facto
-- dependents).
--
-- Ticket of interest: https://github.com/unisonweb/unison/issues/3445
data IncludeCycles
  = IncludeCycles
  | DontIncludeCycles

definitionsBySuffixes ::
  Codebase m Symbol Ann ->
  NameSearch Sqlite.Transaction ->
  IncludeCycles ->
  [HQ.HashQualified Name] ->
  Sqlite.Transaction DefinitionResults
definitionsBySuffixes codebase nameSearch includeCycles query = do
  QueryResult misses results <- hqNameQuery codebase nameSearch query
  -- todo: remember to replace this with getting components directly,
  -- and maybe even remove getComponentLength from Codebase interface altogether
  terms <- Map.foldMapM (\ref -> (ref,) <$> displayTerm codebase ref) (searchResultsToTermRefs results)
  types <- do
    let typeRefsWithoutCycles = searchResultsToTypeRefs results
    typeRefs <- case includeCycles of
      IncludeCycles ->
        Monoid.foldMapM
          Codebase.componentReferencesForReference
          typeRefsWithoutCycles
      DontIncludeCycles -> pure typeRefsWithoutCycles
    Map.foldMapM (\ref -> (ref,) <$> displayType codebase ref) typeRefs
  pure (DefinitionResults terms types misses)
  where
    searchResultsToTermRefs :: [SR.SearchResult] -> Set Reference
    searchResultsToTermRefs results =
      Set.fromList [r | SR.Tm' _ (Referent.Ref r) _ <- results]
    searchResultsToTypeRefs :: [SR.SearchResult] -> Set Reference
    searchResultsToTypeRefs results =
      Set.fromList (mapMaybe f results)
      where
        f :: SR.SearchResult -> Maybe Reference
        f = \case
          SR.Tm' _ (Referent.Con r _) _ -> Just (r ^. ConstructorReference.reference_)
          SR.Tp' _ r _ -> Just r
          _ -> Nothing

displayTerm :: Codebase m Symbol Ann -> Reference -> Sqlite.Transaction (DisplayObject (Type Symbol Ann) (Term Symbol Ann))
displayTerm codebase = \case
  ref@(Reference.Builtin _) -> do
    pure case Map.lookup ref B.termRefTypes of
      -- This would be better as a `MissingBuiltin` constructor; `MissingObject` is kind of being
      -- misused here. Is `MissingObject` even possible anymore?
      Nothing -> MissingObject $ Reference.toShortHash ref
      Just typ -> BuiltinObject (mempty <$ typ)
  Reference.DerivedId rid -> do
    (term, ty) <- Codebase.unsafeGetTermWithType codebase rid
    pure case term of
      Term.Ann' _ _ -> UserObject term
      -- manually annotate if necessary
      _ -> UserObject (Term.ann (ABT.annotation term) term ty)

displayType :: Codebase m Symbol Ann -> Reference -> Sqlite.Transaction (DisplayObject () (DD.Decl Symbol Ann))
displayType codebase = \case
  Reference.Builtin _ -> pure (BuiltinObject ())
  Reference.DerivedId rid -> do
    decl <- Codebase.unsafeGetTypeDeclaration codebase rid
    pure (UserObject decl)

termsToSyntax ::
  (Var v) =>
  (Ord a) =>
  Suffixify ->
  Width ->
  PPED.PrettyPrintEnvDecl ->
  Map Reference.Reference (DisplayObject (Type v a) (Term v a)) ->
  Map Reference.Reference (DisplayObject SyntaxText SyntaxText)
termsToSyntax suff width ppe0 terms =
  Map.fromList . map go . Map.toList $
    Map.mapKeys
      (first (PPE.termName ppeDecl . Referent.Ref) . dupe)
      terms
  where
    ppeBody r =
      if suffixified suff
        then PPED.suffixifiedPPE ppe0
        else PPE.declarationPPE ppe0 r
    ppeDecl =
      (if suffixified suff then PPED.suffixifiedPPE else PPED.unsuffixifiedPPE) ppe0
    go ((n, r), dt) = (r,) $ case dt of
      DisplayObject.BuiltinObject typ ->
        DisplayObject.BuiltinObject $
          formatType' (ppeBody r) width typ
      DisplayObject.MissingObject sh -> DisplayObject.MissingObject sh
      DisplayObject.UserObject tm ->
        DisplayObject.UserObject
          . Pretty.render width
          $ TermPrinter.prettyBinding (ppeBody r) n tm

typesToSyntax ::
  (Var v) =>
  (Ord a) =>
  Suffixify ->
  Width ->
  PPED.PrettyPrintEnvDecl ->
  Map Reference.Reference (DisplayObject () (DD.Decl v a)) ->
  Map Reference.Reference (DisplayObject SyntaxText SyntaxText)
typesToSyntax suff width ppe0 types =
  Map.fromList $
    map go . Map.toList $
      Map.mapKeys
        (first (PPE.typeName ppeDecl) . dupe)
        types
  where
    ppeDecl =
      if suffixified suff
        then PPED.suffixifiedPPE ppe0
        else PPED.unsuffixifiedPPE ppe0
    go ((n, r), dt) = (r,) $ case dt of
      BuiltinObject _ -> BuiltinObject (formatTypeName' ppeDecl r)
      MissingObject sh -> MissingObject sh
      UserObject d ->
        UserObject . Pretty.render width $
          DeclPrinter.prettyDecl (PPE.declarationPPEDecl ppe0 r) r n d

-- | Renders a type to its decl header, e.g.
--
-- Effect:
--
-- unique ability Stream s
--
-- Data:
--
-- structural type Maybe a
typeToSyntaxHeader ::
  Width ->
  HQ.HashQualified Name ->
  DisplayObject () (DD.Decl Symbol Ann) ->
  DisplayObject SyntaxText SyntaxText
typeToSyntaxHeader width hqName obj =
  case obj of
    BuiltinObject _ ->
      let syntaxName = Pretty.renderUnbroken . NP.styleHashQualified id $ hqName
       in BuiltinObject syntaxName
    MissingObject sh -> MissingObject sh
    UserObject d ->
      UserObject . Pretty.render width $
        DeclPrinter.prettyDeclHeader hqName d

loadSearchResults ::
  Codebase m Symbol Ann ->
  [SR.SearchResult] ->
  Sqlite.Transaction [SR'.SearchResult' Symbol Ann]
loadSearchResults c = traverse loadSearchResult
  where
    loadSearchResult = \case
      SR.Tm (SR.TermResult name r aliases) -> do
        typ <- loadReferentType c r
        pure $ SR'.Tm name typ r aliases
      SR.Tp (SR.TypeResult name r aliases) -> do
        dt <- loadTypeDisplayObject c r
        pure $ SR'.Tp name dt r aliases

loadTypeDisplayObject ::
  Codebase m v Ann ->
  Reference ->
  Sqlite.Transaction (DisplayObject () (DD.Decl v Ann))
loadTypeDisplayObject c = \case
  Reference.Builtin _ -> pure (BuiltinObject ())
  Reference.DerivedId id ->
    maybe (MissingObject $ Reference.idToShortHash id) UserObject
      <$> Codebase.getTypeDeclaration c id

-- | Get the causal hash a given project branch points to
causalHashForProjectBranchName :: MonadIO m => ProjectAndBranch ProjectName ProjectBranchName -> Sqlite.Transaction (Maybe CausalHash)
causalHashForProjectBranchName (ProjectAndBranch projectName branchName) = do
  Q.loadProjectBranchByNames projectName branchName >>= \case
    Nothing -> pure Nothing
    Just ProjectBranch {projectId, branchId} -> do
      let path = ProjectUtils.projectBranchPath (ProjectAndBranch projectId branchId)
      -- Use the default codebase root
      let codebaseRoot = Nothing
      mayCausal <- UCodebase.getShallowCausalFromRoot codebaseRoot (Path.unabsolute path)
      pure . Just $ V2Causal.causalHash mayCausal
