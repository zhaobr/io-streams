{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}

module System.IO.Streams.Tests.Internal (tests) where

------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Monad hiding (mapM)
import           Control.Monad.IO.Class (liftIO)
import           Data.IORef
import           Data.Monoid
import           Prelude hiding (mapM, read)
import           Test.Framework
import           Test.Framework.Providers.HUnit
import           Test.HUnit hiding (Test)
------------------------------------------------------------------------------
import           System.IO.Streams.Internal
import           System.IO.Streams.List

tests :: [Test]
tests = [ testSourceConcat
        , testAppendInput
        , testConst
        , testCoverLockingStream
        , testPeek
        , testNullInput
        , testGenerator
        , testGeneratorInstances
        , testConsumer
        ]


------------------------------------------------------------------------------
testSourceConcat :: Test
testSourceConcat = testCase "internal/sourceConcat" $ do
    is  <- sourceToStream $ mconcat $
           map singletonSource [1::Int, 2, 3]

    unRead 7 is

    l   <- toList is

    assertEqual "sourceConcat" [7,1,2,3] l

    is' <- sourceToStream $ mconcat $
           map singletonSource [1::Int, 2, 3]

    unRead 7 is'

    l'  <- toList is'

    assertEqual "sourceConcat2" [7,1,2,3] l'


------------------------------------------------------------------------------
testAppendInput :: Test
testAppendInput = testCase "internal/appendInputStream" $ do
    s1 <- fromList [1::Int, 2, 3]
    s2 <- fromList [5, 6, 7]

    is <- appendInputStream s1 s2
    l  <- toList is

    assertEqual "appendInputStream" [1,2,3,5,6,7] l


------------------------------------------------------------------------------
testConst :: Test
testConst = testCase "internal/const" $ do
    is <- makeInputStream (return (Just (1::Int)))
    read is >>= assertEqual "const" (Just 1)

    unRead 7 is
    read is >>= assertEqual "unRead" (Just 7)
    read is >>= assertEqual "const2" (Just 1)


------------------------------------------------------------------------------
testNullInput :: Test
testNullInput = testCase "internal/nullInput" $ do
    is <- nullInput
    xs <- replicateM 10 $ read (is :: InputStream Int)
    assertEqual "nullInput" (replicate 10 Nothing) xs


------------------------------------------------------------------------------
testCoverLockingStream :: Test
testCoverLockingStream = testCase "internal/coverLockingStreams" $ do
    is <- fromList [1::Int, 2, 3] >>= lockingInputStream
    (os0, grab) <- listOutputStream
    os <- lockingOutputStream os0

    connect is os
    xs <- grab

    assertEqual "lockingStreams" [1,2,3] xs

    write Nothing os
    write Nothing os

    unRead 7 is
    y <- read is
    assertEqual "unRead" (Just 7) y


------------------------------------------------------------------------------
testPeek :: Test
testPeek = testCase "internal/peek" $ do
    is <- fromList [1::Int, 2, 3]
    b   <- atEOF is
    assertEqual "eof1" False b

    x0  <- peek is
    x1  <- peek is

    unRead 7 is
    x2  <- peek is

    assertEqual "peek" (map Just [1, 1, 7]) [x0, x1, x2]

    l   <- toList is
    assertEqual "toList" [7, 1, 2, 3] l

    z   <- peek is
    assertEqual "peekEOF" Nothing z

    b'  <- atEOF is
    assertEqual "eof2" True b'


------------------------------------------------------------------------------
testGenerator :: Test
testGenerator = testCase "internal/generator" $ do
    is <- fromGenerator $ sequence $
          Prelude.map ((>>= yield) . (liftIO . return)) [1..5::Int]
    toList is >>= assertEqual "generator" [1..5]


------------------------------------------------------------------------------
testGeneratorInstances :: Test
testGeneratorInstances = testCase "internal/generatorInstances" $ do
    fromGenerator g1 >>= toList
                     >>= assertEqual "generator" [2,4..10]

    fromGenerator g2 >>= toList
                     >>= assertEqual "generator" [2,4..10]

  where
    g1 = do
        l <- fmap (map (*2)) $ return [1..5::Int]
        fmap id $ sequence_ $ Prelude.map yield l

    g2 = pure id <*> g1


------------------------------------------------------------------------------
testConsumer :: Test
testConsumer = testCase "internal/consumer" $ do
    is  <- fromList [1..10::Int]
    ref <- newIORef 0
    os  <- fromConsumer (fmap id (pure id <*> c ref))
    connect is os
    readIORef ref >>= assertEqual "sum" (sum [1..10])

    -- should be nullsink after receiving Nothing
    write (Just 2) os
    readIORef ref >>= assertEqual "sum" (sum [1..10])

    is2 <- fromList [1..10::Int]
    os2 <- fromConsumer (return ())
    connect is2 os2

  where
    c ref = await >>= maybe (return ())
                            (\x -> do
                                 !t <- liftIO $ readIORef ref
                                 liftIO $ writeIORef ref $! t + x
                                 c ref)
