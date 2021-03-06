{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE StandaloneDeriving #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.Types
-- Copyright   :  (c) David Himmelstrup 2005
--                    Duncan Coutts 2011
-- License     :  BSD-like
--
-- Maintainer  :  cabal-devel@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Various common data types for the entire cabal-install system
-----------------------------------------------------------------------------
module Distribution.Client.Types where

import Distribution.Package
         ( PackageName, PackageId, Package(..), ComponentId(..)
         , ComponentId(..)
         , HasComponentId(..), PackageInstalled(..) )
import Distribution.InstalledPackageInfo
         ( InstalledPackageInfo )
import Distribution.PackageDescription
         ( Benchmark(..), GenericPackageDescription(..), FlagAssignment
         , TestSuite(..) )
import Distribution.PackageDescription.Configuration
         ( mapTreeData )
import Distribution.Client.PackageIndex
         ( PackageIndex )
import Distribution.Client.ComponentDeps
         ( ComponentDeps )
import qualified Distribution.Client.ComponentDeps as CD
import Distribution.Version
         ( VersionRange )
import Distribution.Text (display)

import Data.Map (Map)
import Network.URI (URI, nullURI)
import Data.ByteString.Lazy (ByteString)
import Control.Exception
         ( SomeException )

newtype Username = Username { unUsername :: String }
newtype Password = Password { unPassword :: String }

-- | This is the information we get from a @00-index.tar.gz@ hackage index.
--
data SourcePackageDb = SourcePackageDb {
  packageIndex       :: PackageIndex SourcePackage,
  packagePreferences :: Map PackageName VersionRange
}

-- ------------------------------------------------------------
-- * Various kinds of information about packages
-- ------------------------------------------------------------

-- | Subclass of packages that have specific versioned dependencies.
--
-- So for example a not-yet-configured package has dependencies on version
-- ranges, not specific versions. A configured or an already installed package
-- depends on exact versions. Some operations or data structures (like
--  dependency graphs) only make sense on this subclass of package types.
--
class Package pkg => PackageFixedDeps pkg where
  depends :: pkg -> ComponentDeps [ComponentId]

instance PackageFixedDeps InstalledPackageInfo where
  depends = CD.fromInstalled . installedDepends


-- | In order to reuse the implementation of PackageIndex which relies on
-- 'ComponentId', we need to be able to synthesize these IDs prior
-- to installation.  Eventually, we'll move to a representation of
-- 'ComponentId' which can be properly computed before compilation
-- (of course, it's a bit of a misnomer since the packages are not actually
-- installed yet.)  In any case, we'll synthesize temporary installed package
-- IDs to use as keys during install planning.  These should never be written
-- out!  Additionally, they need to be guaranteed unique within the install
-- plan.
fakeComponentId :: PackageId -> ComponentId
fakeComponentId = ComponentId . (".fake."++) . display

-- | A 'ConfiguredPackage' is a not-yet-installed package along with the
-- total configuration information. The configuration information is total in
-- the sense that it provides all the configuration information and so the
-- final configure process will be independent of the environment.
--
data ConfiguredPackage = ConfiguredPackage
       SourcePackage       -- package info, including repo
       FlagAssignment      -- complete flag assignment for the package
       [OptionalStanza]    -- list of enabled optional stanzas for the package
       (ComponentDeps [ConfiguredId])
                           -- set of exact dependencies (installed or source).
                           -- These must be consistent with the 'buildDepends'
                           -- in the 'PackageDescription' that you'd get by
                           -- applying the flag assignment and optional stanzas.
  deriving Show

-- | A ConfiguredId is a package ID for a configured package.
--
-- Once we configure a source package we know it's ComponentId
-- (at least, in principle, even if we have to fake it currently). It is still
-- however useful in lots of places to also know the source ID for the package.
-- We therefore bundle the two.
--
-- An already installed package of course is also "configured" (all it's
-- configuration parameters and dependencies have been specified).
--
-- TODO: I wonder if it would make sense to promote this datatype to Cabal
-- and use it consistently instead of ComponentIds?
data ConfiguredId = ConfiguredId {
    confSrcId  :: PackageId
  , confInstId :: ComponentId
  }

instance Show ConfiguredId where
  show = show . confSrcId

instance Package ConfiguredPackage where
  packageId (ConfiguredPackage pkg _ _ _) = packageId pkg

instance PackageFixedDeps ConfiguredPackage where
  depends (ConfiguredPackage _ _ _ deps) = fmap (map confInstId) deps

instance HasComponentId ConfiguredPackage where
  installedComponentId = fakeComponentId . packageId

-- | Like 'ConfiguredPackage', but with all dependencies guaranteed to be
-- installed already, hence itself ready to be installed.
data GenericReadyPackage srcpkg ipkg
   = ReadyPackage
       srcpkg                  -- see 'ConfiguredPackage'.
       (ComponentDeps [ipkg])  -- Installed dependencies.
  deriving (Eq, Show)

type ReadyPackage = GenericReadyPackage ConfiguredPackage InstalledPackageInfo

instance Package srcpkg => Package (GenericReadyPackage srcpkg ipkg) where
  packageId (ReadyPackage srcpkg _deps) = packageId srcpkg

instance (Package srcpkg, HasComponentId ipkg) =>
         PackageFixedDeps (GenericReadyPackage srcpkg ipkg) where
  depends (ReadyPackage _ deps) = fmap (map installedComponentId) deps

instance HasComponentId srcpkg =>
         HasComponentId (GenericReadyPackage srcpkg ipkg) where
  installedComponentId (ReadyPackage pkg _) = installedComponentId pkg


-- | A package description along with the location of the package sources.
--
data SourcePackage = SourcePackage {
    packageInfoId        :: PackageId,
    packageDescription   :: GenericPackageDescription,
    packageSource        :: PackageLocation (Maybe FilePath),
    packageDescrOverride :: PackageDescriptionOverride
  }
  deriving Show

-- | We sometimes need to override the .cabal file in the tarball with
-- the newer one from the package index.
type PackageDescriptionOverride = Maybe ByteString

instance Package SourcePackage where packageId = packageInfoId

data OptionalStanza
    = TestStanzas
    | BenchStanzas
  deriving (Eq, Ord, Show)

enableStanzas
    :: [OptionalStanza]
    -> GenericPackageDescription
    -> GenericPackageDescription
enableStanzas stanzas gpkg = gpkg
    { condBenchmarks = flagBenchmarks $ condBenchmarks gpkg
    , condTestSuites = flagTests $ condTestSuites gpkg
    }
  where
    enableTest t = t { testEnabled = TestStanzas `elem` stanzas }
    enableBenchmark bm = bm { benchmarkEnabled = BenchStanzas `elem` stanzas }
    flagBenchmarks = map (\(n, bm) -> (n, mapTreeData enableBenchmark bm))
    flagTests = map (\(n, t) -> (n, mapTreeData enableTest t))

-- ------------------------------------------------------------
-- * Package locations and repositories
-- ------------------------------------------------------------

data PackageLocation local =

    -- | An unpacked package in the given dir, or current dir
    LocalUnpackedPackage FilePath

    -- | A package as a tarball that's available as a local tarball
  | LocalTarballPackage FilePath

    -- | A package as a tarball from a remote URI
  | RemoteTarballPackage URI local

    -- | A package available as a tarball from a repository.
    --
    -- It may be from a local repository or from a remote repository, with a
    -- locally cached copy. ie a package available from hackage
  | RepoTarballPackage Repo PackageId local

--TODO:
--  * add support for darcs and other SCM style remote repos with a local cache
--  | ScmPackage
  deriving (Show, Functor)

data RemoteRepo =
    RemoteRepo {
      remoteRepoName     :: String,
      remoteRepoURI      :: URI,

      -- | Enable secure access to Hackage?
      remoteRepoSecure :: Bool,

      -- | Root key IDs (for bootstrapping)
      remoteRepoRootKeys :: [String],

      -- | Threshold for verification during bootstrapping
      remoteRepoKeyThreshold :: Int,

      -- | Normally a repo just specifies an HTTP or HTTPS URI, but as a
      -- special case we may know a repo supports both and want to try HTTPS
      -- if we can, but still allow falling back to HTTP.
      --
      -- This field is not currently stored in the config file, but is filled
      -- in automagically for known repos.
      remoteRepoShouldTryHttps :: Bool
    }

  deriving (Show,Eq,Ord)

-- | Construct a partial 'RemoteRepo' value to fold the field parser list over.
emptyRemoteRepo :: String -> RemoteRepo
emptyRemoteRepo name = RemoteRepo name nullURI False [] 0 False

data Repo =
    -- | Local repositories
    RepoLocal {
        repoLocalDir :: FilePath
      }

    -- | Standard (unsecured) remote repositores
  | RepoRemote {
        repoRemote   :: RemoteRepo
      , repoLocalDir :: FilePath
      }

deriving instance Show Repo

-- | Check if this is a remote repo
maybeRepoRemote :: Repo -> Maybe RemoteRepo
maybeRepoRemote (RepoLocal    _localDir  ) = Nothing
maybeRepoRemote (RepoRemote r _localDir  ) = Just r

-- ------------------------------------------------------------
-- * Build results
-- ------------------------------------------------------------

type BuildResult  = Either BuildFailure BuildSuccess
data BuildFailure = PlanningFailed
                  | DependentFailed PackageId
                  | DownloadFailed  SomeException
                  | UnpackFailed    SomeException
                  | ConfigureFailed SomeException
                  | BuildFailed     SomeException
                  | TestsFailed     SomeException
                  | InstallFailed   SomeException
data BuildSuccess = BuildOk         DocsResult TestsResult
                                    (Maybe InstalledPackageInfo)

data DocsResult  = DocsNotTried  | DocsFailed  | DocsOk
data TestsResult = TestsNotTried | TestsOk
