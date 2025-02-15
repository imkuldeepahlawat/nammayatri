{-
 
  Copyright 2022-23, Juspay India Pvt Ltd
 
  This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License
 
  as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. This program
 
  is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 
  or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details. You should have received a copy of
 
  the GNU Affero General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.
-}

module Screens.FaqScreen.ScreenData where

import Screens.Types
import Common.Types.App 
import ConfigProvider
import Data.Maybe(Maybe(..))
import MerchantConfig.Types (AppConfig)

initData :: FaqScreenState
initData = {
  data: {
    config : getAppConfig appConfig,
    dropDownList : [],
    issueListType : HELP_AND_SUPPORT_SCREEN_MODAL,
    categories : [],
    categoryName : "",
    maxAllowedRideAge : Nothing
  },
  props:{
    apiFailure : false,
    needIssueListApiCall : true
  }

}


