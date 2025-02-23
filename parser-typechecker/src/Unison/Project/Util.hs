module Unison.Project.Util
  ( projectPath,
    projectBranchesPath,
    projectBranchPath,
    projectBranchSegment,
    projectPathPrism,
    projectBranchPathPrism,
  )
where

import Control.Lens
import Data.Text qualified as Text
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import U.Codebase.Sqlite.DbId (ProjectBranchId (..), ProjectId (..))
import Unison.Codebase.Path qualified as Path
import Unison.NameSegment (NameSegment (..))
import Unison.Project (ProjectAndBranch (..))

-- | Get the path that a project is stored at. Users aren't supposed to go here.
--
-- >>> projectPath "ABCD"
-- .__projects._ABCD
projectPath :: ProjectId -> Path.Absolute
projectPath projectId =
  review projectPathPrism projectId

-- | Get the path that a project's branches are stored at. Users aren't supposed to go here.
--
-- >>> projectBranchesPath "ABCD"
-- .__projects._ABCD.branches
projectBranchesPath :: ProjectId -> Path.Absolute
projectBranchesPath projectId =
  snoc (projectPath projectId) "branches"

-- | Get the path that a branch is stored at. Users aren't supposed to go here.
--
-- >>> projectBranchPath ProjectAndBranch { project = "ABCD", branch = "DEFG" }
-- .__projects._ABCD.branches._DEFG
projectBranchPath :: ProjectAndBranch ProjectId ProjectBranchId -> Path.Absolute
projectBranchPath projectAndBranch =
  review projectBranchPathPrism (projectAndBranch, Path.empty)

-- | Get the name segment that a branch is stored at.
--
-- >>> projectBranchSegment "DEFG"
-- "_DEFG"
projectBranchSegment :: ProjectBranchId -> NameSegment
projectBranchSegment (ProjectBranchId branchId) =
  UUIDNameSegment branchId

pattern UUIDNameSegment :: UUID -> NameSegment
pattern UUIDNameSegment uuid <-
  NameSegment (Text.uncons -> Just ('_', UUID.fromText . Text.map (\c -> if c == '_' then '-' else c) -> Just uuid))
  where
    UUIDNameSegment uuid = NameSegment (Text.cons '_' (Text.map (\c -> if c == '-' then '_' else c) (UUID.toText uuid)))

-- | The prism between paths like
--
-- @
-- .__projects._XX_XX
-- @
--
-- and the project id
--
-- @
-- XX-XX
-- @
projectPathPrism :: Prism' Path.Absolute ProjectId
projectPathPrism =
  prism' toPath toId
  where
    toPath :: ProjectId -> Path.Absolute
    toPath projectId =
      Path.Absolute $
        Path.fromList
          [ "__projects",
            UUIDNameSegment (unProjectId projectId)
          ]

    toId :: Path.Absolute -> Maybe ProjectId
    toId path =
      case Path.toList (Path.unabsolute path) of
        ["__projects", UUIDNameSegment projectId] -> Just (ProjectId projectId)
        _ -> Nothing

-- | The prism between paths like
--
-- @
-- .__projects._XX_XX.branches._YY_YY.foo.bar
-- @
--
-- and the @(project id, branch id, path)@ triple
--
-- @
-- (XX-XX, YY-YY, foo.bar)
-- @
projectBranchPathPrism :: Prism' Path.Absolute (ProjectAndBranch ProjectId ProjectBranchId, Path.Path)
projectBranchPathPrism =
  prism' toPath toIds
  where
    toPath :: (ProjectAndBranch ProjectId ProjectBranchId, Path.Path) -> Path.Absolute
    toPath (ProjectAndBranch {project = projectId, branch = branchId}, restPath) =
      Path.Absolute $
        Path.fromList
          ( [ "__projects",
              UUIDNameSegment (unProjectId projectId),
              "branches",
              UUIDNameSegment (unProjectBranchId branchId)
            ]
              ++ Path.toList restPath
          )

    toIds :: Path.Absolute -> Maybe (ProjectAndBranch ProjectId ProjectBranchId, Path.Path)
    toIds path =
      case Path.toList (Path.unabsolute path) of
        "__projects" : UUIDNameSegment projectId : "branches" : UUIDNameSegment branchId : restPath ->
          Just (ProjectAndBranch {project = ProjectId projectId, branch = ProjectBranchId branchId}, Path.fromList restPath)
        _ -> Nothing
