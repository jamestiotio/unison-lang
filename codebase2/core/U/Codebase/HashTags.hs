module U.Codebase.HashTags where

import Unison.Hash (Hash)

-- | Represents a hash of a type or term component
newtype ComponentHash = ComponentHash {unComponentHash :: Hash}
  deriving stock (Eq, Ord, Show)

newtype BranchHash = BranchHash {unBranchHash :: Hash} deriving (Eq, Ord)

-- | Represents a hash of a causal containing values of the provided type.
newtype CausalHash = CausalHash {unCausalHash :: Hash} deriving (Eq, Ord)

newtype PatchHash = PatchHash {unPatchHash :: Hash} deriving (Eq, Ord)

instance Show BranchHash where
  show h = "BranchHash (" ++ show (unBranchHash h) ++ ")"

instance Show CausalHash where
  show h = "CausalHash (" ++ show (unCausalHash h) ++ ")"

instance Show PatchHash where
  show h = "PatchHash (" ++ show (unPatchHash h) ++ ")"
