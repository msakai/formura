{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, LambdaCase, MultiWayIf, TemplateHaskell #-}

{-

　  ＿＿＿＿_＿＿＿＿
  ／＼／＼／ ＼／＼／＼
／＼／＼／＼ ／＼／＼／＼
＼　\ 　\   |　 /　 /  ／
　＼ \　|\  |  /|  / ／
　　＼\ | \ | / | /／
　　　＼|  \|/  |／
　　　  ＼  |  ／
　　　    ＼|／

-}

module Formura.MPICxx.Cut where

import           Algebra.Lattice.Levitated
import           Control.Lens
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.List (sort)
import           Data.Data
import qualified Data.Map as M
import           Data.Maybe
import           Text.Trifecta (failed, raiseErr)


import           Formura.Syntax(IdentName)
import           Formura.Vec
import           Formura.Geometry
import           Formura.GlobalEnvironment
import           Formura.OrthotopeMachine.Graph
import           Formura.NumericalConfig
import           Formura.Compiler



newtype MPIRank = MPIRank (Vec Int) deriving (Eq, Ord, Show, Read, Num)
newtype IRank = IRank (Vec Int) deriving (Eq, Show, Read, Num)

instance Ord IRank where
  (IRank (Vec xs)) `compare` (IRank (Vec ys)) = reverse xs `compare` reverse ys
  compare _ _ = error "Comparison between IRank (PureVec _) is undefined"

data ResourceT a b = ResourceStatic IdentName a | ResourceOMNode OMNodeID b
                   deriving (Eq, Ord, Show, Read, Typeable, Data)
type Resource = ResourceT () ()
type ConcreteResource = ResourceT (MPIRank, Box) (MPIRank, IRank, Box)

data DistributedInst
  = Communication ConcreteResource (IRank, OMNodeID, Box)
  | Computation (IRank, OMNodeID)


data MPIPlan = MPIPlan
  { _planArrayMargin :: M.Map (ResourceT () IRank) Box
  , _planDistributedInst :: [DistributedInst]
  }
makeClassy ''MPIPlan

data PlanRead = PlanRead
  { _prGlobalEnvironment :: GlobalEnvironment
  , _prNumericalConfig :: NumericalConfig
  , _prStepGraph :: MMGraph
   }
makeClassy ''PlanRead

instance HasGlobalEnvironment PlanRead where
  globalEnvironment = prGlobalEnvironment
instance HasNumericalConfig PlanRead where
  numericalConfig = prNumericalConfig


data PlanState = PlanState
  { _psSyntacticState :: CompilerSyntacticState
  }
makeClassy ''PlanState

instance HasCompilerSyntacticState PlanState where
  compilerSyntacticState = psSyntacticState

type PlanM = CompilerMonad PlanRead () PlanState

makePlan :: NumericalConfig -> MMProgram -> IO MPIPlan
makePlan nc prog = do
  let pr = PlanRead
           { _prGlobalEnvironment = prog ^. omGlobalEnvironment
           , _prNumericalConfig = nc
           , _prStepGraph = prog ^. omStepGraph
           }
      ps = PlanState
           { _psSyntacticState = defaultCompilerSyntacticState {_compilerStage = "MPI Planning"}
           }



  (ret, _, _) <- runCompilerRight cut pr ps
  return ret

getVecAccessor :: PlanM (Vec a -> IdentName -> a)
getVecAccessor = do
  Vec xs <- view axesNames
  let indmap = zip xs [0..]

      go (PureVec y) _ = y
      go (Vec ys) x' = let Just i = lookup x' indmap in ys!!i
  return go

type Walls = Vec [Partition]


initialWalls :: PlanM Walls
initialWalls = do
  axes <- view axesNames
  iwparam <- view ncInitialWalls
  intraShape <- view ncIntraNodeShape
  (!) <- getVecAccessor

  let boundOfAxis :: String -> Bool -> Int -> Vec (Levitated Int, Levitated Int)
      boundOfAxis x ascending n = flip fmap axes $ \y ->
        if | x == y && ascending -> (Levitate n, Bottom)
           | x == y              -> (Top       , Levitate n)
           | otherwise           -> (Top       , Bottom)
      mkWall :: String -> Bool -> Int -> Partition
      mkWall x a n = let ret = boundOfAxis x a n in Orthotope (fmap fst ret) (fmap snd ret)


  forM axes $ \ x -> do
    case M.lookup x iwparam of
     Nothing -> raiseErr $ failed $ "cannot find initial_wall numerical configuration for axis: " ++ x
     Just [] -> raiseErr $ failed $ "at least 1 element is needed for initial_wall numerical configuration for axis: " ++ x
     Just ws -> return $ [mkWall x True 0] ++ map (mkWall x False) ws ++ [mkWall x True (intraShape ! x)]

evalWall :: Partition -> Int
evalWall w = case foldMap (maybeToList . touchdown) w of
  [x] -> x
  _   -> error $ "malformed wall: " ++ show w



cut :: PlanM MPIPlan
cut = do
  dim <- view dimension
  let zeroVec = Vec $ replicate dim 0

  walls0 <- initialWalls
  -- liftIO $ print (walls0 :: Walls)
  let wvs = fmap (fmap evalWall) walls0
  -- liftIO $ print (wvs :: Vec [Int])

  stepGraph <- view prStepGraph

  let wallMap :: M.Map OMNodeID Walls
      wallMap = M.mapWithKey go stepGraph

      go :: OMNodeID -> MMNode -> Walls
      go i mmNode = let
          mmInst :: MMInstruction
          mmInst = mmNode ^. nodeInst
          microInsts :: [MMInstF MMNodeID]
          microInsts = map (^. nodeInst) $ M.elems mmInst
        in foldr1 (&&&) (map listBounds microInsts)

      listBounds :: MMInstF MMNodeID -> Walls
      listBounds (LoadCursorStatic v _) = move (negate v) walls0
      listBounds (LoadCursor v nid) =
        let Just w_of_n = M.lookup nid wallMap
        in move (negate v) w_of_n
      listBounds _ = fmap (fmap (const (mempty :: Partition))) walls0

      wallEvolution :: M.Map OMNodeID (Vec [Int])
      wallEvolution = fmap (fmap (fmap evalWall)) wallMap

  -- liftIO $ print (wallEvolution :: M.Map OMNodeID (Vec [Int]))

  intraShape0 <- view ncIntraNodeShape

  let iRanks0 :: [IRank]
      iRanks0 =
        sort $
        map IRank $
        sequence $
        fmap (\partitions0 -> [0..length partitions0-2]) walls0

      boxAt :: IRank -> Vec [Int] -> Box
      boxAt (IRank vi) vw = Orthotope (liftVec2 (\i xs-> xs!!i) vi vw) (liftVec2 (\i xs-> xs!!(i+1)) vi vw)

      iRankMap :: M.Map OMNodeID (M.Map IRank Box)
      iRankMap = flip fmap wallEvolution $ \vi -> M.fromList
        [(ir, boxAt ir vi)| ir <- iRanks0]

      boxAssignment :: MPIRank -> IRank -> OMNodeID -> Box
      boxAssignment (MPIRank mpir) ir nid = fromJust $ do
        m <- M.lookup nid iRankMap
        ret <- M.lookup ir m
        return $ move (mpir*intraShape0) ret

      mpiRanks0 :: [MPIRank]
      mpiRanks0 =
        map MPIRank $
        (sequence :: Vec [Int] -> [Vec Int]) $
        Vec $
        replicate dim [-1,0,1]
      mpiRankOrigin :: MPIRank
      mpiRankOrigin = MPIRank $ zeroVec

      mpiBox0 :: Box
      mpiBox0 = Orthotope zeroVec intraShape0

{-
  liftIO $ forM_ (M.keys stepGraph) $ \nid -> do
    putStrLn $ "NODE: " ++ show nid
    forM_ iRanks0 $ \ir -> do
      putStrLn $ "  IR: " ++ show ir
      putStrLn $ "    " ++ show (boxAssignment mpiRankOrigin ir nid)
-}
  let supportMap :: M.Map (IRank, OMNodeID) (M.Map Resource Box)
      supportMap = M.fromList [((ir, nid), go ir nid (fromJust $ M.lookup nid stepGraph))
                              | ir <- iRanks0, nid <- M.keys stepGraph]

      go :: IRank -> OMNodeID -> MMNode -> M.Map Resource Box
      go ir nid mmNode = let
          mmInst :: MMInstruction
          mmInst = mmNode ^. nodeInst
          microInsts :: [MMInstF MMNodeID]
          microInsts = map (^. nodeInst) $ M.elems mmInst
          b0 = boxAssignment mpiRankOrigin ir nid
        in M.unionsWith (|||) (map (listSupport b0) microInsts)

      listSupport :: Box -> MMInstF MMNodeID -> M.Map Resource Box
      listSupport b0 (LoadCursorStatic v snName) = M.singleton (ResourceStatic snName ()) (move v b0)
      listSupport b0 (LoadCursor v nid) =
        M.singleton (ResourceOMNode nid ()) (move v b0)
      listSupport _ _ = M.empty

  {-
  liftIO $ forM_ iRanks0 $ \ir -> do
    putStrLn $ "IR: " ++ show ir
    forM_ (M.keys stepGraph) $ \nid -> do
      putStrLn $ "  NODE: " ++ show nid
      putStrLn $ "    " ++ show (M.lookup (ir,nid) supportMap)
-}

  let locateSource :: (Resource, Box) -> [ConcreteResource]
      locateSource (ResourceOMNode nid (),b0) =
        [ ResourceOMNode nid (mpir, ir, b01)
        | (mpir,ir,b1) <- fromJust $ M.lookup nid allPossibleSources
        , let b01 = b0 &&& b1
        , volume b01 > 0]
      locateSource (ResourceStatic snName (),b0) =
        [ ResourceStatic snName (mpir, b01)
        | (mpir,b1) <- allPossibleSourcesStatic
        , let b01 = b0 &&& b1
        , volume b01 > 0]

      locateSource (ResourceStatic snName (), b0) =
        map (ResourceStatic snName) $
        filter (\(_,b1) -> b0 `intersects` b1) $
        allPossibleSourcesStatic

      allPossibleSources :: M.Map OMNodeID [(MPIRank, IRank, Box)]
      allPossibleSources = M.fromList
                           [ (nid, [(mpir, ir, boxAssignment mpir ir nid)
                                   | mpir <- mpiRanks0
                                   , ir <- iRanks0])
                           | nid <- M.keys stepGraph
                           ]

      allPossibleSourcesStatic :: [(MPIRank, Box)]
      allPossibleSourcesStatic =
        [ (mpir,b)
        | mpir@(MPIRank mpiVec) <- mpiRanks0
        , let b = move (mpiVec*intraShape0) mpiBox0
        ]

      locatedSupportMap :: M.Map (IRank, OMNodeID) [ConcreteResource]
      locatedSupportMap = undefined


  return MPIPlan{}
