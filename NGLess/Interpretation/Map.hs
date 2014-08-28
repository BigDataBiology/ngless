{-# LANGUAGE OverloadedStrings #-}


module Interpretation.Map
    (
    interpretMapOp
    , configGenome
    , calcSamStats
    ) where

import qualified Codec.Archive.Tar as Tar
import qualified Codec.Compression.GZip as GZip

import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text as T
import qualified Data.Vector.Unboxed as V

import qualified Data.Map as Map

import System.Directory
import System.FilePath.Posix

import Data.Conduit
import Data.Maybe
import Data.Conduit.Binary (sinkFile)

import Network.HTTP.Conduit

import Control.Monad
import Control.Applicative ((<$>))
import Control.Monad.Error (liftIO)

import ProgressBar
import Numeric
import InvokeExternalProgs
import SamBamOperations
import Language
import FileManagement
import ReferenceDatabases
import Configuration

import Data.Sam


numDecimalPlaces :: Int
numDecimalPlaces = 2


interpretMapOp r ds = do
    (ref', defGen') <- indexReference'
    samPath' <- mapToReference (T.pack ref') (B.unpack ds)
    getSamStats samPath'
    return $ NGOMappedReadSet (T.pack samPath') defGen'
    where 
        r' = T.unpack r
        indexReference' :: IO (FilePath, Maybe T.Text)
        indexReference' = 
            case isDefaultGenome r of
                False  -> indexReference r >>= \x -> return (x, Nothing) --user supplies genome
                True   -> do 
                    rootGen <- getGenomeDir r
                    isIndexCalculated r' >>= \res -> case res of 
                        Nothing -> configGenome r' User >>= \x -> return (x, Just rootGen) -- download and install genome on User mode
                        Just p  -> return (T.unpack p , Just rootGen) -- already installed


{-
    Receives - A default genome name
    Returns  - The root dir for that genome
    
    If not installed in SU mode, return user mode path since it will be installed on User mode next.
-}
getGenomeDir :: T.Text -> IO T.Text
getGenomeDir n = T.pack <$> do
    dataDir <- globalDataDirectory
    doesExist <- doesDirectoryExist $ dataDir </> getGenomeRootPath n
    case doesExist of
        True  -> return (dataDir </> getGenomeRootPath n)
        False -> (</> getGenomeRootPath n) <$> userDataDirectory


getSamStats :: FilePath -> IO ()
getSamStats fname = unCompress fname >>= printSamStats . calcSamStats

calcSamStats contents = [total', aligned', unique', lowQual']
    where res' = samStats contents
          total' = V.unsafeIndex res' (fromEnum Total)
          aligned' = V.unsafeIndex res' (fromEnum Aligned)
          unique' = V.unsafeIndex res' (fromEnum Unique)
          lowQual' = V.unsafeIndex res' (fromEnum LowQual)

printSamStats stats = do
    putStrLn $ "Total reads: " ++ (show total)
    putStrLn $ "Total reads aligned: " ++ (show aligned) ++ "[" ++ (showFloat' $ calcDiv aligned total) ++ "%]"
    putStrLn $ "Total reads Unique map: " ++ (show unique) ++ "[" ++ (showFloat' $ calcDiv unique aligned) ++ "%]"
    putStrLn $ "Total reads Non-Unique map: " ++ (show $ aligned - unique) ++ "[" ++ (showFloat' $ 100 - (calcDiv unique aligned)) ++ "%]"
    putStrLn $ "Total reads without enough qual: " ++ (show lowQ)
  where
    total   = stats !! 0
    aligned = stats !! 1
    unique  = stats !! 2
    lowQ    = stats !! 3
    showFloat' num = showFFloat (Just numDecimalPlaces) num ""
    calcDiv :: Int -> Int -> Double
    calcDiv a b = 
          let x = fromIntegral a
              y = fromIntegral b
          in (x / y) * (100 :: Double) 
    
-- check both SU and normal user Genomes dir for <ref> 
isIndexCalculated :: FilePath -> IO (Maybe T.Text)
isIndexCalculated ref = do
    -- super user genomes dir --
    hasSUFiles <- isIndexCalcAux ref Root
    -- normal user genomes dir --
    hasFiles <- isIndexCalcAux ref User

    case isJust hasSUFiles of
        True  -> return hasSUFiles -- installed in SU dir
        False -> case isJust hasFiles of
                True  -> return hasFiles -- installed in $HOME
                False -> return Nothing -- not installed


isIndexCalcAux :: FilePath -> InstallMode -> IO (Maybe T.Text)
isIndexCalcAux ref Root = do
    dirPath <- globalDataDirectory
    hasIndex <- doesDirContainFormats (dirPath </> getIndexPath ref) indexRequiredFormats
    case hasIndex of
        True  -> return $ (Just $ T.pack (dirPath </> getIndexPath ref))
        False -> return Nothing

isIndexCalcAux ref User = do
    udir <- userDataDirectory
    hasIndex <- doesDirContainFormats (udir </> getIndexPath ref) indexRequiredFormats
    case hasIndex of
        True  -> return $ (Just $ T.pack (udir </> getIndexPath ref))
        False -> return Nothing

configGenome :: FilePath -> InstallMode -> IO FilePath
configGenome ref Root = do
    dirPath <- globalDataDirectory
    installGenome' dirPath ref Root
configGenome ref User = do
    udir <- userDataDirectory
    installGenome' udir ref User

installGenome' p ref mode = do
    hasIndex <- isIndexCalcAux ref mode
    when (isNothing hasIndex) $ do 
        createDirectoryIfMissing True p
        installGenome ref p
    return (p </> getIndexPath ref)


installGenome :: FilePath -> FilePath -> IO ()
installGenome ref d = do
    url <- downloadURL ref
    downloadReference url (d </> tarName)
    Tar.unpack d . Tar.read . GZip.decompress =<< LB.readFile ( d </> tarName)
   where 
        dirName = case lookup (T.pack ref) defaultGenomes of
            Nothing -> error ("Should be a valid genome. The available genomes are " ++ (show defaultGenomes))
            Just v  -> v
        tarName = dirName <.> "tar.gz"

downloadReference url destPath = runResourceT $ do
    manager <- liftIO $ newManager conduitManagerSettings
    req <- liftIO $ parseUrl url
    res <- http req manager
    case Map.lookup "Content-Length" (Map.fromList $ responseHeaders res) of
        Nothing -> error ("Error on http request")
        Just genSize -> do
            responseBody res $$+- printProgress (read (B.unpack genSize) :: Int) =$ sinkFile destPath
            liftIO $ putStrLn " Genome download completed! "

printProgress :: Int -> Conduit B.ByteString (ResourceT IO) B.ByteString
printProgress genSize = do
    pbar <- liftIO (mkProgressBar 40)
    loop 0 pbar
  where
    loop len pbar = await >>= maybe (return ()) (\bs -> do
            let len' = len + B.length bs
                progress = (fromIntegral len' / fromIntegral genSize)
            pbar' <- liftIO (updateProgressBar pbar progress)
            yield bs
            loop len' pbar'
            )