{-# LANGUAGE ScopedTypeVariables, CPP #-}

#include <ghcplatform.h>

-- | Compiler utility functions, mainly dealing with IO and files
module Compiler.Utils
    (
      -- * File utils
      touchFile
    , copyNoOverwrite
    , findFile
    , jsexeExtension
    , exeFileName
    , mkGhcjsSuf
    , mkGhcjsOutput
      -- * Source code and JS related utilities
    , ghcjsSrcSpan
    , isJsFile
      -- * User interaction
    , compilationProgressMsg
      -- * Environment
    , getEnvMay
    , getEnvOpt
      -- * Preprocessing for JS
    , doCpp
      -- * Error messages
    , simpleSrcErr
    ) where

import           DynFlags
import           GHC
import           Platform
import           HscTypes
import           Bag
import           Outputable
import           ErrUtils          (mkPlainErrMsg)
import           Packages          (getPackageIncludePath)
import           Config            (cProjectVersionInt)
import qualified SysTools

import           Control.Applicative
import qualified Control.Exception as Ex
import           Control.Monad
import           Control.Monad.IO.Class

import           Data.Char
import           Data.List         (isPrefixOf)

import           System.Directory  (doesFileExist, copyFile)
import           System.Environment
import           System.FilePath

import           Gen2.Utils

touchFile :: DynFlags -> FilePath -> IO ()
touchFile df file = do
  e <- doesFileExist file
  when e (SysTools.touch df "keep build system happy" file)

copyNoOverwrite :: FilePath -> FilePath -> IO ()
copyNoOverwrite from to = do
  ef <- doesFileExist from
  et <- doesFileExist to
  when (ef && not et) (copyFile from to)

findFile :: (FilePath -> FilePath)      -- Maps a directory path to a file path
         -> [FilePath]                  -- Directories to look in
         -> IO (Maybe FilePath)         -- The first file path to match
findFile _            [] = return Nothing
findFile mk_file_path (dir : dirs)
  = do let file_path = mk_file_path dir
       b <- doesFileExist file_path
       if b then return (Just file_path)
            else findFile mk_file_path dirs

jsexeExtension :: FilePath
jsexeExtension = "jsexe"

exeFileName :: DynFlags -> FilePath
exeFileName dflags
  | Just s <- outputFile dflags =
      -- unmunge the extension
      let s' = dropPrefix "js_" (drop 1 $ takeExtension s)
      in if null s'
           then dropExtension s <.> jsexeExtension
           else dropExtension s <.> s'
  | otherwise =
      if platformOS (targetPlatform dflags) == OSMinGW32
           then "main.jsexe"
           else "a.jsexe"
  where
    dropPrefix prefix xs
      | prefix `isPrefixOf` xs = drop (length prefix) xs
      | otherwise              = xs

isJsFile :: FilePath -> Bool
isJsFile = (==".js") . takeExtension

mkGhcjsOutput :: String -> String
mkGhcjsOutput "" = ""
mkGhcjsOutput file
  | ext == ".hi"     = replaceExtension file ".js_hi"
  | ext == ".o"      = replaceExtension file ".js_o"
  | ext == ".dyn_hi" = replaceExtension file ".js_dyn_hi"
  | ext == ".dyn_o"  = replaceExtension file ".js_dyn_o"
  | otherwise        = replaceExtension file (".js_" ++ drop 1 ext)
  where
    ext = takeExtension file
mkGhcjsSuf :: String -> String
mkGhcjsSuf "o"      = "js_o"
mkGhcjsSuf "hi"     = "js_hi"
mkGhcjsSuf "dyn_o"  = "js_dyn_o"
mkGhcjsSuf "dyn_hi" = "js_dyn_hi"
mkGhcjsSuf xs       = "js_" ++ xs -- is this correct?

getEnvMay :: String -> IO (Maybe String)
getEnvMay xs = fmap Just (getEnv xs)
               `Ex.catch` \(_::Ex.SomeException) -> return Nothing

getEnvOpt :: MonadIO m => String -> m Bool
getEnvOpt xs = liftIO (maybe False ((`notElem` ["0","no"]).map toLower) <$> getEnvMay xs)

doCpp :: DynFlags -> Bool -> FilePath -> FilePath -> IO ()
doCpp dflags raw input_fn output_fn = do
    let hscpp_opts = picPOpts dflags
    let cmdline_include_paths = includePaths dflags

    pkg_include_dirs <- getPackageIncludePath dflags []
    let include_paths = foldr (\ x xs -> "-I" : x : xs) []
                          (cmdline_include_paths ++ pkg_include_dirs)

    let verbFlags = getVerbFlags dflags

    let cpp_prog args | raw       = SysTools.runCpp dflags args
                      | otherwise = SysTools.runCc dflags (SysTools.Option "-E" : args)

    let target_defs =
          [ "-D" ++ HOST_OS     ++ "_BUILD_OS=1",
            "-D" ++ HOST_ARCH   ++ "_BUILD_ARCH=1",
            "-Dghcjs_HOST_OS=1",
            "-Dghcjs_HOST_ARCH=1" ]
        -- remember, in code we *compile*, the HOST is the same our TARGET,
        -- and BUILD is the same as our HOST.

    backend_defs <- getBackendDefs dflags

    cpp_prog       (   map SysTools.Option verbFlags
                    ++ map SysTools.Option include_paths
                    ++ map SysTools.Option hsSourceCppOpts
                    ++ map SysTools.Option target_defs
                    ++ map SysTools.Option backend_defs
                    ++ map SysTools.Option hscpp_opts
                    ++ [ SysTools.Option "-undef" ] -- undefine host system definitions
        -- Set the language mode to assembler-with-cpp when preprocessing. This
        -- alleviates some of the C99 macro rules relating to whitespace and the hash
        -- operator, which we tend to abuse. Clang in particular is not very happy
        -- about this.
                    ++ [ SysTools.Option     "-x"
                       , SysTools.Option     "assembler-with-cpp"
                       , SysTools.Option     input_fn
        -- We hackily use Option instead of FileOption here, so that the file
        -- name is not back-slashed on Windows.  cpp is capable of
        -- dealing with / in filenames, so it works fine.  Furthermore
        -- if we put in backslashes, cpp outputs #line directives
        -- with *double* backslashes.   And that in turn means that
        -- our error messages get double backslashes in them.
        -- In due course we should arrange that the lexer deals
        -- with these \\ escapes properly.
                       , SysTools.Option     "-o"
                       , SysTools.FileOption "" output_fn
                       ])

getBackendDefs :: DynFlags -> IO [String]
getBackendDefs dflags | hscTarget dflags == HscLlvm = do
    llvmVer <- SysTools.figureLlvmVersion dflags
    return $ case llvmVer of
               Just n -> [ "-D__GLASGOW_HASKELL_LLVM__="++show n ]
               _      -> []

getBackendDefs _ =
    return []

hsSourceCppOpts :: [String]
-- Default CPP defines in Haskell source
hsSourceCppOpts =
        [ "-D__GLASGOW_HASKELL__="++cProjectVersionInt ]

simpleSrcErr :: DynFlags -> SrcSpan -> String -> SourceError
simpleSrcErr df span msg = mkSrcErr (unitBag errMsg)
  where
    errMsg = mkPlainErrMsg df span (text msg)

