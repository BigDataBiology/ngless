{- Copyright 2013-2015 NGLess Authors
 - License: MIT
 -}

{-# LANGUAGE OverloadedStrings #-}

module Interpretation.Write
    ( executeWrite
    , _formatFQOname
    ) where


import Control.Monad
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import System.Process
import System.Exit
import System.IO
import Data.String.Utils
import Data.List (isInfixOf)
import Data.Maybe

import Language
import Configuration
import NGLess
import Output
import Data.AnnotRes
import Utils.Utils (readPossiblyCompressedFile)

removeEnd :: String -> String -> String
removeEnd base suffix = take (length base - length suffix) base

_formatFQOname :: FilePath -> FilePath -> FilePath
_formatFQOname base insert
    | base `isInfixOf` "{index}" = replace base "{index}" ("." ++ insert ++ ".")
    | endswith ".fq" base = (removeEnd base ".fq") ++ "." ++ insert ++ ".fq"
    | endswith ".fq.gz" base = (removeEnd base ".fq") ++ "." ++ insert ++ ".fq.gz"
    | otherwise = error ("Cannot handle " ++ base)

getNGOPath :: (Maybe NGLessObject) -> FilePath
getNGOPath (Just (NGOFilename p)) = p
getNGOPath (Just (NGOString p)) = T.unpack p
getNGOPath _ = error "getNGOPath cannot decode file path"

writeToUncFile :: NGLessObject -> FilePath -> IO NGLessObject
writeToUncFile (NGOMappedReadSet path defGen) newfp = do
    readPossiblyCompressedFile path >>= BL.writeFile newfp
    return $ NGOMappedReadSet newfp defGen

writeToUncFile (NGOReadSet1 enc path) newfp = do
    readPossiblyCompressedFile path >>= BL.writeFile newfp
    return $ NGOReadSet1 enc newfp

writeToUncFile obj _ = error ("writeToUncFile: Should have received a NGOReadSet or a NGOMappedReadSet but the type was: " ++ show obj)


executeWrite :: NGLessObject -> [(T.Text, NGLessObject)] -> NGLessIO NGLessObject
executeWrite (NGOList el) args = do
    let args' = filter (\(a,_) -> (a /= "ofile")) args
        templateFP = getNGOPath $ lookup "ofile" args
        fps = map ((\fname -> replace "{index}" fname templateFP) . show) [1..length el]
    res <- zipWithM (\e fp -> executeWrite e (("ofile", NGOFilename fp):args')) el fps
    return (NGOList res)

executeWrite el@NGOReadSet1{} args = liftIO $
    writeToUncFile el (getNGOPath (lookup "ofile" args))
executeWrite (NGOReadSet2 enc r1 r2) args = do
    let newfp = getNGOPath (lookup "ofile" args)
    liftIO $ do
        NGOReadSet1 _ r1' <- writeToUncFile (NGOReadSet1 enc r1) (_formatFQOname newfp "pair.1")
        NGOReadSet1 _ r2' <- writeToUncFile (NGOReadSet1 enc r2) (_formatFQOname newfp "pair.2")
        return (NGOReadSet2 enc r1' r2')

executeWrite (NGOReadSet3 enc r1 r2 r3) args = do
    let newfp = getNGOPath (lookup "ofile" args)
    liftIO $ do
        NGOReadSet1 _ r1' <- writeToUncFile (NGOReadSet1 enc r1) (_formatFQOname newfp "pair.1")
        NGOReadSet1 _ r2' <- writeToUncFile (NGOReadSet1 enc r2) (_formatFQOname newfp "pair.2")
        NGOReadSet1 _ r3' <- writeToUncFile (NGOReadSet1 enc r3) (_formatFQOname newfp "singles")
        return (NGOReadSet3 enc r1' r2' r3')

executeWrite el@(NGOMappedReadSet fp defGen) args = do
    let newfp = getNGOPath (lookup "ofile" args) --
        format = fromMaybe (NGOSymbol "sam") (lookup "format" args)
    case format of
        NGOSymbol "sam" -> liftIO $ writeToUncFile el newfp
        NGOSymbol "bam" -> do
                        newfp' <- convertSamToBam fp newfp
                        return (NGOMappedReadSet newfp' defGen) --newfp will contain the bam
        _ -> error "This format should have been impossible"

executeWrite (NGOAnnotatedSet fp) args = do
    let newfp = getNGOPath $ lookup "ofile" args
        del = getDelimiter $ lookup "format" args
    outputListLno' InfoOutput ["Writing AnnotatedSet to: ", newfp]
    cont <- liftIO $ readPossiblyCompressedFile fp
    let NGOBool verbose = fromMaybe (NGOBool False) (lookup "verbose" args)
        cont' = if verbose
                    then showGffCountDel del . readAnnotCounts $ cont
                    else showUniqIdCounts del cont
    liftIO $ BL.writeFile newfp cont'
    return $ NGOAnnotatedSet newfp

executeWrite v _ = error ("Error: executeWrite of " ++ show v ++ " not implemented yet.")

getDelimiter :: Maybe NGLessObject -> B.ByteString
getDelimiter (Just (NGOSymbol "csv")) = ","
getDelimiter (Just (NGOSymbol "tsv")) = "\t"
getDelimiter Nothing = "\t"
getDelimiter (Just v) =  error ("Type of 'format' in 'write' must be NGOSymbol, got " ++ show v)

convertSamToBam samfile newfp = do
    outputListLno' DebugOutput ["SAM->BAM Conversion start ('", samfile, "' -> '", newfp, "')"]
    samPath <- samtoolsBin
    (errmsg, exitCode) <- liftIO $ withFile newfp WriteMode $ \hout -> do
            (_, _, Just herr, jHandle) <- createProcess (
                proc samPath
                    ["view", "-bS", samfile]
                ){ std_out = UseHandle hout,
                   std_err = CreatePipe }
            errmsg' <- hGetContents herr
            exitCode' <- waitForProcess jHandle
            return (errmsg', exitCode')
    outputListLno' InfoOutput ["Message from samtools: ", errmsg]
    case exitCode of
       ExitSuccess -> return newfp
       ExitFailure err -> error ("Failure on converting sam to bam" ++ show err)
