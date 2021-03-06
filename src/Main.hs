module Main (main) where
import GHC
import GHC.Paths (libdir)
import HscMain
import DynFlags hiding (flags)
import TidyPgm
import CorePrep
import CoreToStg
import StgSyn (StgBinding)
import HscTypes
import GhcMonad
import System.Environment (getArgs)
import Control.Monad (when)
import CodeGen.Javascript
import Args
import ArgSpecs
import System.FilePath (addExtension)
import System.IO
import System.Process (runProcess, waitForProcess, rawSystem)
import System.Exit (ExitCode (..))
import System.Directory (renameFile)
import Version
import Data.Version
import Data.List
import EnvUtils
import System.Posix.Env (setEnv)

logStr :: String -> IO ()
logStr = hPutStrLn stderr

rebootMsg :: String
rebootMsg = "Haste needs to be rebooted; please run haste-boot"

printInfo :: IO ()
printInfo = do
  ghc <- runGhc (Just libdir) getSessionDynFlags
  putStrLn $ formatInfo $ compilerInfo ghc
  where
    formatInfo = ('[' :) . tail . unlines . (++ ["]"]) . map ((',' :) . show)

-- | Check for arguments concerning version info and the like, and act on them.
--   Return True if the compiler should run afterwards.
preArgs :: [String] -> IO Bool
preArgs args
  | "--numeric-version" `elem` args =
    putStrLn ghcVersion >> return False
  | "--info" `elem` args =
    printInfo >> return False
  | "--version" `elem` args =
    putStrLn (showVersion hasteVersion) >> return False
  | "--supported-extensions" `elem` args =
    (putStrLn $ unlines $ supportedLanguagesAndExtensions) >> return False
  | "--supported-languages" `elem` args =
    (putStrLn $ unlines $ supportedLanguagesAndExtensions) >> return False
  | otherwise =
    return True

main :: IO ()
main = do
  setEnv "GHC_PACKAGE_PATH" pkgDir True
  args <- getArgs
  runCompiler <- preArgs args
  when (runCompiler) $ do
    if allSupported args
      then hasteMain args
      else callVanillaGHC args

-- | Call vanilla GHC; used for boot files and the like.
callVanillaGHC :: [String] -> IO ()
callVanillaGHC args = do
  _ <- rawSystem "ghc" (filter noHasteArgs args)
  return ()
  where
    noHasteArgs x =
      x /= "--libinstall" &&
      x /= "--unbooted"

-- | Run the compiler if everything's satisfactorily booted, otherwise whine
--   and exit.
hasteMain :: [String] -> IO ()
hasteMain args
  | needsReboot == Dont =
    compiler args
  | otherwise = do
    if "--unbooted" `elem` args
      then compiler (filter (/= "--unbooted") args)
      else fail rebootMsg

-- | Determine whether all given args are handled by Haste, or if we need to
--   ship them off to vanilla GHC instead.
allSupported :: [String] -> Bool
allSupported args =
  and args'
  where
    args' = [not $ any (`isSuffixOf` a) someoneElsesProblems | a <- args]
    someoneElsesProblems = [".c", ".cmm", ".hs-boot", ".lhs-boot"]

-- | The main compiler driver.
compiler :: [String] -> IO ()
compiler cmdargs = do
  let cmdargs' | "--opt-all" `elem` cmdargs = "-O2" : cmdargs
               | "--opt-all-unsafe" `elem` cmdargs = "-O2" : cmdargs
               | otherwise                  = cmdargs
      argRes = handleArgs defConfig argSpecs cmdargs'
      usedGhcMode = if "-c" `elem` cmdargs then OneShot else CompManager

  case argRes of
    -- We got --help as an argument - display help and exit.
    Left help -> putStrLn help
    
    -- We got a config and a set of arguments for GHC; let's compile!
    Right (cfg, ghcargs) -> do
      -- Parse static flags, but ignore profiling.
      (ghcargs', _) <- parseStaticFlags [noLoc a | a <- ghcargs, a /= "-prof"]
      
      defaultErrorHandler defaultLogAction $ runGhc (Just libdir) $ do
        -- Handle dynamic GHC flags.
        let ghcargs'' = "-D__HASTE__" : map unLoc ghcargs'
            args = if doTCE cfg
                     then "-D__HASTE_TCE__" : ghcargs''
                     else ghcargs''
        dynflags <- getSessionDynFlags
        (dynflags', files, _) <- parseDynamicFlags dynflags (map noLoc args)
        _ <- setSessionDynFlags dynflags' {ghcLink = NoLink,
                                           ghcMode = usedGhcMode}
        let files' = map unLoc files

        -- Prepare and compile all needed targets.
        ts <- mapM (flip guessTarget Nothing) files'
        setTargets ts
        _ <- load LoadAllTargets
        deps <- depanal [] False
        mapM_ (compile cfg dynflags') deps
        
        -- Link everything together into a .js file.
        when (performLink cfg) $ liftIO $ do
          flip mapM_ files' $ \file -> do
            logStr $ "Linking " ++ outFile cfg file
            link cfg file
            case useGoogleClosure cfg of 
              Just clopath -> closurize clopath $ outFile cfg file
              _            -> return ()

-- | Run Google Closure on a file.
closurize :: FilePath -> FilePath -> IO ()
closurize cloPath file = do
  logStr $ "Running the Google Closure compiler on " ++ file ++ "..."
  let cloFile = file `addExtension` ".clo"
  cloOut <- openFile cloFile WriteMode
  build <- runProcess "java"
             ["-jar", cloPath, "--compilation_level", "ADVANCED_OPTIMIZATIONS",
              "--jscomp_off", "uselessCode", "--jscomp_off", "globalThis",
              file]
             Nothing
             Nothing
             Nothing
             (Just cloOut)
             Nothing
  res <- waitForProcess build
  hClose cloOut
  case res of
    ExitFailure n ->
      fail $ "Couldn't execute Google Closure compiler: " ++ show n
    ExitSuccess ->
      renameFile cloFile file

-- | Compile a module into a .jsmod intermediate file.
compile :: (GhcMonad m) => Config -> DynFlags -> ModSummary -> m ()
compile cfg dynflags modSummary = do
  case ms_hsc_src modSummary of
    HsBootFile -> liftIO $ logStr $ "Skipping boot " ++ myName
    _          -> do
      (pgm, name) <- prepare dynflags modSummary
      let theCode    = generate cfg name pgm
          targetpath = (targetLibPath cfg)
      liftIO $ logStr $ "Compiling " ++ myName ++ " into " ++ targetpath
      liftIO $ writeModule targetpath theCode
  where
    myName = moduleNameString $ moduleName $ ms_mod modSummary

-- | Do everything required to get a list of STG bindings out of a module.
prepare :: (GhcMonad m) => DynFlags -> ModSummary -> m ([StgBinding], ModuleName)
prepare dynflags theMod = do
  env <- getSession
  let name = moduleName $ ms_mod theMod
  pgm <- parseModule theMod
    >>= typecheckModule
    >>= desugarModule
    >>= liftIO . hscSimplify env . coreModule
    >>= liftIO . tidyProgram env
    >>= prepPgm . fst
    >>= liftIO . coreToStg dynflags
  return (pgm, name)
  where
    prepPgm tidy = liftIO $ do
      prepd <- corePrepPgm dynflags (cg_binds tidy) (cg_tycons tidy)
      return prepd
