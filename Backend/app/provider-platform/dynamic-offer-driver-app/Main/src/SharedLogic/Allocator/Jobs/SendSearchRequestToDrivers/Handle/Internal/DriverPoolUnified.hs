module SharedLogic.Allocator.Jobs.SendSearchRequestToDrivers.Handle.Internal.DriverPoolUnified where

import Control.Monad.Extra (partitionM)
import Data.Aeson
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as AKM
import qualified Data.List as DL
import qualified Data.Map as Map
import Domain.Types.Common
import Domain.Types.DriverGoHomeRequest as DDGR
import Domain.Types.DriverPoolConfig
import Domain.Types.GoHomeConfig (GoHomeConfig)
import qualified Domain.Types.Merchant as DM
import Domain.Types.MerchantOperatingCity (MerchantOperatingCity)
import Domain.Types.Person (Driver)
import qualified Domain.Types.SearchRequest as DSR
import qualified Domain.Types.SearchTry as DST
import qualified Domain.Types.TransporterConfig as DTC
import qualified Domain.Types.VehicleServiceTier as DVST
import EulerHS.Prelude hiding (id)
import Kernel.Storage.Esqueleto.Config (EsqDBReplicaFlow)
import qualified Kernel.Storage.Hedis as Redis
import Kernel.Types.Error
import Kernel.Types.Id
import Kernel.Utils.Common
import Lib.Queries.GateInfo
import qualified SharedLogic.Allocator.Jobs.SendSearchRequestToDrivers.Handle.Internal.DriverPool as SDP
import qualified SharedLogic.Beckn.Common as DTS
import SharedLogic.DriverPool
import qualified SharedLogic.External.LocationTrackingService.Types as LT
import Storage.Beam.Yudhishthira ()
import qualified Storage.Cac.TransporterConfig as SCTC
import qualified Storage.CachedQueries.Driver.GoHomeRequest as CQDGR
import qualified Storage.CachedQueries.Merchant as CQM
import qualified Storage.CachedQueries.ValueAddNP as CQVAN
import qualified Storage.CachedQueries.VehicleServiceTier as CQVST
import Tools.Maps as Maps

getNextDriverPoolBatch ::
  ( EncFlow m r,
    CacheFlow m r,
    EsqDBReplicaFlow m r,
    EsqDBFlow m r,
    LT.HasLocationService m r
  ) =>
  DriverPoolConfig ->
  DSR.SearchRequest ->
  DST.SearchTry ->
  [TripQuoteDetail] ->
  GoHomeConfig ->
  m DriverPoolWithActualDistResultWithFlags
getNextDriverPoolBatch driverPoolConfig searchReq searchTry tripQuoteDetails goHomeConfig = withLogTag "getNextDriverPoolBatch" do
  batchNum <- SDP.getPoolBatchNum searchTry.id
  SDP.incrementBatchNum searchTry.id
  cityServiceTiers <- CQVST.findAllByMerchantOpCityId searchReq.merchantOperatingCityId
  merchant <- CQM.findById searchReq.providerId >>= fromMaybeM (MerchantNotFound searchReq.providerId.getId)
  prepareDriverPoolBatch cityServiceTiers merchant driverPoolConfig searchReq searchTry tripQuoteDetails batchNum goHomeConfig

prepareDriverPoolBatch ::
  ( EncFlow m r,
    EsqDBReplicaFlow m r,
    EsqDBFlow m r,
    CacheFlow m r,
    LT.HasLocationService m r
  ) =>
  [DVST.VehicleServiceTier] ->
  DM.Merchant ->
  DriverPoolConfig ->
  DSR.SearchRequest ->
  DST.SearchTry ->
  [TripQuoteDetail] ->
  PoolBatchNum ->
  GoHomeConfig ->
  m DriverPoolWithActualDistResultWithFlags
