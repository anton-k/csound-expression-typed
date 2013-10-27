module Csound.Typed.GlobalState.GE(
    GE, Dep, History(..), withOptions, withHistory, getOptions, evalGE, execGE,
    -- * Globals
    onGlobals, 
    -- * Midi
    MidiAssign(..), Msg(..), renderMidiAssign, saveMidi,  
    -- * Instruments
    saveAlwaysOnInstr, onInstr, saveUserInstr0, getSysExpr,
    -- * Total duration
    TotalDur(..), getTotalDur, setDuration, setDurationToInfinite,
    -- * GEN routines
    saveGen,
    -- * Band-limited waves
    saveBandLimitedWave,
    -- * Strings
    saveStr,
    -- * Cache
    GetCache, SetCache, withCache
) where

import Control.Applicative
import Control.Monad
import Data.Default

import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Strict
import Control.Monad.Trans.Reader

import Csound.Dynamic 

import Csound.Typed.GlobalState.Options
import Csound.Typed.GlobalState.Cache
import Csound.Typed.GlobalState.Elements

type Dep a = DepT GE a

-- global side effects
newtype GE a = GE { unGE :: ReaderT Options (StateT History IO) a }

runGE :: GE a -> Options -> History -> IO (a, History)
runGE (GE f) opt hist = runStateT (runReaderT f opt) hist

evalGE :: Options -> GE a -> IO a
evalGE options a = fmap fst $ runGE a options def

execGE :: Options -> GE a -> IO History
execGE options a = fmap snd $ runGE a options def

instance Functor GE where
    fmap f = GE . fmap f . unGE

instance Applicative GE where
    pure = return
    (<*>) = ap

instance Monad GE where
    return = GE . return
    ma >>= mf = GE $ unGE ma >>= unGE . mf

instance MonadIO GE where
    liftIO = GE . liftIO . liftIO
    
data History = History
    { genMap            :: GenMap
    , stringMap         :: StringMap
    , globals           :: Globals
    , instrs            :: Instrs
    , midis             :: [MidiAssign]
    , totalDur          :: Maybe TotalDur
    , alwaysOnInstrs    :: [InstrId]
    , userInstr0        :: Dep ()
    , bandLimitedMap    :: BandLimitedMap
    , cache             :: Cache GE }

instance Default History where
    def = History def def def def def def def (return ()) def def

data Msg = Msg
data MidiAssign = MidiAssign MidiType Channel InstrId
            
renderMidiAssign :: Monad m => MidiAssign -> DepT m ()
renderMidiAssign (MidiAssign ty chn instrId) = case ty of
    Massign         -> massign chn instrId
    Pgmassign mn    -> pgmassign chn instrId mn
    where
        massign n instr = depT_ $ opcs "massign" [(Xr, [Ir,Ir])] [int n, prim $ PrimInstrId instr]
        pgmassign pgm instr mchn = depT_ $ opcs "pgmassign" [(Xr, [Ir,Ir,Ir])] ([int pgm, prim $ PrimInstrId instr] ++ maybe [] (return . int) mchn)

data TotalDur = NumDur Double | InfiniteDur
    deriving (Eq, Ord)

getTotalDur :: Options -> (Maybe TotalDur) -> Double
getTotalDur _ = toDouble . maybe InfiniteDur id  
    where 
        toDouble x = case x of
            NumDur d    -> d
            InfiniteDur -> infiniteDur
        infiniteDur = 7 * 24 * 60 * 60 -- a week

saveStr :: String -> GE E
saveStr = fmap prim . onStringMap . newString
    where onStringMap = onHistory stringMap (\val h -> h{ stringMap = val })

saveGen :: Gen -> GE E
saveGen = onGenMap . newGen
    where onGenMap = onHistory genMap (\val h -> h{ genMap = val })

saveBandLimitedWave :: BandLimited -> GE Int
saveBandLimitedWave = onBandLimitedMap . saveBandLimited
    where onBandLimitedMap = onHistory 
                (\a -> (genMap a, bandLimitedMap a)) 
                (\(gm, blm) h -> h { genMap = gm, bandLimitedMap = blm})

setDurationToInfinite :: GE ()
setDurationToInfinite = setTotalDur InfiniteDur

setDuration :: Double -> GE ()
setDuration = setTotalDur . NumDur

setTotalDur :: TotalDur -> GE ()
setTotalDur = onTotalDur . modify . max . Just
    where onTotalDur = onHistory totalDur (\a h -> h { totalDur = a })

saveMidi :: MidiAssign -> GE ()
saveMidi ma = onMidis $ modify (ma: )
    where onMidis = onHistory midis (\a h -> h { midis = a })

saveUserInstr0 :: Dep () -> GE ()
saveUserInstr0 expr = onUserInstr0 $ modify ( >> expr)
    where onUserInstr0 = onHistory userInstr0 (\a h -> h { userInstr0 = a })

getSysExpr :: GE (Dep ())
getSysExpr = withHistory $ clearGlobals . globals
    where clearGlobals = snd . renderGlobals

saveAlwaysOnInstr :: InstrId -> GE ()
saveAlwaysOnInstr instrId = onAlwaysOnInstrs $ modify (instrId : )
    where onAlwaysOnInstrs = onHistory alwaysOnInstrs (\a h -> h { alwaysOnInstrs = a })

{-
setMasterInstrId :: InstrId -> GE ()
setMasterInstrId masterId = onMasterInstrId $ put masterId
    where onMasterInstrId = onHistory masterInstrId (\a h -> h { masterInstrId = a })
-}
----------------------------------------------------------------------
-- state modifiers

withOptions :: (Options -> a) -> GE a
withOptions f = GE $ asks f

getOptions :: GE Options
getOptions = withOptions id

withHistory :: (History -> a) -> GE a
withHistory f = GE $ lift $ fmap f get

modifyHistory :: (History -> History) -> GE ()
modifyHistory = GE . lift . modify

-- update fields

onHistory :: (History -> a) -> (a -> History -> History) -> State a b -> GE b
onHistory getter setter st = GE $ ReaderT $ \_ -> StateT $ \history -> 
    let (res, s1) = runState st (getter history)
    in  return (res, setter s1 history) 

type UpdField a b = State a b -> GE b

onInstr :: UpdField Instrs a
onInstr = onHistory instrs (\a h -> h { instrs = a })

onGlobals :: UpdField Globals a
onGlobals = onHistory globals (\a h -> h { globals = a })

----------------------------------------------------------------------
-- cache

-- midi functions

type GetCache a b = a -> Cache GE -> Maybe b

fromCache :: GetCache a b -> a -> GE (Maybe b)
fromCache f key = withHistory $ f key . cache

type SetCache a b = a -> b -> Cache GE -> Cache GE

toCache :: SetCache a b -> a -> b -> GE () 
toCache f key val = modifyHistory $ \h -> h { cache = f key val (cache h) }

withCache :: GetCache key val -> SetCache key val -> key -> GE val -> GE val
withCache lookupResult saveResult key getResult = do    
    ma <- fromCache lookupResult key
    case ma of
        Just a      -> return a
        Nothing     -> do
            res <- getResult
            toCache saveResult key res
            return res          

