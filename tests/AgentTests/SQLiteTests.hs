{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}

module AgentTests.SQLiteTests (storeTests) where

import Control.Concurrent.Async (concurrently_)
import Control.Monad (replicateM_)
import Control.Monad.Except (ExceptT, runExceptT)
import qualified Crypto.PubKey.RSA as R
import Data.ByteString.Char8 (ByteString)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time
import Data.Word (Word32)
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import SMPClient (testKeyHash)
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Crypto as C
import System.Random (Random (randomIO))
import Test.Hspec
import UnliftIO.Directory (removeFile)

testDB :: String
testDB = "tests/tmp/smp-agent.test.db"

withStore :: SpecWith SQLiteStore -> Spec
withStore = before createStore . after removeStore

withStore2 :: SpecWith (SQLiteStore, SQLiteStore) -> Spec
withStore2 = before connect2 . after (removeStore . fst)
  where
    connect2 :: IO (SQLiteStore, SQLiteStore)
    connect2 = do
      s1 <- createStore
      s2 <- connectSQLiteStore $ dbFilePath s1
      pure (s1, s2)

createStore :: IO SQLiteStore
createStore = do
  -- Randomize DB file name to avoid SQLite IO errors supposedly caused by asynchronous
  -- IO operations on multiple similarly named files; error seems to be environment specific
  r <- randomIO :: IO Word32
  createSQLiteStore $ testDB <> show r

removeStore :: SQLiteStore -> IO ()
removeStore store = do
  DB.close $ dbConn store
  removeFile $ dbFilePath store

returnsResult :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> a -> Expectation
action `returnsResult` r = runExceptT action `shouldReturn` Right r

throwsError :: (Eq a, Eq e, Show a, Show e) => ExceptT e IO a -> e -> Expectation
action `throwsError` e = runExceptT action `shouldReturn` Left e

-- TODO add null port tests
storeTests :: Spec
storeTests = do
  withStore2 do
    describe "stress test" testConcurrentWrites
  withStore do
    describe "store setup" do
      testCompiledThreadsafe
      testForeignKeysEnabled
    describe "store methods" do
      describe "Queue and Connection management" do
        describe "createRcvConn" do
          testCreateRcvConn
          testCreateRcvConnDuplicate
        describe "createSndConn" do
          testCreateSndConn
          testCreateSndConnDuplicate
        describe "getAllConnAliases" testGetAllConnAliases
        describe "getRcvConn" testGetRcvConn
        describe "deleteConn" do
          testDeleteRcvConn
          testDeleteSndConn
          testDeleteDuplexConn
        describe "upgradeRcvConnToDuplex" do
          testUpgradeRcvConnToDuplex
        describe "upgradeSndConnToDuplex" do
          testUpgradeSndConnToDuplex
        describe "set Queue status" do
          describe "setRcvQueueStatus" do
            testSetRcvQueueStatus
            testSetRcvQueueStatusNoQueue
          describe "setSndQueueStatus" do
            testSetSndQueueStatus
            testSetSndQueueStatusNoQueue
          testSetQueueStatusDuplex
      describe "Msg management" do
        describe "create Msg" do
          testCreateRcvMsg
          testCreateSndMsg
          testCreateRcvAndSndMsgs

testConcurrentWrites :: SpecWith (SQLiteStore, SQLiteStore)
testConcurrentWrites =
  it "should complete multiple concurrent write transactions w/t sqlite busy errors" $ \(s1, s2) -> do
    _ <- runExceptT $ createRcvConn s1 rcvQueue1
    concurrently_ (runTest s1) (runTest s2)
  where
    runTest :: SQLiteStore -> IO (Either StoreError ())
    runTest store = runExceptT . replicateM_ 100 $ do
      (internalId, internalRcvId, _, _) <- updateRcvIds store rcvQueue1
      let rcvMsgData = mkRcvMsgData internalId internalRcvId 0 "0" "hash_dummy"
      createRcvMsg store rcvQueue1 rcvMsgData

testCompiledThreadsafe :: SpecWith SQLiteStore
testCompiledThreadsafe =
  it "compiled sqlite library should be threadsafe" $ \store -> do
    compileOptions <- DB.query_ (dbConn store) "pragma COMPILE_OPTIONS;" :: IO [[T.Text]]
    compileOptions `shouldNotContain` [["THREADSAFE=0"]]

