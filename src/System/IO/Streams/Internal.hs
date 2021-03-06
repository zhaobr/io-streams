-- | Internal implementation of the @io-streams@ library, intended for library
-- writers
--
-- Library users should use the interface provided by "System.IO.Streams"

{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}

module System.IO.Streams.Internal
  ( -- * Types
    SP(..)
  , Source(..)
  , Sink(..)

    -- * About pushback
    -- $pushback

    -- * Pushback functions
  , defaultPushback
  , withDefaultPushback

    -- * Basic sources and sinks
  , nullSource
  , nullSink
  , singletonSource

    -- * Input and output streams
  , InputStream(..)
  , OutputStream(..)

    -- * Primitive stream operations
  , read
  , unRead
  , peek
  , write
  , atEOF

    -- * Building streams
  , sourceToStream
  , sinkToStream
  , makeInputStream
  , makeOutputStream
  , appendInputStream

    -- * Connecting streams
  , connect
  , connectTo
  , supply
  , supplyTo

    -- * Thread safety
  , lockingInputStream
  , lockingOutputStream

    -- * Utility streams
  , nullInput
  , nullOutput

    -- * Generator monad
  , Generator
  , generatorToSource
  , fromGenerator
  , yield

    -- * Consumer monad
  , Consumer
  , consumerToSink
  , fromConsumer
  , await
  ) where

------------------------------------------------------------------------------
import           Control.Applicative    (Applicative (..))
import           Control.Concurrent     (newMVar, withMVar)
import           Control.Monad          (liftM)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.IORef             (IORef, newIORef, readIORef, writeIORef)
import           Data.Monoid            (Monoid (..))
import           Prelude                hiding (read)


------------------------------------------------------------------------------
-- | A strict pair type.
data SP a b = SP !a !b

------------------------------------------------------------------------------
-- | A 'Source' generates values of type @c@ in the 'IO' monad.
--
-- 'Source's wrap ordinary values in a 'Just' and signal end-of-stream by
-- yielding 'Nothing'.
--
-- All 'Source's define an optional push-back mechanism. You can assume that:
--
-- @
-- Streams.'pushback' source c >>= Streams.'produce' = 'return' (source, 'Just' c)
-- @
--
-- ... unless a 'Source' documents otherwise.
--
-- 'Source' is to be considered an implementation detail of the library, and
-- should only be used in code that needs explicit control over the 'pushback'
-- semantics.
--
-- Most library users should instead directly use 'InputStream's, which prevent
-- reuse of previous 'Source's.
data Source c = Source {
      produce  :: IO (SP (Source c) (Maybe c))
    , pushback :: c -> IO (Source c)
    }


------------------------------------------------------------------------------
-- | A 'Generator' is a coroutine monad that can be used to define complex
-- 'InputStream's. You can cause a value of type @Just r@ to appear when the
-- 'InputStream' is read by calling 'yield':
--
-- @
-- g :: 'Generator' Int ()
-- g = do
--     Streams.'yield' 1
--     Streams.'yield' 2
--     Streams.'yield' 3
-- @
--
-- A 'Generator' can be turned into an 'InputStream' by calling
-- 'fromGenerator':
--
-- @
-- m :: 'IO' ['Int']
-- m = Streams.'fromGenerator' g >>= Streams.'System.IO.Streams.toList'     \-\- value returned is [1,2,3]
-- @
--
-- You can perform IO by calling 'liftIO', and turn a 'Generator' into an
-- 'InputStream' with 'fromGenerator'.
--
-- As a general rule, you should not acquire resources that need to be freed
-- from a 'Generator', because there is no guarantee the coroutine continuation
-- will ever be called, nor can you catch an exception from within a
-- 'Generator'.
newtype Generator r a = Generator {
      unG :: IO (Either (SP r (Generator r a)) a)
    }


------------------------------------------------------------------------------
generatorBind :: Generator r a -> (a -> Generator r b) -> Generator r b
generatorBind (Generator m) f = Generator (m >>= either step value)
  where
    step (SP v r) = return $! Left $! SP v (generatorBind r f)
    value = unG .  f


------------------------------------------------------------------------------
instance Monad (Generator r) where
   return = Generator . return . Right
   (>>=)  = generatorBind


