{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Auto where

-- much borrowed from http://lpaste.net/raw/101205

import Control.Applicative
import Control.Arrow
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Control.Category
import Data.Traversable
import Control.Exception
import Control.Monad hiding (mapM_, sequence_, sequence)
import Control.Monad.Fix
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.ByteString.Lazy as B
import Data.Foldable
import Prelude hiding       ((.), id, mapM_, sequence_, sequence)
import System.IO

data Auto m a b = Auto { loadAuto :: Get (Auto m a b)
                       , saveAuto :: Put
                       , stepAuto :: a -> m (b, Auto m a b)
                       }

instance Monad m => Functor (Auto m a) where
    fmap f (Auto load save step) =
        Auto (fmap (fmap f) load)
             save
             (liftM (f *** fmap f) . step)

instance Monad m => Applicative (Auto m a) where
    pure x =
        let w = Auto (pure (pure x)) (pure ()) (\_ -> return (x, w))
        in  w

    Auto loadf savef stepf <*> Auto loadx savex stepx =
        Auto (liftA2 (<*>) loadf loadx) (savef *> savex) $ \x' ->
            liftM2 (\(f, wf) (x, wx) -> (f x, wf <*> wx))
                   (stepf x')
                   (stepx x')

instance Monad m => Category (Auto m) where
    id = Auto (pure id) (pure ()) (\x -> return (x, id))

    Auto load2 save2 step2 . Auto load1 save1 step1 =
        Auto (liftA2 (.) load2 load1) (save2 *> save1) $ \x0 -> do
            (x1, w1) <- step1 x0
            (x2, w2) <- step2 x1
            return (x2, w2 . w1)

instance Monad m => Arrow (Auto m) where
    arr f =
        let w = Auto (pure (arr f)) (pure ()) (\x -> return (f x, w))
        in  w

    first (Auto load save step) =
        Auto (fmap first load) save $ \(x', y) ->
            liftM (\(x, w) -> ((x, y), first w))
                  (step x')

instance MonadFix m => ArrowLoop (Auto m) where
    loop (Auto load save step) =
        Auto (fmap loop load) save $ \x' ->
            liftM (fst *** loop) .
            mfix $ \ ~((_, d), _) -> step (x', d)

instance Monad m => ArrowChoice (Auto m) where
    left a@(Auto load save step) =
        Auto (fmap left load) save $ \x' ->
          case x' of
            Left  y -> liftM (Left *** left) (step y)
            Right z -> return (Right z, left a)

encodeAuto :: Auto m a b -> ByteString
encodeAuto = runPut . saveAuto

decodeAuto :: Auto m a b -> ByteString -> Auto m a b
decodeAuto w = runGet (loadAuto w)

loadAutoFile :: forall m a b. FilePath -> Auto m a b -> IO (Auto m a b)
loadAutoFile fp a0 = do
    h <- try (openFile fp ReadMode) :: IO (Either SomeException Handle)
    a <- case h of
           Right h' -> decodeAuto a0 <$> B.hGetContents h'
           Left _   -> return a0
    try (evaluate a) :: IO (Either SomeException (Auto m a b))
    mapM_ hClose h
    return a

writeAutoFile :: FilePath -> Auto m a b -> IO ()
writeAutoFile fp a = B.writeFile fp (encodeAuto a)

integral :: (Monad m, Num a, Binary a) => a -> Auto m a a
integral x' = Auto (fmap integral get) (put x') $ \dx ->
                let !x = x' + dx
                in  return (x, integral x)
            -- also possibly scanA (+)

scanA :: (Monad m, Binary b) => (b -> a -> b) -> b -> Auto m a b
scanA f x' = Auto (fmap (scanA f) get) (put x') $ \dx ->
               let y = f x' dx
               in  return (y, scanA f y)

arrM :: Monad m => (a -> m b) -> Auto m a b
arrM f = Auto (pure (arrM f)) (pure ()) $ \x -> do
           res <- f x
           return (res, arrM f)

cacheAuto :: Monad m => m b -> Auto m a b
cacheAuto f = Auto (pure (cacheAuto f)) (pure ()) $ \_ -> do
                res <- f
                return (res, pure res)

multiAuto :: forall m c a b. (Monad m, Ord c) => (c -> Auto m a b) -> Auto m (c, a) b
multiAuto f = go M.empty
  where
    go :: (Monad m, Ord c) => Map c (Auto m a b) -> Auto m (c, a) b
    go m = Auto
             (go <$> sequence (fmap loadAuto m))
             (sequence_ (fmap saveAuto m)) $ \(k,x) -> do
               let a' = M.findWithDefault (f k) k m
               (out, a) <- stepAuto a' x
               let m' = M.insert k a m
               return (out, go m')


-- integral :: (Fractional a, Monad m, Serialize a) => a -> Wire m a a
-- -- integral x' =
--     Wire (fmap integral get) (put x') $ \dt dx ->
--         let !x = x' + realToFrac dt*dx in
--         return (x, integral x)