testForeignKeysEnabled :: SpecWith SQLiteStore
testForeignKeysEnabled =
  it "foreign keys should be enabled" $ \store -> do
    let inconsistentQuery =
          [sql|
            INSERT INTO connections
              (conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id)
            VALUES
              ("conn1", "smp.simplex.im", "5223", "1234", "smp.simplex.im", "5223", "2345");
          |]
    DB.execute_ (dbConn store) inconsistentQuery
      `shouldThrow` (\e -> DB.sqlError e == DB.ErrorConstraint)

rcvQueue1 :: RcvQueue
rcvQueue1 =
  RcvQueue
    { server = SMPServer "smp.simplex.im" (Just "5223") testKeyHash,
      rcvId = "1234",
      connAlias = "conn1",
      rcvPrivateKey = C.safePrivateKey (1, 2, 3),
      sndId = Just "2345",
      sndKey = Nothing,
      decryptKey = C.safePrivateKey (1, 2, 3),
      verifyKey = Nothing,
      status = New
    }

sndQueue1 :: SndQueue
sndQueue1 =
  SndQueue
    { server = SMPServer "smp.simplex.im" (Just "5223") testKeyHash,
      sndId = "3456",
      connAlias = "conn1",
      sndPrivateKey = C.safePrivateKey (1, 2, 3),
      encryptKey = C.PublicKey $ R.PublicKey 1 2 3,
      signKey = C.safePrivateKey (1, 2, 3),
      status = New
    }

testCreateRcvConn :: SpecWith SQLiteStore
testCreateRcvConn =
  it "should create RcvConnection and add SndQueue" $ \store -> do
    createRcvConn store rcvQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection "conn1" rcvQueue1)
    upgradeRcvConnToDuplex store "conn1" sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 sndQueue1)

testCreateRcvConnDuplicate :: SpecWith SQLiteStore
testCreateRcvConnDuplicate =
  it "should throw error on attempt to create duplicate RcvConnection" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    createRcvConn store rcvQueue1
      `throwsError` SEConnDuplicate

testCreateSndConn :: SpecWith SQLiteStore
testCreateSndConn =
  it "should create SndConnection and add RcvQueue" $ \store -> do
    createSndConn store sndQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection "conn1" sndQueue1)
    upgradeSndConnToDuplex store "conn1" rcvQueue1
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 sndQueue1)

testCreateSndConnDuplicate :: SpecWith SQLiteStore
testCreateSndConnDuplicate =
  it "should throw error on attempt to create duplicate SndConnection" $ \store -> do
    _ <- runExceptT $ createSndConn store sndQueue1
    createSndConn store sndQueue1
      `throwsError` SEConnDuplicate

testGetAllConnAliases :: SpecWith SQLiteStore
testGetAllConnAliases =
  it "should get all conn aliases" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    _ <- runExceptT $ createSndConn store sndQueue1 {connAlias = "conn2"}
    getAllConnAliases store
      `returnsResult` ["conn1" :: ConnAlias, "conn2" :: ConnAlias]

testGetRcvConn :: SpecWith SQLiteStore
testGetRcvConn =
  it "should get connection using rcv queue id and server" $ \store -> do
    let smpServer = SMPServer "smp.simplex.im" (Just "5223") testKeyHash
    let recipientId = "1234"
    _ <- runExceptT $ createRcvConn store rcvQueue1
    getRcvConn store smpServer recipientId
      `returnsResult` SomeConn SCRcv (RcvConnection (connAlias (rcvQueue1 :: RcvQueue)) rcvQueue1)

testDeleteRcvConn :: SpecWith SQLiteStore
testDeleteRcvConn =
  it "should create RcvConnection and delete it" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection "conn1" rcvQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testDeleteSndConn :: SpecWith SQLiteStore
testDeleteSndConn =
  it "should create SndConnection and delete it" $ \store -> do
    _ <- runExceptT $ createSndConn store sndQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection "conn1" sndQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testDeleteDuplexConn :: SpecWith SQLiteStore
testDeleteDuplexConn =
  it "should create DuplexConnection and delete it" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    _ <- runExceptT $ upgradeRcvConnToDuplex store "conn1" sndQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 sndQueue1)
    deleteConn store "conn1"
      `returnsResult` ()
    -- TODO check queues are deleted as well
    getConn store "conn1"
      `throwsError` SEConnNotFound