------------------------------------------------------------------------------
instance MonadIO (Generator r) where
    liftIO = Generator . (Right `fmap`)


------------------------------------------------------------------------------
instance Functor (Generator r) where
    fmap f (Generator m) = Generator $ m >>= either step value
      where
        step (SP v m') = return $! Left $! SP v (fmap f m')
        value v        = return $! Right $! f v


------------------------------------------------------------------------------
instance Applicative (Generator r) where
    pure = Generator . return . Right

    m <*> n = do
        f <- m
        v <- n
        return $! f v


------------------------------------------------------------------------------
-- | Calling @'yield' x@ causes the value @'Just' x@ to appear on the input
-- when this generator is converted to an 'InputStream'. The rest of the
-- computation after the call to 'yield' is resumed later when the
-- 'InputStream' is 'read' again.
yield :: r -> Generator r ()
yield x = Generator $! return $! Left $! SP x (return $! ())


------------------------------------------------------------------------------
-- | Turns a 'Generator' into a 'Source' using the default pushback mechanism.
generatorToSource :: Generator r a -> Source r
generatorToSource (Generator m) = withDefaultPushback go
  where
    go              = m >>= either step finish
    finish          = const $ return $! SP nullSource Nothing
    step (SP v gen) = return $! SP (generatorToSource gen) (Just v)


------------------------------------------------------------------------------
-- | Turns a 'Generator' into an 'InputStream'.
fromGenerator :: Generator r a -> IO (InputStream r)
fromGenerator = sourceToStream . generatorToSource


------------------------------------------------------------------------------
newtype Consumer c a = Consumer {
      unC :: IO (Either (Maybe c -> Consumer c a) a)
    }


------------------------------------------------------------------------------
instance Monad (Consumer c) where
    return = Consumer . return . Right

    (Consumer m) >>= f = Consumer $ m >>= either step value
      where
        step g  = return $! Left $! (>>= f) . g
        value v = unC $ f v


------------------------------------------------------------------------------
instance MonadIO (Consumer c) where
    liftIO = Consumer . fmap Right


------------------------------------------------------------------------------
instance Functor (Consumer r) where
    fmap f (Consumer m) = Consumer (m >>= either step value)
      where
        step g = return $! Left $! (fmap f) . g
        value v = return $! Right $! f v


------------------------------------------------------------------------------
instance Applicative (Consumer r) where
    pure = return

    m <*> n = do
        f <- m
        v <- n
        return $! f v


------------------------------------------------------------------------------
await :: Consumer r (Maybe r)
await = Consumer $ return (Left return)


------------------------------------------------------------------------------
consumerToSink :: Consumer r a -> Sink r
consumerToSink (Consumer m) = Sink $ go m
  where
    go act v = act >>= either step value
      where
        value _ = return nullSink
        step f  = unC (f v) >>=
                  either (\g -> return $! Sink $! go (return $ Left g))
                         (const $ return nullSink)


------------------------------------------------------------------------------
fromConsumer :: Consumer r a -> IO (OutputStream r)
fromConsumer = sinkToStream . consumerToSink


------------------------------------------------------------------------------
-- | A 'Sink' consumes values of type @c@ in the 'IO' monad.
--
-- Sinks are supplied ordinary values by wrapping them in 'Just', and you
-- indicate the end of the stream to a 'Sink' by supplying 'Nothing'.
--
-- If you supply a value after a 'Nothing', the behavior is defined by the
-- implementer of the given 'Sink'. (All 'Sink' definitions in this library
-- will simply discard the extra input.)
--
-- Library users should use 'OutputStream's, which prevent reuse of previous
-- 'Sink's.
data Sink c = Sink {
      consume :: Maybe c -> IO (Sink c)
    }


