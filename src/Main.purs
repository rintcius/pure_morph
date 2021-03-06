module Main where

import Prelude
import Config (UIST, EpiS, Pattern, EngineST, EngineConf, SystemST, SystemConf, UIConf)
import Control.Monad (unless, when)
import Control.Monad.Eff (Eff)
import Control.Monad.Except.Trans (lift)
import Control.Monad.ST (ST, STRef, readSTRef, newSTRef, modifySTRef, runST)
import DOM (DOM)
import Data.Int (round, toNumber)
import Data.Maybe (fromMaybe, Maybe(Nothing, Just))
import Data.StrMap (lookup)
import Engine (initEngineST, renderFrame, setShaders)
import Graphics.Canvas (Canvas)
import Layout (updateLayout)
import Paths (runPaths)
import Pattern (importPattern)
import Script (runScripts)
import System (initSystemST, loadLib)
import UI (initUIST)
import Util (lg, isHalted, requestAnimationFrame, now, Now, handleError, seedRandom, urlArgs, isDev)

host :: String
host = ""

type State h = {
    ucRef :: STRef h UIConf
  , usRef :: STRef h UIST
  , scRef :: STRef h SystemConf
  , ssRef :: STRef h (SystemST h)
  , ecRef :: STRef h EngineConf
  , esRef :: STRef h EngineST
  , pRef  :: STRef h Pattern
}


getSysConfName :: forall eff. Eff eff String
getSysConfName = do
  args <- urlArgs
  dev <- isDev
  let def = if dev then "dev" else "prod"
  let conf = fromMaybe def (lookup "system" args)
  return conf

init :: forall eff h. EpiS eff h (State h)
init = do
  -- init system
  systemST <- initSystemST host
  ssRef <- lift $ newSTRef systemST

  -- init config
  systemName <- lift $ getSysConfName
  systemConf <- loadLib systemName systemST.systemConfLib "init system"
  let systemConf' = systemConf {host = host}

  when (systemConf.seed /= "") do
    lift $ seedRandom systemConf.seed

  engineConf <- loadLib systemConf'.initEngineConf systemST.engineConfLib "init engine"
  uiConf     <- loadLib systemConf'.initUIConf systemST.uiConfLib "init ui"
  pattern    <- loadLib systemConf'.initPattern systemST.patternLib "init pattern"

  -- build strefs
  scRef <- lift $ newSTRef systemConf'
  ecRef <- lift $ newSTRef engineConf
  ucRef <- lift $ newSTRef uiConf
  pRef  <- lift $ newSTRef pattern

  -- import pattern
  importPattern ssRef pRef
  pattern'  <- lift $ readSTRef pRef
  systemST' <- lift $ readSTRef ssRef

  -- init engine & ui states
  esRef <- initEngineST systemConf' engineConf systemST' pattern' uiConf.canvasId Nothing
  usRef <- initUIST ucRef ecRef esRef pRef scRef ssRef

  return {ucRef, usRef, ssRef, scRef, ecRef, esRef, pRef}


animate :: forall h. EpiS (now :: Now) h (State h) -> Eff (canvas :: Canvas, dom :: DOM, now :: Now, st :: ST h) Unit
animate stateM = handleError do
  -- unpack state
  state@{ucRef, usRef, ssRef, scRef, ecRef, esRef, pRef} <- stateM
  uiConf     <- lift $ readSTRef ucRef
  uiST       <- lift $ readSTRef usRef
  systemST   <- lift $ readSTRef ssRef
  systemConf <- lift $ readSTRef scRef
  engineConf <- lift $ readSTRef ecRef
  engineST   <- lift $ readSTRef esRef
  pattern    <- lift $ readSTRef pRef

  -- update time
  currentTimeMS <- lift $ now
  let lastTimeMS = fromMaybe currentTimeMS systemST.lastTimeMS
  let delta = (currentTimeMS - lastTimeMS) * pattern.tSpd / 1000.0
  --let delta' = 0.05
  let delta' = if systemST.paused then 0.0 else delta
  let t' = systemST.t + delta'
  lift $ modifySTRef ssRef (\s -> s {t = t', lastTimeMS = Just currentTimeMS})

  -- fps
  when (systemST.frameNum `mod` uiConf.uiUpdateFreq == 0) do
    let lastFpsTimeMS = fromMaybe currentTimeMS systemST.lastFpsTimeMS
    let fps = round $ (toNumber uiConf.uiUpdateFreq) * 1000.0 / (currentTimeMS - lastFpsTimeMS)
    lift $ modifySTRef ssRef (\s -> s {lastFpsTimeMS = Just currentTimeMS, fps = Just fps})
    return unit

  -- update pattern
  runPaths ssRef pRef
  recompile <- runScripts ssRef pRef
  systemST' <- lift $ readSTRef ssRef

  case recompile of -- when doesnt work here for some godforsaken reason
    true -> do
      setShaders systemConf engineConf esRef systemST' pattern
      currentTimeMS2 <- lift $ now
      lift $ modifySTRef ssRef (\s -> s {lastTimeMS = Just currentTimeMS2})

      return unit
    false -> return unit

  engineST' <- lift $ readSTRef esRef
  systemST'' <- lift $ readSTRef ssRef

  -- render!
  renderFrame systemST'' engineConf engineST' pattern systemST'.frameNum

  -- update ui
  updateLayout uiConf uiST systemST'' pattern

  -- request next frame
  halted <- lift $ isHalted
  unless halted do
    lift $ modifySTRef ssRef (\s -> s {frameNum = s.frameNum + 1})
    lift $ requestAnimationFrame $ animate $ return state

  return unit


main :: Eff (canvas :: Canvas, dom :: DOM, now :: Now) Unit
main = runST do
  animate init