testUpgradeRcvConnToDuplex :: SpecWith SQLiteStore
testUpgradeRcvConnToDuplex =
  it "should throw error on attempt to add SndQueue to SndConnection or DuplexConnection" $ \store -> do
    _ <- runExceptT $ createSndConn store sndQueue1
    let anotherSndQueue =
          SndQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") testKeyHash,
              sndId = "2345",
              connAlias = "conn1",
              sndPrivateKey = C.safePrivateKey (1, 2, 3),
              encryptKey = C.PublicKey $ R.PublicKey 1 2 3,
              signKey = C.safePrivateKey (1, 2, 3),
              status = New
            }
    upgradeRcvConnToDuplex store "conn1" anotherSndQueue
      `throwsError` SEBadConnType CSnd
    _ <- runExceptT $ upgradeSndConnToDuplex store "conn1" rcvQueue1
    upgradeRcvConnToDuplex store "conn1" anotherSndQueue
      `throwsError` SEBadConnType CDuplex

testUpgradeSndConnToDuplex :: SpecWith SQLiteStore
testUpgradeSndConnToDuplex =
  it "should throw error on attempt to add RcvQueue to RcvConnection or DuplexConnection" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    let anotherRcvQueue =
          RcvQueue
            { server = SMPServer "smp.simplex.im" (Just "5223") testKeyHash,
              rcvId = "3456",
              connAlias = "conn1",
              rcvPrivateKey = C.safePrivateKey (1, 2, 3),
              sndId = Just "4567",
              sndKey = Nothing,
              decryptKey = C.safePrivateKey (1, 2, 3),
              verifyKey = Nothing,
              status = New
            }
    upgradeSndConnToDuplex store "conn1" anotherRcvQueue
      `throwsError` SEBadConnType CRcv
    _ <- runExceptT $ upgradeRcvConnToDuplex store "conn1" sndQueue1
    upgradeSndConnToDuplex store "conn1" anotherRcvQueue
      `throwsError` SEBadConnType CDuplex

testSetRcvQueueStatus :: SpecWith SQLiteStore
testSetRcvQueueStatus =
  it "should update status of RcvQueue" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection "conn1" rcvQueue1)
    setRcvQueueStatus store rcvQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCRcv (RcvConnection "conn1" rcvQueue1 {status = Confirmed})

testSetSndQueueStatus :: SpecWith SQLiteStore
testSetSndQueueStatus =
  it "should update status of SndQueue" $ \store -> do
    _ <- runExceptT $ createSndConn store sndQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection "conn1" sndQueue1)
    setSndQueueStatus store sndQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCSnd (SndConnection "conn1" sndQueue1 {status = Confirmed})

testSetQueueStatusDuplex :: SpecWith SQLiteStore
testSetQueueStatusDuplex =
  it "should update statuses of RcvQueue and SndQueue in DuplexConnection" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    _ <- runExceptT $ upgradeRcvConnToDuplex store "conn1" sndQueue1
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 sndQueue1)
    setRcvQueueStatus store rcvQueue1 Secured
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 {status = Secured} sndQueue1)
    setSndQueueStatus store sndQueue1 Confirmed
      `returnsResult` ()
    getConn store "conn1"
      `returnsResult` SomeConn SCDuplex (DuplexConnection "conn1" rcvQueue1 {status = Secured} sndQueue1 {status = Confirmed})

testSetRcvQueueStatusNoQueue :: SpecWith SQLiteStore
testSetRcvQueueStatusNoQueue =
  xit "should throw error on attempt to update status of non-existent RcvQueue" $ \store -> do
    setRcvQueueStatus store rcvQueue1 Confirmed
      `throwsError` SEConnNotFound

testSetSndQueueStatusNoQueue :: SpecWith SQLiteStore
testSetSndQueueStatusNoQueue =
  xit "should throw error on attempt to update status of non-existent SndQueue" $ \store -> do
    setSndQueueStatus store sndQueue1 Confirmed
      `throwsError` SEConnNotFound

hw :: ByteString
hw = encodeUtf8 "Hello world!"

ts :: UTCTime
ts = UTCTime (fromGregorian 2021 02 24) (secondsToDiffTime 0)