prepareDriverPoolBatch cityServiceTiers merchant driverPoolCfg searchReq searchTry tripQuoteDetails startingbatchNum goHomeConfig = withLogTag ("startingbatchNum- (" <> show startingbatchNum <> ")") $ do
  isValueAddNP <- CQVAN.isValueAddNP searchReq.bapId
  previousBatchesDrivers <- getPreviousBatchesDrivers Nothing
  previousBatchesDriversOnRide <- getPreviousBatchesDrivers (Just True)
  let merchantOpCityId = searchReq.merchantOperatingCityId
  logDebug $ "PreviousBatchesDrivers-" <> show previousBatchesDrivers
  SDP.PrepareDriverPoolBatchEntity {..} <- prepareDriverPoolBatch' previousBatchesDrivers startingbatchNum merchantOpCityId searchReq.transactionId isValueAddNP
  let finalPool = currentDriverPoolBatch <> currentDriverPoolBatchOnRide
  SDP.incrementDriverRequestCount finalPool searchTry.id
  pure $ buildDriverPoolWithActualDistResultWithFlags finalPool poolType nextScheduleTime (previousBatchesDrivers <> previousBatchesDriversOnRide)
  where
    buildDriverPoolWithActualDistResultWithFlags finalPool poolType nextScheduleTime prevBatchDrivers =
      DriverPoolWithActualDistResultWithFlags
        { driverPoolWithActualDistResult = finalPool,
          poolType = poolType,
          prevBatchDrivers = prevBatchDrivers,
          nextScheduleTime = nextScheduleTime
        }
    getPreviousBatchesDrivers ::
      ( EncFlow m r,
        EsqDBReplicaFlow m r,
        EsqDBFlow m r,
        CacheFlow m r,
        LT.HasLocationService m r
      ) =>
      Maybe Bool ->
      m [Id Driver]
    getPreviousBatchesDrivers mbOnRide = do
      batches <- SDP.previouslyAttemptedDrivers searchTry.id mbOnRide
      return $ (.driverPoolResult.driverId) <$> batches

    prepareDriverPoolBatch' previousBatchesDrivers batchNum merchantOpCityId txnId isValueAddNP = withLogTag ("BatchNum - " <> show batchNum) $ do
      radiusStep <- SDP.getPoolRadiusStep searchTry.id
      transporterConfig <- SCTC.findByMerchantOpCityId merchantOpCityId Nothing >>= fromMaybeM (TransporterConfigDoesNotExist merchantOpCityId.getId)
      allDriversNotOnRide' <- calcDriverPool NormalPool radiusStep transporterConfig
      blockListedDriversForSearch <- Redis.withCrossAppRedis $ Redis.getList (mkBlockListedDriversKey searchReq.id)
      blockListedDriversForRider <- maybe (pure []) (Redis.withCrossAppRedis . Redis.getList . mkBlockListedDriversForRiderKey) searchReq.riderId
      let blockListedDrivers = blockListedDriversForSearch <> blockListedDriversForRider
          blockListedAndAlreadyAttemptedDrivers = blockListedDrivers <> previousBatchesDrivers
          onlyNewAndFilteredDrivers = filter (\dp -> dp.driverPoolResult.driverId `notElem` blockListedAndAlreadyAttemptedDrivers) allDriversNotOnRide'
          onlyNonBlockedDrivers = filter (\dp -> dp.driverPoolResult.driverId `notElem` blockListedDrivers) allDriversNotOnRide'

      (driverPoolNotOnRide, driverPoolOnRide) <- do
        case batchNum of
          -1 -> do
            gateTaggedDrivers <- assignDriverGateTags searchReq onlyNewAndFilteredDrivers
            goHomeTaggedDrivers <- assignDriverGoHomeTags gateTaggedDrivers searchReq searchTry tripQuoteDetails driverPoolCfg merchant goHomeConfig merchantOpCityId isValueAddNP transporterConfig
            driverPoolOnRide <- getDriverPoolOnRide merchantOpCityId transporterConfig radiusStep blockListedDrivers NormalPool
            return (goHomeTaggedDrivers, driverPoolOnRide)
          _ -> do
            allNearbyNonGoHomeDrivers <- filterM (\dpr -> (CQDGR.getDriverGoHomeRequestInfo dpr.driverPoolResult.driverId merchantOpCityId (Just goHomeConfig)) <&> (/= Just DDGR.ACTIVE) . (.status)) onlyNewAndFilteredDrivers
            calculateNormalBatch merchantOpCityId transporterConfig onlyNonBlockedDrivers radiusStep blockListedDrivers (bookAnyFilters transporterConfig allNearbyNonGoHomeDrivers previousBatchesDrivers) txnId
      cacheBatch driverPoolNotOnRide Nothing
      cacheBatch driverPoolOnRide (Just True)
      let (poolNotOnRide, poolOnRide) =
            if batchNum /= -1
              then
                ( addDistanceSplitConfigBasedDelaysForDriversWithinBatch driverPoolNotOnRide,
                  addDistanceSplitConfigBasedDelaysForOnRideDriversWithinBatch driverPoolOnRide
                )
              else (driverPoolNotOnRide, driverPoolOnRide)
      (poolWithSpecialZoneInfoNotOnRide, poolWithSpecialZoneInfoOnRide) <-
        if isJust searchReq.specialLocationTag
          then (,) <$> addSpecialZonePickupInfo poolNotOnRide <*> addSpecialZonePickupInfo poolOnRide
          else pure (poolNotOnRide, poolOnRide)
      pure $ SDP.PrepareDriverPoolBatchEntity poolWithSpecialZoneInfoNotOnRide NormalPool (bool Nothing (Just goHomeConfig.goHomeBatchDelay) (batchNum == (-1))) poolWithSpecialZoneInfoOnRide
      where
        addSpecialZonePickupInfo pool = do
          (driversFromGate, restDrivers) <- splitDriverFromGateAndRest pool
          pure $ restDrivers <> addSpecialZoneInfo searchReq.driverDefaultExtraFee driversFromGate

        splitDriverFromGateAndRest pool =
          case searchReq.pickupZoneGateId of
            Just pickupZoneGateId ->
              partitionM
                ( \dd -> do
                    mbDriverGate <- findGateInfoIfDriverInsideGatePickupZone (LatLong dd.driverPoolResult.lat dd.driverPoolResult.lon)
                    pure $ case mbDriverGate of
                      Just driverGate -> driverGate.id.getId == pickupZoneGateId
                      Nothing -> False
                )
                pool
            Nothing -> pure ([], pool)

        calcDriverPool poolType radiusStep transporterConfig = do
          now <- getCurrentTime
          let serviceTiers = tripQuoteDetails <&> (.vehicleServiceTier)
              merchantId = searchReq.providerId
              pickupLoc = searchReq.fromLocation
              pickupLatLong = LatLong pickupLoc.lat pickupLoc.lon
              dropLocation = searchReq.toLocation <&> (\loc -> LatLong loc.lat loc.lon)
              routeDistance = searchReq.estimatedDistance
              currentSearchInfo = DTS.CurrentSearchInfo {..}
              driverPoolReq =
                CalculateDriverPoolReq
                  { poolStage = DriverSelection,
                    pickup = pickupLatLong,
                    merchantOperatingCityId = merchantOpCityId,
                    mRadiusStep = Just radiusStep,
                    isRental = isRentalTrip searchTry.tripCategory,
                    isInterCity = isInterCityTrip searchTry.tripCategory,
                    onlinePayment = merchant.onlinePayment,
                    ..
                  }
          calculateDriverPoolWithActualDist driverPoolReq poolType currentSearchInfo

        calculateNormalBatch mOCityId transporterConfig normalDriverPool radiusStep blockListedDrivers onlyNewNormalDrivers txnId' = do
          logDebug $ "NormalDriverPool-" <> show normalDriverPool
          (normalBatchNotOnRide, normalBatchOnRide', mbRadiusThreshold) <- getDriverPoolNotOnRide mOCityId transporterConfig normalDriverPool radiusStep onlyNewNormalDrivers txnId'
          normalBatchOnRide <-
            case mbRadiusThreshold of
              Just radiusStepThreshold -> do
                getDriverPoolOnRide mOCityId transporterConfig radiusStepThreshold blockListedDrivers NormalPool
              Nothing -> pure normalBatchOnRide'
          pure (normalBatchNotOnRide, normalBatchOnRide)

        getDriverPoolNotOnRide mOCityId transporterConfig normalDriverPool radiusStep onlyNewNormalDrivers txnId' = do
          if length onlyNewNormalDrivers < batchSize && not (isAtMaxRadiusStep radiusStep)
            then do
              SDP.incrementPoolRadiusStep searchTry.id
              batchEntity <- prepareDriverPoolBatch' previousBatchesDrivers batchNum mOCityId txnId' isValueAddNP
              pure (batchEntity.currentDriverPoolBatch, batchEntity.currentDriverPoolBatchOnRide, Nothing)
            else do
              normalDriverPoolBatch <- mkDriverPoolBatch mOCityId onlyNewNormalDrivers transporterConfig batchSize False
              if length normalDriverPoolBatch < batchSize
                then do
                  filledBatch <- fillBatch transporterConfig normalDriverPool normalDriverPoolBatch
                  logDebug $ "FilledDriverPoolBatch-" <> show filledBatch
                  pure (filledBatch, [], Just radiusStep)
                else do
                  pure (normalDriverPoolBatch, [], Just radiusStep)

        filtersForNormalBatch mOCityId transporterConfig normalDriverPool blockListedDrivers previousBatchesDrivers' = do
          allNearbyNonGoHomeDrivers <- filterM (\dpr -> (CQDGR.getDriverGoHomeRequestInfo dpr.driverPoolResult.driverId mOCityId (Just goHomeConfig)) <&> (/= Just DDGR.ACTIVE) . (.status)) normalDriverPool
          let allNearbyDrivers = filter (\dpr -> dpr.driverPoolResult.driverId `notElem` blockListedDrivers) allNearbyNonGoHomeDrivers
          pure $ bookAnyFilters transporterConfig allNearbyDrivers previousBatchesDrivers'

        getDriverPoolOnRide mOCityId transporterConfig radiusStep blockListedDrivers poolType = do
          if poolType == NormalPool && driverPoolCfg.enableForwardBatching && searchTry.isAdvancedBookingEnabled
            then do
              previousDriverOnRide <- getPreviousBatchesDrivers (Just True)
              allNearbyDriversCurrentlyOnRide <- calcDriverCurrentlyOnRidePool poolType radiusStep transporterConfig batchNum
              logDebug $ "NormalDriverPoolBatchOnRideCurrentlyOnRide-" <> show allNearbyDriversCurrentlyOnRide
              onlyNewNormalDriversOnRide <- filtersForNormalBatch mOCityId transporterConfig allNearbyDriversCurrentlyOnRide blockListedDrivers previousDriverOnRide
              normalDriverPoolBatchOnRide <- mkDriverPoolBatch mOCityId onlyNewNormalDriversOnRide transporterConfig batchSizeOnRide True
              validDriversFromPreviousBatch <-
                filterM
                  ( \dpr -> do
                      isHasValidRequests <- SDP.checkRequestCount searchTry.id (SDP.isBookAny $ tripQuoteDetails <&> (.vehicleServiceTier)) dpr.driverPoolResult.driverId dpr.driverPoolResult.serviceTier dpr.driverPoolResult.serviceTierDowngradeLevel driverPoolCfg
                      let isPreviousBatchDriver = dpr.driverPoolResult.driverId `elem` previousDriverOnRide
                      return $ isHasValidRequests && isPreviousBatchDriver
                  )
                  allNearbyDriversCurrentlyOnRide
              logDebug $ "NormalDriverPoolBatchOnRide-" <> show normalDriverPoolBatchOnRide
              logDebug $ "ValidDriversFromPreviousBatchOnRide-" <> show validDriversFromPreviousBatch
              let finalBatchOnRide = take batchSizeOnRide $ normalDriverPoolBatchOnRide <> validDriversFromPreviousBatch
              pure finalBatchOnRide
            else pure []

        bookAnyFilters transporterConfig allNearbyDrivers previousBatchesDrivers' = do
          let onlyNewNormalDriversWithMultipleSeriveTier = filter (\dpr -> dpr.driverPoolResult.driverId `notElem` previousBatchesDrivers') allNearbyDrivers
          if SDP.isBookAny (tripQuoteDetails <&> (.vehicleServiceTier))
            then do selectMinDowngrade transporterConfig.bookAnyVehicleDowngradeLevel onlyNewNormalDriversWithMultipleSeriveTier
            else do onlyNewNormalDriversWithMultipleSeriveTier

        -- This function takes a list of DriverPoolWithActualDistResult and returns a list with unique driverId entries with the minimum serviceTierDowngradeLevel.
        selectMinDowngrade :: Int -> [DriverPoolWithActualDistResult] -> [DriverPoolWithActualDistResult]
        selectMinDowngrade config results = Map.elems $ foldr insertOrUpdate Map.empty filtered
          where
            insertOrUpdate :: DriverPoolWithActualDistResult -> Map.Map Text DriverPoolWithActualDistResult -> Map.Map Text DriverPoolWithActualDistResult
            insertOrUpdate result currentMap =
              let driver = result.driverPoolResult
                  key = driver.driverId.getId
               in Map.insertWith minByDowngradeLevel key result currentMap

            minByDowngradeLevel :: DriverPoolWithActualDistResult -> DriverPoolWithActualDistResult -> DriverPoolWithActualDistResult
            minByDowngradeLevel new old =
              if new.driverPoolResult.serviceTierDowngradeLevel < old.driverPoolResult.serviceTierDowngradeLevel
                then new
                else old

            filtered = filter (\d -> d.driverPoolResult.serviceTierDowngradeLevel >= config) results

        mkDriverPoolBatch mOCityId onlyNewDrivers transporterConfig batchSize' isOnRidePool = do
          case sortingType of
            _ -> SDP.makeTaggedDriverPool mOCityId transporterConfig.timeDiffFromUtc searchReq onlyNewDrivers batchSize' isOnRidePool searchReq.customerNammaTags

        addDistanceSplitConfigBasedDelaysForDriversWithinBatch filledPoolBatch =
          fst $
            foldl'
              ( \(finalBatch, restBatch) splitConfig -> do
                  let (splitToAddDelay, newRestBatch) = splitAt splitConfig.batchSplitSize restBatch
                      splitWithDelay = map (\driverWithDistance -> driverWithDistance {keepHiddenForSeconds = splitConfig.batchSplitDelay}) splitToAddDelay
                  (finalBatch <> splitWithDelay, newRestBatch)
              )
              ([], filledPoolBatch)
              driverPoolCfg.distanceBasedBatchSplit

        addDistanceSplitConfigBasedDelaysForOnRideDriversWithinBatch filledPoolBatch =
          fst $
            foldl'
              ( \(finalBatch, restBatch) splitConfig -> do
                  let (splitToAddDelay, newRestBatch) = splitAt splitConfig.batchSplitSize restBatch
                      splitWithDelay = map (\driverWithDistance -> driverWithDistance {keepHiddenForSeconds = splitConfig.batchSplitDelay}) splitToAddDelay
                  (finalBatch <> splitWithDelay, newRestBatch)
              )
              ([], filledPoolBatch)
              driverPoolCfg.onRideBatchSplitConfig

        calcDriverCurrentlyOnRidePool poolType radiusStep transporterConfig batchNum' = do
          let merchantId = searchReq.providerId
          now <- getCurrentTime
          if transporterConfig.includeDriverCurrentlyOnRide && driverPoolCfg.enableForwardBatching && radiusStep > 0
            then do
              let serviceTiers = tripQuoteDetails <&> (.vehicleServiceTier)
              let pickupLoc = searchReq.fromLocation
              let pickupLatLong = LatLong pickupLoc.lat pickupLoc.lon
              let dropLocation = searchReq.toLocation <&> (\loc -> LatLong loc.lat loc.lon)
                  routeDistance = searchReq.estimatedDistance
              let currentSearchInfo = DTS.CurrentSearchInfo {..}
              let driverPoolReq =
                    CalculateDriverPoolReq
                      { poolStage = DriverSelection,
                        pickup = pickupLatLong,
                        merchantOperatingCityId = merchantOpCityId,
                        mRadiusStep = Just radiusStep,
                        isRental = isRentalTrip searchTry.tripCategory,
                        isInterCity = isInterCityTrip searchTry.tripCategory,
                        onlinePayment = merchant.onlinePayment,
                        ..
                      }
              calculateDriverCurrentlyOnRideWithActualDist driverPoolReq poolType (toInteger batchNum') currentSearchInfo
            else pure []

        fillBatch transporterConfig allNearbyDrivers batch = do
          let batchDriverIds = batch <&> (.driverPoolResult.driverId)
          let driversNotInBatch = filter (\dpr -> dpr.driverPoolResult.driverId `notElem` batchDriverIds) allNearbyDrivers
          driversWithValidReqAmount <- filterM (\dpr -> SDP.checkRequestCount searchTry.id (SDP.isBookAny $ tripQuoteDetails <&> (.vehicleServiceTier)) dpr.driverPoolResult.driverId dpr.driverPoolResult.serviceTier dpr.driverPoolResult.serviceTierDowngradeLevel driverPoolCfg) driversNotInBatch
          nonGoHomeDriversWithValidReqCount <- filterM (\dpr -> (CQDGR.getDriverGoHomeRequestInfo dpr.driverPoolResult.driverId merchantOpCityId (Just goHomeConfig)) <&> (/= Just DDGR.ACTIVE) . (.status)) driversWithValidReqAmount
          let nonGoHomeNormalDriversWithValidReqCountWithServiceTier =
                if SDP.isBookAny (tripQuoteDetails <&> (.vehicleServiceTier))
                  then do selectMinDowngrade transporterConfig.bookAnyVehicleDowngradeLevel nonGoHomeDriversWithValidReqCount
                  else do nonGoHomeDriversWithValidReqCount
          let fillSize = batchSize - length batch
          (batch <>)
            <$> case sortingType of
              _ -> SDP.makeTaggedDriverPool merchantOpCityId transporterConfig.timeDiffFromUtc searchReq nonGoHomeNormalDriversWithValidReqCountWithServiceTier fillSize False searchReq.customerNammaTags -- TODO: Fix isOnRidePool flag
        cacheBatch batch consideOnRideDrivers = do
          logDebug $ "Caching batch-" <> show batch
          batches <- SDP.previouslyAttemptedDrivers searchTry.id consideOnRideDrivers
          Redis.withCrossAppRedis $ Redis.setExp (SDP.previouslyAttemptedDriversKey searchTry.id consideOnRideDrivers) (batches <> batch) (60 * 30)

        isAtMaxRadiusStep radiusStep = do
          let minRadiusOfSearch = fromIntegral @_ @Double driverPoolCfg.minRadiusOfSearch
          let maxRadiusOfSearch = fromIntegral @_ @Double driverPoolCfg.maxRadiusOfSearch
          let radiusStepSize = fromIntegral @_ @Double driverPoolCfg.radiusStepSize
          let maxRadiusStep = ceiling $ (maxRadiusOfSearch - minRadiusOfSearch) / radiusStepSize
          maxRadiusStep <= radiusStep
        -- util function

        sortingType = driverPoolCfg.poolSortingType
        batchSize = driverPoolCfg.driverBatchSize
        batchSizeOnRide = driverPoolCfg.batchSizeOnRide

assignDriverGateTags ::
  ( EncFlow m r,
    EsqDBReplicaFlow m r,
    EsqDBFlow m r,
    CacheFlow m r,
    LT.HasLocationService m r
  ) =>
  DSR.SearchRequest ->
  [DriverPoolWithActualDistResult] ->
  m [DriverPoolWithActualDistResult]
assignDriverGateTags searchReq pool = do
  case searchReq.pickupZoneGateId of
    Just pickupZoneGateId -> do
      (onGateDrivers', outSideDrivers) <-
        partitionM
          ( \dd -> do
              mbDriverGate <- findGateInfoIfDriverInsideGatePickupZone (LatLong dd.driverPoolResult.lat dd.driverPoolResult.lon)
              pure $ case mbDriverGate of
                Just driverGate -> driverGate.id.getId == pickupZoneGateId
                Nothing -> False
          )
          pool
      let onGateDrivers'' =
            map
              ( \(dp :: DriverPoolWithActualDistResult) ->
                  let dpResult = dp.driverPoolResult
                      updatedTags = insertInObject dpResult.driverTags [SpecialZoneQueueDriver]
                      dprWithTags = (dpResult :: DriverPoolResult) {driverTags = updatedTags}
                   in dp {driverPoolResult = dprWithTags}
              )
              onGateDrivers'
          onGateDrivers = addSpecialZoneInfo searchReq.driverDefaultExtraFee onGateDrivers''
      return $ onGateDrivers <> outSideDrivers
    Nothing -> return pool

addSpecialZoneInfo :: Maybe HighPrecMoney -> [DriverPoolWithActualDistResult] -> [DriverPoolWithActualDistResult]
addSpecialZoneInfo driverDefaultExtraFee = map (\driverWithDistance -> driverWithDistance {pickupZone = True, specialZoneExtraTip = driverDefaultExtraFee})

assignDriverGoHomeTags ::
  ( EncFlow m r,
    EsqDBReplicaFlow m r,
    EsqDBFlow m r,
    CacheFlow m r,
    LT.HasLocationService m r
  ) =>
  [DriverPoolWithActualDistResult] ->
  DSR.SearchRequest ->
  DST.SearchTry ->
  [TripQuoteDetail] ->
  DriverPoolConfig ->
  DM.Merchant ->
  GoHomeConfig ->
  Id MerchantOperatingCity ->
  Bool ->
  DTC.TransporterConfig ->
  m [DriverPoolWithActualDistResult]
assignDriverGoHomeTags pool searchReq searchTry tripQuoteDetails driverPoolCfg merchant goHomeConfig merchantOpCityId isValueAddNP transporterConfig = do
  (goHomeDriversInQueue, goHomeDriversNotToDestination) <-
    case searchReq.toLocation of
      Just toLoc | isGoHomeAvailable searchTry.tripCategory -> do
        let dropLocation = searchReq.toLocation <&> (\loc -> LatLong loc.lat loc.lon)
            routeDistance = searchReq.estimatedDistance
        let currentSearchInfo = DTS.CurrentSearchInfo {..}
        let goHomeReq =
              CalculateGoHomeDriverPoolReq
                { poolStage = DriverSelection,
                  driverPoolCfg = driverPoolCfg,
                  goHomeCfg = goHomeConfig,
                  serviceTiers = tripQuoteDetails <&> (.vehicleServiceTier),
                  fromLocation = searchReq.fromLocation,
                  toLocation = toLoc, -- last or all ?
                  merchantId = searchReq.providerId,
                  isRental = isRentalTrip searchTry.tripCategory,
                  isInterCity = isInterCityTrip searchTry.tripCategory,
                  onlinePayment = merchant.onlinePayment,
                  ..
                }
        filterOutGoHomeDriversAccordingToHomeLocation (map (convertDriverPoolWithActualDistResultToNearestGoHomeDriversResult False) pool) goHomeReq merchantOpCityId
      _ -> pure ([], [])
  let goHomeDriversToDestionation = map (\dp -> dp.driverPoolResult.driverId) goHomeDriversInQueue
      goHomePool' = assignGoHomeTags goHomeDriversToDestionation GoHomeDriverToDestination pool
  return $ assignGoHomeTags goHomeDriversNotToDestination GoHomeDriverNotToDestination goHomePool'
  where
    assignGoHomeTags goHomeDrivers driverTag =
      map
        ( \dp ->
            if dp.driverPoolResult.driverId `elem` goHomeDrivers
              then
                dp
                  { driverPoolResult =
                      (driverPoolResult dp :: DriverPoolResult)
                        { driverTags =
                            insertInObject
                              (((driverTags :: DriverPoolResult -> Value) . (driverPoolResult)) dp)
                              [driverTag]
                        }
                  }
              else dp
        )

insertInObject :: Value -> [DriverPoolTags] -> Value
insertInObject obj tags =
  case obj of
    Object keymap -> Object $ DL.foldl' (\acc key -> AKM.insert ((AK.fromString . show) key) (toJSON True) acc) keymap tags
    _ -> Object $ DL.foldl' (\acc key -> AKM.insert ((AK.fromString . show) key) (toJSON True) acc) AKM.empty tags