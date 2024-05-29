{-# OPTIONS_GHC -Wno-dodgy-exports #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}

module Storage.Queries.Merchant (module Storage.Queries.Merchant, module ReExport) where

import qualified Domain.Types.Merchant
import Kernel.Beam.Functions
import Kernel.External.Encryption
import Kernel.Prelude
import qualified Kernel.Prelude
import Kernel.Types.Error
import qualified Kernel.Types.Geofencing
import qualified Kernel.Types.Id
import Kernel.Utils.Common (CacheFlow, EsqDBFlow, MonadFlow, fromMaybeM, getCurrentTime)
import qualified Sequelize as Se
import qualified Storage.Beam.Merchant as Beam
import Storage.Queries.MerchantExtra as ReExport

create :: (EsqDBFlow m r, MonadFlow m, CacheFlow m r) => (Domain.Types.Merchant.Merchant -> m ())
create = createWithKV

createMany :: (EsqDBFlow m r, MonadFlow m, CacheFlow m r) => ([Domain.Types.Merchant.Merchant] -> m ())
createMany = traverse_ create

findById :: (EsqDBFlow m r, MonadFlow m, CacheFlow m r) => (Kernel.Types.Id.Id Domain.Types.Merchant.Merchant -> m (Maybe Domain.Types.Merchant.Merchant))
findById (Kernel.Types.Id.Id id) = do findOneWithKV [Se.Is Beam.id $ Se.Eq id]

findByShortId :: (EsqDBFlow m r, MonadFlow m, CacheFlow m r) => (Kernel.Types.Id.ShortId Domain.Types.Merchant.Merchant -> m (Maybe Domain.Types.Merchant.Merchant))
findByShortId (Kernel.Types.Id.ShortId shortId) = do findOneWithKV [Se.Is Beam.shortId $ Se.Eq shortId]

findBySubscriberId :: (EsqDBFlow m r, MonadFlow m, CacheFlow m r) => (Kernel.Types.Id.ShortId Domain.Types.Merchant.Subscriber -> m (Maybe Domain.Types.Merchant.Merchant))
findBySubscriberId (Kernel.Types.Id.ShortId subscriberId) = do findOneWithKV [Se.Is Beam.subscriberId $ Se.Eq subscriberId]

findByPrimaryKey :: (EsqDBFlow m r, MonadFlow m, CacheFlow m r) => (Kernel.Types.Id.Id Domain.Types.Merchant.Merchant -> m (Maybe Domain.Types.Merchant.Merchant))
findByPrimaryKey (Kernel.Types.Id.Id id) = do findOneWithKV [Se.And [Se.Is Beam.id $ Se.Eq id]]

updateByPrimaryKey :: (EsqDBFlow m r, MonadFlow m, CacheFlow m r) => (Domain.Types.Merchant.Merchant -> m ())
updateByPrimaryKey (Domain.Types.Merchant.Merchant {..}) = do
  _now <- getCurrentTime
  updateWithKV
    [ Se.Set Beam.city city,
      Se.Set Beam.country country,
      Se.Set Beam.createdAt createdAt,
      Se.Set Beam.description description,
      Se.Set Beam.enabled enabled,
      Se.Set Beam.fromTime fromTime,
      Se.Set Beam.geoHashPrecisionValue geoHashPrecisionValue,
      Se.Set Beam.destinationRestriction (Kernel.Types.Geofencing.destination geofencingConfig),
      Se.Set Beam.originRestriction (Kernel.Types.Geofencing.origin geofencingConfig),
      Se.Set Beam.gstin gstin,
      Se.Set Beam.headCount headCount,
      Se.Set Beam.info info,
      Se.Set Beam.internalApiKey internalApiKey,
      Se.Set Beam.minimumDriverRatesCount minimumDriverRatesCount,
      Se.Set Beam.mobileCountryCode mobileCountryCode,
      Se.Set Beam.mobileNumber mobileNumber,
      Se.Set Beam.name name,
      Se.Set Beam.registryUrl (Kernel.Prelude.showBaseUrl registryUrl),
      Se.Set Beam.shortId (Kernel.Types.Id.getShortId shortId),
      Se.Set Beam.state state,
      Se.Set Beam.status status,
      Se.Set Beam.subscriberId (Kernel.Types.Id.getShortId subscriberId),
      Se.Set Beam.toTime toTime,
      Se.Set Beam.uniqueKeyId uniqueKeyId,
      Se.Set Beam.updatedAt _now,
      Se.Set Beam.verified verified
    ]
    [Se.And [Se.Is Beam.id $ Se.Eq (Kernel.Types.Id.getId id)]]