------------------------------------------------------------------------------
-- | 'appendSource' concatenates two 'Source's, analogous to ('++') for lists.
--
-- The second 'Source' continues where the first 'Source' ends.
--
-- 'appendSource' defines a monoid with 'nullSource' as the identity:
--
-- > nullSource `appendSource` s = s
-- >
-- > s `appendSource` nullSource = s
-- >
-- >  (s1 `appendSource` s2) `appendSource` s3
-- > = s1 `appendSource` (s2 `appendSource` s3)
appendSource :: Source c -> Source c -> Source c
appendSource !p !q = Source prod pb
  where
    prod = do
        (SP p' c) <- produce p
        maybe (produce q)
              (const $ return $! SP (p' `appendSource` q) c)
              c

    pb c = do
        s' <- pushback p c
        return $! s' `appendSource` q


------------------------------------------------------------------------------
instance Monoid (Source a) where
    mempty  = nullSource
    mappend = appendSource


{- TODO: Define better convenience functions for pushback.  These convenience
         functions still require that the user ties the knot to correctly define
         pushback, which is error-prone for non-trivial pushback
         customizations. -}

------------------------------------------------------------------------------
-- | The default pushback implementation. Given a 'Source' and a value to push
-- back, produces a new 'Source' that will 'produce' the value given and yield
-- the original 'Source', and where 'pushback' recursively calls
-- 'defaultPushback'.
defaultPushback :: Source c -> c -> IO (Source c)
defaultPushback s c = let s' = Source { produce  = return $! SP s (Just c)
                                      , pushback = defaultPushback s'
                                      }
                      in return $! s'


------------------------------------------------------------------------------
-- | Given an action to use as 'produce', creates a 'Source' that uses
-- 'defaultPushback' as its 'pushback'.
withDefaultPushback :: IO (SP (Source c) (Maybe c)) -> Source c
withDefaultPushback prod = let s = Source prod (defaultPushback s)
                           in s


------------------------------------------------------------------------------
-- | An empty source that immediately yields 'Nothing'.
nullSource :: Source c
nullSource = withDefaultPushback (return $! SP nullSource Nothing)


------------------------------------------------------------------------------
-- | 'nullSink' discards all values it consumes.
nullSink :: Sink c
nullSink = Sink $ const $ return nullSink


------------------------------------------------------------------------------
-- | Transforms any value into a 1-element 'Source'.
singletonSource :: c -> Source c
singletonSource c = withDefaultPushback $ return $! SP nullSource (Just c)


------------------------------------------------------------------------------
-- A note for readers: why are we using IORef inside InputStream and
-- OutputStream instead of MVar?
--
-- A modifyMVar takes about 35ns to run on my Macbook, and the equivalent
-- readIORef/writeIORef pair takes 6ns.
--
-- Given that we'll be composing these often, we'll give up thread safety in
-- order to gain a 6x performance improvement. If you want thread-safe access
-- to a stream, you can use lockingInputStream or lockingOutputStream.
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | An 'InputStream' generates values of type @c@ in the 'IO' monad.
--
--  Two primitive operations are defined on 'InputStream':
--
-- * @'read' :: 'InputStream' c -> 'IO' ('Maybe' c)@ reads a value from the stream,
-- where \"end of stream\" is signaled by 'read' returning 'Nothing'.
--
-- * @'unRead' :: c -> 'InputStream' c -> 'IO' ()@ \"pushes back\" a value to the
-- stream.
--
-- It is intended that 'InputStream's obey the following law:
--
-- @'unRead' c stream >> 'read' stream === 'return' ('Just' c)@
--
newtype InputStream  c = IS (IORef (Source c))


------------------------------------------------------------------------------
-- | An 'OutputStream' consumes values of type @c@ in the 'IO' monad.
-- The only primitive operation defined on 'OutputStream' is:
--
-- * @'write' :: 'Maybe' c -> 'OutputStream' c -> 'IO' ()@
--
-- Values of type @c@ are written in an 'OutputStream' by wrapping them in
-- 'Just', and the end of the stream is indicated by by supplying 'Nothing'.
--
-- If you supply a value after a 'Nothing', the behavior is defined by the
-- implementer of the given 'OutputStream'. (All 'OutputStream' definitions in
-- this library will simply discard the extra input.)
--
newtype OutputStream c = OS (IORef (Sink   c))


------------------------------------------------------------------------------
-- | Reads one value from an 'InputStream'.
--
-- Returns either a value wrapped in a 'Just', or 'Nothing' if the end of the
-- stream is reached.
read :: InputStream c -> IO (Maybe c)
read (IS ref) = do
    m       <- readIORef ref
    SP m' x <- produce m
    writeIORef ref m'
    return x
{-# INLINE read #-}


------------------------------------------------------------------------------
-- | Pushes a value back onto an input stream. 'read' and 'unRead' should
-- satisfy the following law, with the possible exception of side effects:
--
-- @
-- Streams.'unRead' c stream >> Streams.'read' stream === 'return' ('Just' c)
-- @
--
-- Note that this could be used to add values back to the stream that were not
-- originally drawn from the stream.
unRead :: c -> InputStream c -> IO ()
unRead c (IS ref) = readIORef ref >>= f >>= writeIORef ref
  where
    f (Source _ pb) = pb c
{-# INLINE unRead #-}


------------------------------------------------------------------------------
-- | Converts a 'Source' to an 'InputStream'.
sourceToStream :: Source a -> IO (InputStream a)
sourceToStream = liftM IS . newIORef
{-# INLINE sourceToStream #-}


------------------------------------------------------------------------------
-- | Converts a 'Sink' to an 'OutputStream'.
sinkToStream :: Sink a -> IO (OutputStream a)
sinkToStream = liftM OS . newIORef
{-# INLINE sinkToStream #-}


------------------------------------------------------------------------------
-- | 'appendInputStream' concatenates two 'InputStream's, analogous to ('++')
-- for lists.
--
-- The second 'InputStream' continues where the first 'InputStream' ends.
--
-- Note: values pushed back to 'appendInputStream' are not propagated to either
-- wrapped 'InputStream'.
appendInputStream :: InputStream a -> InputStream a -> IO (InputStream a)
appendInputStream s1 s2 = sourceToStream src1
  where
    src1 = withDefaultPushback read1
    src2 = withDefaultPushback read2

    read1 = do
        x <- read s1
        maybe read2 (const $! return $! SP src1 x) x

    read2 = do
        x <- read s2
        return $! SP src2 x


------------------------------------------------------------------------------
-- | Observes the first value from an 'InputStream' without consuming it.
--
-- Returns 'Nothing' if the 'InputStream' is empty. 'peek' satisfies the
-- following law:
--
-- @
-- Streams.'peek' stream >> Streams.'read' stream === Streams.'read' stream
-- @
peek :: InputStream c -> IO (Maybe c)
peek s = do
    x <- read s
    maybe (return $! ()) (\c -> unRead c s) x
    return x
{-# INLINE peek #-}


------------------------------------------------------------------------------
-- | Feeds a value to an 'OutputStream'. Values of type @c@ are written in an
-- 'OutputStream' by wrapping them in 'Just', and the end of the stream is
-- indicated by by supplying 'Nothing'.
--
write :: Maybe c -> OutputStream c -> IO ()
write c (OS ref) = readIORef ref >>= (($ c) . consume) >>= writeIORef ref
{-# INLINE write #-}


------------------------------------------------------------------------------
-- | Connects an 'InputStream' and 'OutputStream', supplying values from the
-- 'InputStream' to the 'OutputStream', and propagating the end-of-stream
-- message from the 'InputStream' through to the 'OutputStream'.
--
-- The connection ends when the 'InputStream' yields a 'Nothing'.
connect :: InputStream a -> OutputStream a -> IO ()
connect p q = loop
  where
    loop = do
        m <- read p
        maybe (write Nothing q)
              (const $ write m q >> loop)
              m
{-# INLINE connect #-}


------------------------------------------------------------------------------
-- | The 'connectTo' function is just @'flip' 'connect'@.
--
-- Useful for writing expressions like @fromList [1,2,3] >>= connectTo foo@.
--
connectTo :: OutputStream a -> InputStream a -> IO ()
connectTo = flip connect
{-# INLINE connectTo #-}


------------------------------------------------------------------------------
-- | Connects an 'InputStream' to an 'OutputStream' without passing the
-- end-of-stream notification through to the 'OutputStream'.
--
-- Use this to supply an 'OutputStream' with multiple 'InputStream's and use
-- 'connect' for the final 'InputStream' to finalize the 'OutputStream', like
-- so:
--
-- @
-- do Streams.'supply'  input1 output
--    Streams.'supply'  input2 output
--    Streams.'connect' input3 output
-- @
--
supply :: InputStream a -> OutputStream a -> IO ()
supply p q = loop
  where
    loop = do
        m <- read p
        maybe (return $! ())
              (const $ write m q >> loop)
              m
{-# INLINE supply #-}


------------------------------------------------------------------------------
-- | 'supply' with the arguments flipped.
supplyTo :: OutputStream a -> InputStream a -> IO ()
supplyTo = flip supply
{-# INLINE supplyTo #-}


------------------------------------------------------------------------------
-- | Creates an 'InputStream' from a value-producing action.
--
-- (@makeInputStream m@) calls the action @m@ each time you request a value
-- from the 'InputStream'. The given action is extended with the default
-- pushback mechanism (see "System.IO.Streams.Internal#pushback").
makeInputStream :: IO (Maybe a) -> IO (InputStream a)
makeInputStream m = sourceToStream s
  where
    s = Source { produce = do
                     x <- m
                     return $! maybe (SP nullSource Nothing)
                                     (const $ SP s x)
                                     x
               , pushback = defaultPushback s
               }
{-# INLINE makeInputStream #-}


------------------------------------------------------------------------------
-- | Creates an 'OutputStream' from a value-consuming action.
--
-- (@makeOutputStream f@) runs the computation @f@ on each value fed to it.
makeOutputStream :: (Maybe a -> IO ()) -> IO (OutputStream a)
makeOutputStream f = sinkToStream s
  where
    s = Sink (\x -> f x >> return s)
{-# INLINE makeOutputStream #-}


------------------------------------------------------------------------------
-- | Converts an 'InputStream' into a thread-safe 'InputStream', at a slight
-- performance penalty.
--
-- For performance reasons, this library provides non-thread-safe streams by
-- default. Use the @locking@ functions to convert these streams into slightly
-- slower, but thread-safe, equivalents.
lockingInputStream :: InputStream a -> IO (InputStream a)
lockingInputStream s = do
    mv <- newMVar $! ()
    let src = Source { produce = withMVar mv $ const $ do
                           x <- read s
                           return $! SP src x
                     , pushback = \c -> withMVar mv $ const $ do
                                      unRead c s
                                      return src
                     }
    sourceToStream src
{-# INLINE lockingInputStream #-}


------------------------------------------------------------------------------
-- | Converts an 'OutputStream' into a thread-safe 'OutputStream', at a slight
-- performance penalty.
--
-- For performance reasons, this library provides non-thread-safe streams by
-- default. Use the @locking@ functions to convert these streams into slightly
-- slower, but thread-safe, equivalents.
lockingOutputStream :: OutputStream a -> IO (OutputStream a)
lockingOutputStream s = do
    mv <- newMVar $! ()
    makeOutputStream $ f mv

  where
    f mv x = withMVar mv $ const $ write x s
{-# INLINE lockingOutputStream #-}


------------------------------------------------------------------------------
-- | An empty 'InputStream' that yields 'Nothing' immediately.
nullInput :: IO (InputStream a)
nullInput = sourceToStream nullSource


------------------------------------------------------------------------------
-- | An empty 'OutputStream' that discards any input fed to it.
nullOutput :: IO (OutputStream a)
nullOutput = sinkToStream nullSink


------------------------------------------------------------------------------
-- | Checks if an 'InputStream' is at end-of-stream.
atEOF :: InputStream a -> IO Bool
atEOF s = read s >>= maybe (return True) (\k -> unRead k s >> return False)


------------------------------------------------------------------------------
-- $pushback
-- #pushback#
--
-- Users can push a value back into an input stream using the 'unRead'
-- function. Usually this will use the default pushback mechanism which
-- provides a buffer for the stream. Some stream transformers, like
-- 'takeBytes', produce streams that send pushed-back values back to the
-- streams that they wrap. A function like 'System.IO.Streams.Combinators.map'
-- cannot do this because the types don't match up:
--
-- @
-- 'System.IO.Streams.Combinators.map' :: (a -> b) -> 'InputStream' a -> 'IO' ('InputStream' b)
-- @
--
-- A function will usually document if its pushback behaviour differs from the
-- default. No matter what the case, input streams should obey the following
-- law:
--
-- @
-- Streams.'unRead' c stream >> Streams.'read' stream === 'return' ('Just' c)
-- @
