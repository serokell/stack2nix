{-# LANGUAGE OverloadedStrings #-}
module Stack2nix.Render
   (render) where

import qualified Data.Set as Set
import           Control.Monad                           (when)
import           Data.Either                             (rights, lefts)
import           Data.List                               (sort, isPrefixOf, filter)
import           Data.Monoid                             ((<>))
import qualified Data.Set                                as S
import           Distribution.Text                       (display)
import           System.IO                               (hPutStrLn, stderr)
import           Stack2nix.Types                         (Args (..))
import           Distribution.Text                       (display)
import           Distribution.Types.PackageId            (PackageIdentifier(..), pkgName)
import           Distribution.Types.PackageName          (unPackageName)
import           Lens.Micro.Extras
import           Lens.Micro
import           Paths_stack2nix                         (version)
import           Distribution.Nixpkgs.Haskell.Derivation (Derivation, pkgid, dependencies, testDepends, benchmarkDepends, runHaddock, doCheck, pkgid)
import           Distribution.Nixpkgs.Haskell.BuildInfo  (system, haskell, pkgconfig, tool)
import           Text.PrettyPrint.HughesPJClass          (semi, nest, pPrint, fcat, punctuate, space, text, Doc, prettyShow, pPrint)
import qualified Text.PrettyPrint                        as PP
import           Language.Nix.Binding                    (Binding, reference)
import           Language.Nix                            (path)
import           Language.Nix.PrettyPrinting             (disp)


-- TODO: this only covers GHC 8.0.2
basePackages :: S.Set String
basePackages = S.fromList
  [ "array"
  , "base"
  , "binary"
  , "bytestring"
  , "Cabal"
  , "containers"
  , "deepseq"
  , "directory"
  , "filepath"
  , "ghc-boot"
  , "ghc-boot-th"
  , "ghc-prim"
  , "ghci"
  , "haskeline"
  , "hoopl"
  , "hpc"
  , "integer-gmp"
  , "pretty"
  , "process"
  , "rts"
  , "template-haskell"
  , "terminfo"
  , "time"
  , "transformers"
  , "unix"
  , "xhtml"
  ]

render :: [Either Doc Derivation] -> Args -> [String] -> String -> IO ()
render results args locals ghcnixversion = do
   let docs = lefts results
   when (length docs > 0) $ do
     hPutStrLn stderr $ show docs
     error "Error(s) happened during cabal2nix generation ^^"
   let drvs = rights results

   -- See what base packages are missing in the derivations list and null them
   let missing = sort $ S.toList $ S.difference basePackages $ S.fromList (map drvToName drvs)
   let renderedMissing = map (\b -> nest 6 (text (b <> " = null;"))) missing

   let out = defaultNix ghcnixversion $ renderedMissing ++ map (renderOne args locals) drvs

   case argOutFile args of
     Just fname -> writeFile fname out
     Nothing -> putStrLn out

renderOne :: Args -> [String] -> Derivation -> Doc
renderOne args locals drv' =
   nest 6 $ PP.hang (PP.doubleQuotes (text pid) <> " = callPackage") 2 ("(" <> pPrint drv <> ") {" <> text (show pkgs) <> "};")
     where pid = drvToName drv
           deps = view dependencies drv
           nixPkgs :: [Binding]
           nixPkgs = Set.toList $ Set.union (view pkgconfig deps) (view system deps)
           -- filter out libX stuff to prevent breakage in generated set
           nonXpkgs = filter (\e -> not ("libX" `Data.List.isPrefixOf` (display (((view (reference . path) e) !! 1))))) nixPkgs
           pkgs = fcat $ punctuate space [ disp b <> semi | b <- nonXpkgs ]
           drv = drv'
                 & doCheck .~ (argTest args && isLocal)
                 & runHaddock .~ (argHaddock args && isLocal)
                 & benchmarkDepends . haskell .~ S.empty
                 -- find a DRY way
                 & testDepends . haskell .~ (if (argTest args && isLocal) then (view (testDepends . haskell) drv') else S.empty)
                 & testDepends . pkgconfig .~ (if (argTest args && isLocal) then (view (testDepends . pkgconfig) drv') else S.empty)
                 & testDepends . system .~ (if (argTest args && isLocal) then (view (testDepends . system) drv') else S.empty)
                 & testDepends . tool .~ (if (argTest args && isLocal) then (view (testDepends . tool) drv') else S.empty)
           isLocal = elem pid locals

drvToName :: Derivation -> String
drvToName drv = unPackageName $ pkgName $ view pkgid drv

defaultNix :: String -> [Doc] -> String
defaultNix ghcnixversion drvs = unlines $
 [ "# Generated using stack2nix " <> display version <> "."
 , "#"
 , "# Only works with sufficiently recent nixpkgs, e.g. \"NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/21a8239452adae3a4717772f4e490575586b2755.tar.gz\"."
 , ""
 , "{ pkgs ? (import <nixpkgs> {})"
 , ", compiler ? pkgs.haskell.packages.ghc" ++ ghcnixversion
 , "}:"
 , ""
 , "with pkgs.haskell.lib;"
 , ""
 , "let"
 , "  stackPackages = { pkgs, stdenv, callPackage }:"
 , "    self: {"
 ] ++ (map PP.render drvs) ++
 [ "    };"
 , "in compiler.override {"
 , "  initialPackages = stackPackages;"
 , "  configurationCommon = { ... }: self: super: {};"
 , "  compilerConfig = self: super: {};"
 , "}"
 ]
