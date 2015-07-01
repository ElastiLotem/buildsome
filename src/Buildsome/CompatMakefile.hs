{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings, TupleSections #-}
module Buildsome.CompatMakefile
  ( Phonies, make
  ) where

import           Buildsome.BuildMaps (TargetRep)
import qualified Buildsome.BuildMaps as BuildMaps
import           Buildsome.Stats (Stats)
import qualified Buildsome.Stats as Stats
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Map as Map
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Lib.Directory as Directory
import           Lib.FilePath (FilePath, (</>))
import           Lib.List (partitionA)
import           Lib.Makefile (TargetType(..), Target)
import           Lib.Parsec (showPos)
import qualified Lib.Revisit as Revisit
import qualified System.Posix.ByteString as Posix

import           Prelude.Compat hiding (FilePath)

isDir :: FilePath -> IO Bool
isDir path = maybe False Posix.isDirectory <$> Directory.getMFileStatus path

type M = Revisit.M TargetRep IO

data MakefileTarget = MakefileTarget
  { makefileTargetPaths :: [FilePath]
  , makefileTargetDirs :: [FilePath]
  , isDirectory :: Bool
  }

makefileTarget :: Target -> IO MakefileTarget
makefileTarget target = do
  repIsDir <- isDir repPath
  (targetOutputDirs, targetOutputFiles) <- partitionA isDir (targetOutputs target)
  return MakefileTarget
    { makefileTargetPaths = map (</> ".dir") targetOutputDirs ++ targetOutputFiles
    , makefileTargetDirs = targetOutputDirs
    , isDirectory = repIsDir
    }
  where
    repPath = BuildMaps.targetRepPath $ BuildMaps.computeTargetRep target

targetCmdLines :: MakefileTarget -> Target -> [ByteString]
targetCmdLines tgt target =
  ["rm -rf " <> dir | dir <- makefileTargetDirs tgt] ++
  (BS8.lines . targetCmds) target ++
  (if isDirectory tgt then map ("touch " <>) (makefileTargetPaths tgt) else [])

type Phonies = Set FilePath

onOneTarget :: Phonies -> FilePath -> Stats -> Target -> M [ByteString]
onOneTarget phoniesSet cwd stats target =
  fmap (fromMaybe []) $
  Revisit.avoid targetRep $ do
    depsLines <- depBuildCommands
    tgt <- lift $ makefileTarget target
    let
      targetDecl = mconcat
        [ "T := ", spaceUnwords (makefileTargetPaths tgt)
        , "\n$(T):", spaceUnwords $ Set.toList $ Set.fromList inputs
        ]
      myLines =
        [ "#" <> BS8.pack (showPos (targetPos target)) ] ++
        [ ".PHONY: " <> t
        | t <- makefileTargetPaths tgt, t `Set.member` phoniesSet
        ] ++
        [ targetDecl ] ++
        map ("\t" <>) (targetCmdLines tgt target) ++
        [ "" ]
    return $ myLines ++ depsLines
  where
    spaceUnwords = BS8.concat . map (" " <>)
    inputs =
      fromMaybe
      (error "compat makefile requested without tsExistingInputs being calculated?!")
      $ Stats.tsExistingInputs targetStats
    targetRep = BuildMaps.computeTargetRep target
    directDeps = Stats.tsDirectDeps targetStats
    targetStats =
      fromMaybe (error "BUG: Stats does not contain targets that appear as root/dependencies") $
      Map.lookup targetRep (Stats.ofTarget stats)
    depBuildCommands = onMultipleTargets phoniesSet cwd stats directDeps

onMultipleTargets :: Phonies -> FilePath -> Stats -> [Target] -> M [ByteString]
onMultipleTargets phoniesSet cwd stats = fmap concat . mapM (onOneTarget phoniesSet cwd stats)

make :: Phonies -> FilePath -> Stats -> [Target] -> FilePath -> IO ()
make phoniesSet cwd stats rootTargets filePath = do
  putStrLn $ "Writing compat makefile to: " ++ show (cwd </> filePath)
  makefileLines <- Revisit.run (onMultipleTargets phoniesSet cwd stats rootTargets)
  BS8.writeFile (BS8.unpack filePath) $
    BS8.unlines $
    [ "# Auto-generated compatibility mode Makefile"
    , "# THIS MAKEFILE IS INVALID AS SOON AS ANY CHANGE OCCURS ANYWHERE"
    , "# ON THE FILE SYSTEM (even outside your project). USE CAREFULLY."
    , "# make -f compat-makefile"
    ] ++ makefileLines
