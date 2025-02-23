module U.Codebase.Sqlite.HashHandle
  ( HashHandle (..),
  )
where

import U.Codebase.Branch.Type (Branch)
import U.Codebase.HashTags
import U.Codebase.Reference qualified as C
import U.Codebase.Sqlite.Branch.Format (HashBranchLocalIds)
import U.Codebase.Sqlite.Branch.Full (LocalBranch)
import U.Codebase.Sqlite.Symbol (Symbol)
import U.Codebase.Term qualified as C.Term
import U.Codebase.Type qualified as C.Type
import Unison.Hash (Hash)
import Unison.Prelude

data HashHandle = HashHandle
  { -- | Hash type
    toReference :: C.Term.Type Symbol -> C.Reference,
    -- | Hash type's mentions
    toReferenceMentions :: C.Term.Type Symbol -> Set C.Reference,
    -- | Hash the type of a single constructor in a decl component. The provided hash argument is the hash of the decl component.
    toReferenceDecl :: Hash -> C.Type.TypeD Symbol -> C.Reference,
    -- | Hash decl's mentions
    toReferenceDeclMentions :: Hash -> C.Type.TypeD Symbol -> Set C.Reference,
    hashBranch :: forall m. Monad m => Branch m -> m BranchHash,
    hashCausal ::
      -- The causal's namespace hash
      BranchHash ->
      -- The causal's parents
      Set CausalHash ->
      CausalHash,
    hashBranchFormatFull ::
      HashBranchLocalIds ->
      LocalBranch ->
      BranchHash
  }
