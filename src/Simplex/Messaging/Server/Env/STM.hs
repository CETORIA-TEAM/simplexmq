{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.Env.STM where

import Control.Concurrent (ThreadId)
import Control.Monad.IO.Unlift
import qualified Crypto.PubKey.RSA as R
import Crypto.Random
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Network.Socket (ServiceName)
import Numeric.Natural
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.QueueStore.STM
import UnliftIO.STM

data ServerConfig = ServerConfig
  { tcpPort :: ServiceName,
    tbqSize :: Natural,
    queueIdBytes :: Int,
    msgIdBytes :: Int
  }

data Env = Env
  { config :: ServerConfig,
    server :: Server,
    queueStore :: QueueStore,
    msgStore :: STMMsgStore,
    idsDrg :: TVar ChaChaDRG,
    serverKeyPair :: C.KeyPair
    -- serverId :: ByteString
  }

data Server = Server
  { subscribedQ :: TBQueue (RecipientId, Client),
    subscribers :: TVar (Map RecipientId Client)
  }

data Client = Client
  { subscriptions :: TVar (Map RecipientId Sub),
    rcvQ :: TBQueue Transmission,
    sndQ :: TBQueue Transmission
  }

data SubscriptionThread = NoSub | SubPending | SubThread ThreadId

data Sub = Sub
  { subThread :: SubscriptionThread,
    delivered :: TMVar ()
  }

newServer :: Natural -> STM Server
newServer qSize = do
  subscribedQ <- newTBQueue qSize
  subscribers <- newTVar M.empty
  return Server {subscribedQ, subscribers}

newClient :: Natural -> STM Client
newClient qSize = do
  subscriptions <- newTVar M.empty
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  return Client {subscriptions, rcvQ, sndQ}

newSubscription :: STM Sub
newSubscription = do
  delivered <- newEmptyTMVar
  return Sub {subThread = NoSub, delivered}

newEnv :: (MonadUnliftIO m, MonadRandom m) => ServerConfig -> m Env
newEnv config = do
  server <- atomically $ newServer (tbqSize config)
  queueStore <- atomically newQueueStore
  msgStore <- atomically newMsgStore
  idsDrg <- drgNew >>= newTVarIO
  -- TODO these keys should be set in the environment, not in the code
  return Env {config, server, queueStore, msgStore, idsDrg, serverKeyPair}
  where
    serverKeyPair =
      ( C.PublicKey
          { rsaPublicKey =
              R.PublicKey
                { public_size = 256,
                  public_n = 24491401566218566997383105010202223087300892576089255259580984651333137614713737618097624532507176450266480395052797332730303098565954279378701980313049999952643146946493842983667770915603693980339519205455913124235423278419181501399080069195664300809453039371169996023512911587381435574254546266774756319955237750224266282550919563293672568339958353047135257914364920805066749904289452712976534358633568668875150094910205741579097517675339029147403213185924413178887675432745168542469043448659751499651038006514754218441022754807971535895895877162103157702709155894482782232155817331812261258282431796597840952464257,
                  public_e = 8750208418393523480444709183090020123776537336553019181250117771363000810675051423462439348759073000328325050011503730211252469588880505946970399702607609166796825215104414212088697348613726705621594590369250976359268097976909710311654938358716518878047036682173044667792903503207106314854901036618348367397
                }
          },
        C.PrivateKey
          { private_size = 256,
            private_n = 24491401566218566997383105010202223087300892576089255259580984651333137614713737618097624532507176450266480395052797332730303098565954279378701980313049999952643146946493842983667770915603693980339519205455913124235423278419181501399080069195664300809453039371169996023512911587381435574254546266774756319955237750224266282550919563293672568339958353047135257914364920805066749904289452712976534358633568668875150094910205741579097517675339029147403213185924413178887675432745168542469043448659751499651038006514754218441022754807971535895895877162103157702709155894482782232155817331812261258282431796597840952464257,
            private_d = 7597313014691047671352664508683652467940113991200105893460705315744177757772923044415828427601194535604492873282390112577565179730319668643740113323630387082584239892956534048712048059175569855278723311295064858148623887611800385925820852572241607131360121661598015161261779381845187797044113149447495567589968956065009916550602209418325870594974390014927949966324558614396231902374868077411836997835082564279358230227298823445650053370542685308691044175390251929540772677009245507450972026595993054141350350385685400540681305852935721245601287301749047921282924410369389293829570448007237832101875085500166095784749
          }
      )

-- public key hash:
-- "8Cvd+AYVxLpSsB/glEhVxkKuEzMNBFdAL5yr7p9DGGk="