mkRcvMsgData :: InternalId -> InternalRcvId -> ExternalSndId -> BrokerId -> MsgHash -> RcvMsgData
mkRcvMsgData internalId internalRcvId externalSndId brokerId internalHash =
  RcvMsgData
    { internalId,
      internalRcvId,
      internalTs = ts,
      senderMeta = (externalSndId, ts),
      brokerMeta = (brokerId, ts),
      msgBody = hw,
      internalHash,
      externalPrevSndHash = "hash_from_sender",
      msgIntegrity = MsgOk
    }

testCreateRcvMsg' :: SQLiteStore -> PrevExternalSndId -> PrevRcvMsgHash -> RcvQueue -> RcvMsgData -> Expectation
testCreateRcvMsg' store expectedPrevSndId expectedPrevHash rcvQueue rcvMsgData@RcvMsgData {..} = do
  updateRcvIds store rcvQueue
    `returnsResult` (internalId, internalRcvId, expectedPrevSndId, expectedPrevHash)
  createRcvMsg store rcvQueue rcvMsgData
    `returnsResult` ()

testCreateRcvMsg :: SpecWith SQLiteStore
testCreateRcvMsg =
  it "should reserve internal ids and create a RcvMsg" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    -- TODO getMsg to check message
    testCreateRcvMsg' store 0 "" rcvQueue1 $ mkRcvMsgData (InternalId 1) (InternalRcvId 1) 1 "1" "hash_dummy"
    testCreateRcvMsg' store 1 "hash_dummy" rcvQueue1 $ mkRcvMsgData (InternalId 2) (InternalRcvId 2) 2 "2" "new_hash_dummy"

mkSndMsgData :: InternalId -> InternalSndId -> MsgHash -> SndMsgData
mkSndMsgData internalId internalSndId internalHash =
  SndMsgData
    { internalId,
      internalSndId,
      internalTs = ts,
      msgBody = hw,
      internalHash
    }

testCreateSndMsg' :: SQLiteStore -> PrevSndMsgHash -> SndQueue -> SndMsgData -> Expectation
testCreateSndMsg' store expectedPrevHash sndQueue sndMsgData@SndMsgData {..} = do
  updateSndIds store sndQueue
    `returnsResult` (internalId, internalSndId, expectedPrevHash)
  createSndMsg store sndQueue sndMsgData
    `returnsResult` ()

testCreateSndMsg :: SpecWith SQLiteStore
testCreateSndMsg =
  it "should create a SndMsg and return InternalId and PrevSndMsgHash" $ \store -> do
    _ <- runExceptT $ createSndConn store sndQueue1
    -- TODO getMsg to check message
    testCreateSndMsg' store "" sndQueue1 $ mkSndMsgData (InternalId 1) (InternalSndId 1) "hash_dummy"
    testCreateSndMsg' store "hash_dummy" sndQueue1 $ mkSndMsgData (InternalId 2) (InternalSndId 2) "new_hash_dummy"

testCreateRcvAndSndMsgs :: SpecWith SQLiteStore
testCreateRcvAndSndMsgs =
  it "should create multiple RcvMsg and SndMsg, correctly ordering internal Ids and returning previous state" $ \store -> do
    _ <- runExceptT $ createRcvConn store rcvQueue1
    _ <- runExceptT $ upgradeRcvConnToDuplex store "conn1" sndQueue1
    testCreateRcvMsg' store 0 "" rcvQueue1 $ mkRcvMsgData (InternalId 1) (InternalRcvId 1) 1 "1" "rcv_hash_1"
    testCreateRcvMsg' store 1 "rcv_hash_1" rcvQueue1 $ mkRcvMsgData (InternalId 2) (InternalRcvId 2) 2 "2" "rcv_hash_2"
    testCreateSndMsg' store "" sndQueue1 $ mkSndMsgData (InternalId 3) (InternalSndId 1) "snd_hash_1"
    testCreateRcvMsg' store 2 "rcv_hash_2" rcvQueue1 $ mkRcvMsgData (InternalId 4) (InternalRcvId 3) 3 "3" "rcv_hash_3"
    testCreateSndMsg' store "snd_hash_1" sndQueue1 $ mkSndMsgData (InternalId 5) (InternalSndId 2) "snd_hash_2"
    testCreateSndMsg' store "snd_hash_2" sndQueue1 $ mkSndMsgData (InternalId 6) (InternalSndId 3) "snd_hash_3"
