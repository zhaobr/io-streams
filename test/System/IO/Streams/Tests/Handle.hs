{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}

module System.IO.Streams.Tests.Handle (tests) where

------------------------------------------------------------------------------
import           Control.Exception
import           Control.Monad hiding (mapM)
import qualified Data.ByteString.Char8 as S
import           Data.List
import           Prelude hiding (mapM, read)
import           System.Directory
import           System.FilePath
import           System.IO
import           System.IO.Streams hiding (intersperse)
import           Test.Framework
import           Test.Framework.Providers.HUnit
import           Test.HUnit hiding (Test)
------------------------------------------------------------------------------
import           System.IO.Streams.Tests.Common

tests :: [Test]
tests = [ testHandle ]


------------------------------------------------------------------------------
testHandle :: Test
testHandle = testCase "file/files" $ do
    createDirectoryIfMissing False "tmp"
    tst `finally` eatException (removeFile fn >> removeDirectory "tmp")

  where
    fn = "tmp" </> "data"

    tst = do
        withBinaryFile fn WriteMode $ \h -> do
            let l = "" : (intersperse " " ["the", "quick", "brown", "fox"])
            os <- handleToOutputStream h
            fromList l >>= connectTo os

        withBinaryFile fn ReadMode $ \h -> do
            l <- liftM S.concat (handleToInputStream h >>= toList)
            assertEqual "testFiles" "the quick brown fox" l
