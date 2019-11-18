{-# LANGUAGE CPP             #-}
{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Control.Monad
import Data.List (intercalate, sort)
import Data.Maybe (mapMaybe)
import Data.Version (showVersion)
import Development.GitRev
import Options.Applicative
import Ormolu
import Ormolu.Parser (manualExts)
import Ormolu.Utils (showOutputable)
import Paths_ormolu (version)
import System.Exit (ExitCode (..), exitWith)
import System.Directory
import System.Directory.Extra
import System.IO (hPutStrLn, stderr)
import qualified Data.Text.IO as TIO

-- | Entry point of the program.

main :: IO ()
main = withPrettyOrmoluExceptions $ do
  Opts {..} <- execParser optsParserInfo
  let formatOne' = formatOne optMode optConfig
  case optInputFiles of
    [] -> formatOne' Nothing
    ["-"] -> formatOne' Nothing
    xs -> case optMode of
            InPlace -> parsePaths xs >>= mapM_ (formatOne' . Just)
            _       -> mapM_ (formatOne' . Just) xs

-- | Get .hs files recursively.

parsePaths :: [FilePath] -> IO [FilePath]
parsePaths xs = concat <$> mapM parsePath xs

parsePath :: FilePath -> IO [FilePath]
parsePath x = mapMaybe onlyHs <$> insideDir x

boolToMaybe :: (a -> Bool) -> a -> Maybe a
boolToMaybe f x | f x = Just x
                | otherwise = Nothing

-- | Returns Just FilePath if file ends on ".hs".

-- >>> onlyHs "foo.hs"
-- Just "foo.hs"
--
-- >>> onlyHs "hs"
-- Nothing
onlyHs :: FilePath -> Maybe FilePath
onlyHs = boolToMaybe (\x -> dotHs x == ".hs")
  where
    dotHs = reverse . take 3 . reverse 

-- | Recurse into dirs.

insideDir :: FilePath -> IO [FilePath]
insideDir p = do
  isDir <- doesDirectoryExist p
  if isDir then
    listFilesRecursive p
  else do
    isFile <- doesFileExist p
    if isFile then
       return [p]
    else
      return []

-- | Format a single input.

formatOne
  :: Mode                       -- ^ Mode of operation
  -> Config                     -- ^ Configuration
  -> Maybe FilePath             -- ^ File to format or stdin as 'Nothing'
  -> IO ()
formatOne mode config = \case
  Nothing -> do
    r <- ormoluStdin config
    case mode of
      Stdout -> TIO.putStr r
      _ ->  do
        hPutStrLn stderr
          "This feature is not supported when input comes from stdin."
          -- 101 is different from all the other exit codes we already use.
        exitWith (ExitFailure 101)
  Just inputFile -> do
    r <- ormoluFile config inputFile
    case mode of
      Stdout ->
        TIO.putStr r
      InPlace ->
        TIO.writeFile inputFile r
      Check -> do
        r' <- TIO.readFile inputFile
        when (r /= r') $
          -- 100 is different to all the other exit code that are emitted
          -- either from an 'OrmoluException' or from 'error' and
          -- 'notImplemented'.
          exitWith (ExitFailure 100)

----------------------------------------------------------------------------
-- Command line options parsing.

data Opts = Opts
  { optMode :: !Mode
    -- ^ Mode of operation
  , optConfig :: !Config
    -- ^ Ormolu 'Config'
  , optInputFiles :: ![FilePath]
    -- ^ Haskell source files to format or stdin (when the list is empty)
  }

-- | Mode of operation.

data Mode
  = Stdout                      -- ^ Output formatted source code to stdout
  | InPlace                     -- ^ Overwrite original file
  | Check                       -- ^ Exit with non-zero status code if
                                -- source is not already formatted
  deriving (Eq, Show)

optsParserInfo :: ParserInfo Opts
optsParserInfo = info (helper <*> ver <*> exts <*> optsParser) . mconcat $
  [ fullDesc
  , progDesc ""
  , header ""
  ]
  where
    ver :: Parser (a -> a)
    ver = infoOption verStr . mconcat $
      [ long "version"
      , short 'v'
      , help "Print version of the program"
      ]
    verStr = intercalate "\n"
      [ unwords
        [ "ormolu"
        , showVersion version
        , $gitBranch
        , $gitHash
        ]
      , "using ghc-lib-parser " ++ VERSION_ghc_lib_parser
      ]
    exts :: Parser (a -> a)
    exts = infoOption displayExts . mconcat $
      [ long "manual-exts"
      , help "Display extensions that need to be enabled manually"
      ]
    displayExts = unlines $ sort (showOutputable <$> manualExts)

optsParser :: Parser Opts
optsParser = Opts
  <$> (option parseMode . mconcat)
    [ long "mode"
    , short 'm'
    , metavar "MODE"
    , value Stdout
    , help "Mode of operation: 'stdout' (default), 'inplace', or 'check'"
    ]
  <*> configParser
  <*> (many . strArgument . mconcat)
    [ metavar "FILE"
    , help "Haskell source files to format or stdin (default)"
    ]

configParser :: Parser Config
configParser = Config
  <$> (fmap (fmap DynOption) . many . strOption . mconcat)
    [ long "ghc-opt"
    , short 'o'
    , metavar "OPT"
    , help "GHC options to enable (e.g. language extensions)"
    ]
  <*> (switch . mconcat)
    [ long "unsafe"
    , short 'u'
    , help "Do formatting faster but without automatic detection of defects"
    ]
  <*> (switch . mconcat)
    [ long "debug"
    , short 'd'
    , help "Output information useful for debugging"
    ]
  <*> (switch . mconcat)
    [ long "tolerate-cpp"
    , short 'p'
    , help "Do not fail if CPP pragma is present"
    ]
  <*> (switch . mconcat)
    [ long "check-idempotency"
    , short 'c'
    , help "Fail if formatting is not idempotent"
    ]

----------------------------------------------------------------------------
-- Helpers

-- | Parse 'Mode'.

parseMode :: ReadM Mode
parseMode = eitherReader $ \case
  "stdout" -> Right Stdout
  "inplace" -> Right InPlace
  "check" -> Right Check
  s -> Left $ "unknown mode: " ++ s
