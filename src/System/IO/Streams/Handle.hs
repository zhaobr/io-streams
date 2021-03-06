-- | Input and output streams for file 'Handle's.
module System.IO.Streams.Handle
 ( -- * Handle conversions
   handleToInputStream
 , handleToOutputStream
 ) where

import qualified Data.ByteString            as S
import           Data.ByteString            ( ByteString )
import           System.IO                  ( Handle, hFlush )
------------------------------------------------------------------------------
import           System.IO.Streams.Internal ( InputStream
                                            , OutputStream
                                            , makeInputStream
                                            , makeOutputStream
                                            )


------------------------------------------------------------------------------
bUFSIZ :: Int
bUFSIZ = 32752


------------------------------------------------------------------------------
-- | Converts a read-only handle into an 'InputStream' of strict 'ByteString's.
handleToInputStream :: Handle -> IO (InputStream ByteString)
handleToInputStream h = makeInputStream f
  where
    f = do
        x <- S.hGetSome h bUFSIZ
        return $! if S.null x then Nothing else Just x


------------------------------------------------------------------------------
-- | Converts a writable handle into an 'OutputStream' of strict 'ByteString's.
handleToOutputStream :: Handle -> IO (OutputStream ByteString)
handleToOutputStream h = makeOutputStream f
  where
    f Nothing  = return $! ()
    f (Just x) = if S.null x
                   then hFlush h
                   else S.hPut h x
