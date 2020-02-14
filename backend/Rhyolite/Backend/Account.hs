{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-orphans -Wno-unused-matches #-}
{- NOTE: We add a -Wno-unused-matches because the code generated by groundhog has an unused variable
  GROUNDHOG ERROR -
  src/Rhyolite/Backend/Account.hs:35:1: warning: [-Wunused-matches]
    Defined but not used: ‘p’
  <no location info>: error:
  Failing due to -Werror.
-}

module Rhyolite.Backend.Account where

import Control.Monad.Trans.Maybe
import Control.Monad.Writer
import Crypto.PasswordStore
import Data.Aeson
import Data.Byteable (toBytes)
import Data.ByteString (ByteString)
import Data.Constraint.Extras
import Data.Constraint.Forall
import Data.Default
import Data.Functor.Identity
import Data.List.NonEmpty
import Data.Maybe
import Data.SecureMem
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding
import Data.Time
import Data.Typeable
import Database.Groundhog
import Database.Groundhog.Core
import Database.Groundhog.Generic.Sql.Functions
import Database.Groundhog.TH (defaultCodegenConfig, groundhog, mkPersist)
import Database.Id.Class
import Database.Id.Groundhog
import Database.Id.Groundhog.TH
import Text.Blaze.Html5 (Html)
import qualified Text.Blaze.Html5 as H
import Text.Blaze.Html5.Attributes as A

import Rhyolite.Backend.DB
import Rhyolite.Backend.Email
import Rhyolite.Backend.Listen

import Rhyolite.Account
import Rhyolite.Email
import Rhyolite.Route
import Rhyolite.Schema
import Rhyolite.Sign

mkPersist defaultCodegenConfig [groundhog|
  - entity: Account
    constructors:
      - name: Account
        uniques:
          - name: emailUnique
            type: index
            fields: [{expr: "lower(account_email::text)"}]
|]

makeDefaultKeyIdInt64 ''Account 'AccountKey

migrateAccount :: PersistBackend m => TableAnalysis m -> Migration m
migrateAccount tableInfo = migrate tableInfo (undefined :: Account)

-- Returns whether a new account had to be created
ensureAccountExists
  :: ( PersistBackend m
     , SqlDb (PhantomDb m)
     , Has' ToJSON n Identity
     , ForallF ToJSON n
     )
  => n (Id Account)
  -> Email
  -> m (Bool, Id Account)
ensureAccountExists nm email = do
  nonce <- getTime
  mPrevId <- fmap (listToMaybe . fmap toId) $ project AutoKeyField (lower Account_emailField ==. T.toLower email)
  case mPrevId of
    Just prevId -> return (False, prevId)
    Nothing -> do
      result <- insertByAll $ Account email Nothing (Just nonce)
      case result of
        -- TODO: Better way to handle errors?
        Left _ -> error "ensureAccountExists: Creating account failed"
        Right aid -> do
          let aid' = toId aid
          notify NotificationType_Insert nm aid'
          return (True, aid')

-- Creates account if it doesn't already exist and sends pw email
ensureAccountExistsEmail
  :: ( PersistBackend m
     , MonadSign m
     , SqlDb (PhantomDb m)
     , Typeable f
     , ToJSON (f (Id Account))
     , Has' ToJSON n Identity
     , ForallF ToJSON n
     )
  => n (Id Account)
  -> (Id Account -> f (Id Account))
  -> (Signed (PasswordResetToken f) -> Email -> m ()) -- pw reset email
  -> Email
  -> m (Bool, Id Account)
ensureAccountExistsEmail n = ensureAccountExistsEmail' (ensureAccountExists n)

-- Creates account if it doesn't already exist and sends pw email
-- Allows the option for a custom "ensure account" creation function
ensureAccountExistsEmail'
  :: ( PersistBackend m
     , MonadSign m
     , Typeable f
     , ToJSON (f (Id Account)))
  => (Email -> m (Bool, Id Account))
  -> (Id Account -> f (Id Account))
  -> (Signed (PasswordResetToken f) -> Email -> m ()) -- pw reset email
  -> Email
  -> m (Bool, Id Account)
ensureAccountExistsEmail' ensureAccount decorateAccountId pwEmail email = do
  ret@(_, aid) <- ensureAccount email
  mNonce <- generateAndSendPasswordResetEmail decorateAccountId pwEmail aid
  forM_ mNonce $ \nonce -> do
    update [Account_passwordResetNonceField =. Just nonce] (Account_emailField ==. email)
  return ret

generatePasswordResetToken
  :: ( PersistBackend m
     , MonadSign m
     , Typeable f
     , ToJSON (f (Id Account))
     )
  => f (Id Account)
  -> m (Signed (PasswordResetToken f))
generatePasswordResetToken aid = do
  nonce <- getTime
  sign $ PasswordResetToken (aid, nonce)

generatePasswordResetTokenFromNonce
  :: ( MonadSign m
     , Typeable f
     , ToJSON (f (Id Account))
     )
  => f (Id Account)
  -> UTCTime
  -> m (Signed (PasswordResetToken f))
generatePasswordResetTokenFromNonce aid nonce = sign $ PasswordResetToken (aid, nonce)

setAccountPassword
  :: (PersistBackend m, MonadIO m)
  => Id Account
  -> Text
  -> m ()
setAccountPassword aid password = do
  pw <- makePasswordHash password
  update [ Account_passwordHashField =. Just pw
         , Account_passwordResetNonceField =. (Nothing :: Maybe UTCTime) ]
         (AutoKeyField ==. fromId aid)

makePasswordHash
  :: MonadIO m
  => Text
  -> m ByteString
makePasswordHash pw = do
  salt <- liftIO genSaltIO
  return $ makePasswordSaltWith pbkdf2 (2^) (encodeUtf8 pw) salt 14

resetPassword
  :: (MonadIO m, PersistBackend m)
  => Id Account
  -> UTCTime
  -> Text
  -> m (Maybe (Id Account))
resetPassword aid nonce password = do
  Just a <- get $ fromId aid
  if account_passwordResetNonce a == Just nonce
    then do
      setAccountPassword aid password
      return $ Just aid
    else return Nothing

login
  :: (PersistBackend m, SqlDb (PhantomDb m))
  => (Id Account -> m loginInfo)
  -> Email
  -> Text
  -> m (Maybe loginInfo)
login toLoginInfo email password = runMaybeT $ do
  (aid, a) <- MaybeT . fmap listToMaybe $ project (AutoKeyField, AccountConstructor) (lower Account_emailField ==. T.toLower email)
  ph <- MaybeT . return $ account_passwordHash a
  guard $ verifyPasswordWith pbkdf2 (2^) (encodeUtf8 password) ph
  lift $ toLoginInfo (toId aid)

loginByAccountId
  :: (PersistBackend m)
  => Id Account
  -> Text
  -> m (Maybe ())
loginByAccountId aid password = runMaybeT $ do
  a <- MaybeT . fmap listToMaybe $ project AccountConstructor (AutoKeyField ==. fromId aid)
  ph <- MaybeT . return $ account_passwordHash a
  guard $ verifyPasswordWith pbkdf2 (2^) (encodeUtf8 password) ph

generateAndSendPasswordResetEmail
  :: (PersistBackend m, MonadSign m, Typeable f, ToJSON (f (Id Account)))
  => (Id Account -> f (Id Account))
  -> (Signed (PasswordResetToken f) -> Email -> m ())
  -> Id Account
  -> m (Maybe UTCTime)
generateAndSendPasswordResetEmail decorateAccountId pwEmail aid = do
  nonce <- getTime
  prt <- sign $ PasswordResetToken (decorateAccountId aid, nonce)
  ma <- get (fromId aid)
  forM ma $ \a -> do
    pwEmail prt (account_email a)
    return nonce

-- | Like 'generateAndSendPasswordResetEmail', but sets the nonce in the
-- database instead of just returning it.
generateAndSendPasswordResetEmailUpdateNonce
  :: (PersistBackend m, MonadSign m, Typeable f, ToJSON (f (Id Account)))
  => (Id Account -> f (Id Account))
  -> (Signed (PasswordResetToken f) -> Email -> m ())
  -> Id Account
  -> m ()
generateAndSendPasswordResetEmailUpdateNonce f g aid = do
  nonce <- generateAndSendPasswordResetEmail f g aid
  void $ update [Account_passwordResetNonceField =. nonce] $ AutoKeyField ==. fromId aid

newAccountEmail
  :: (MonadRoute r m, Default r)
  => Text
  -> Text
  -> (AccountRoute f -> r)
  -> Signed (PasswordResetToken f)
  -> m Html
newAccountEmail productName productDescription f token = do
  passwordResetLink <- routeToUrl $ f $ AccountRoute_PasswordReset token
  emailTemplate productName
                Nothing
                (H.text $ "Welcome to " <> productName)
                (H.a H.! A.href (fromString $ show passwordResetLink) $ H.text "Click here to verify your email")
                (H.p $ H.text productDescription)

sendNewAccountEmail
  :: (MonadRoute r m, Default r, MonadEmail m)
  => Text
  -> Text
  -> Text
  -> Text
  -> (AccountRoute f -> r) -- How to turn AccountRoute into a route for a specific app
  -> Signed (PasswordResetToken f)
  -> Email
  -> m ()
sendNewAccountEmail senderName senderEmail productName productDescription f prt email = do
  body <- newAccountEmail productName productDescription f prt
  sendEmailFrom senderName senderEmail (email :| []) (productName <> " Verification Email") body

sendPasswordResetEmail
  :: (MonadEmail m, MonadRoute r m, Default r)
  => Text
  -> Text
  -> Text
  -> (AccountRoute f -> r)
  -> Signed (PasswordResetToken f)
  -> Email
  -> m ()
sendPasswordResetEmail senderName senderEmail productName f prt email = do
  passwordResetLink <- routeToUrl $ f $ AccountRoute_PasswordReset prt
  let lead = "You have received this message because you requested that your " <> productName <> " password be reset. Click the link below to create a new password."
      body = H.a H.! A.href (fromString $ show passwordResetLink) $ "Reset Password"
  sendEmailFrom senderName senderEmail (email :| []) (productName <> " Password Reset") =<< emailTemplate productName Nothing (H.text (productName <> " Password Reset")) (H.toHtml lead) body

-- SecureMem functions that delay the conversion of the secret (wrapped in a SecureMem type) to Text until it is required for a third-party interface. This
-- preventes the accidental leakage of secrets into logs

setAccountPasswordSM
  :: (PersistBackend m, MonadIO m)
  => Id Account
  -> SecureMem
  -> m ()
setAccountPasswordSM aid password = do
  pw <- makePasswordHashSM password
  update [ Account_passwordHashField =. Just pw
         , Account_passwordResetNonceField =. (Nothing :: Maybe UTCTime) ]
         (AutoKeyField ==. fromId aid)

makePasswordHashSM
  :: MonadIO m
  => SecureMem
  -> m ByteString
makePasswordHashSM pw = do
  salt <- liftIO genSaltIO
  return $ makePasswordSaltWith pbkdf2 (2^) (toBytes pw) salt 14

resetPasswordSM
  :: (MonadIO m, PersistBackend m)
  => Id Account
  -> UTCTime
  -> SecureMem
  -> m (Maybe (Id Account))
resetPasswordSM aid nonce password = do
  Just a <- get $ fromId aid
  if account_passwordResetNonce a == Just nonce
    then do
      setAccountPasswordSM aid password
      return $ Just aid
    else return Nothing

loginSM
  :: (PersistBackend m, SqlDb (PhantomDb m))
  => (Id Account -> m loginInfo)
  -> Email
  -> SecureMem
  -> m (Maybe loginInfo)
loginSM toLoginInfo email password = runMaybeT $ do
  (aid, a) <- MaybeT . fmap listToMaybe $ project (AutoKeyField, AccountConstructor) (lower Account_emailField ==. T.toLower email)
  ph <- MaybeT . return $ account_passwordHash a
  guard $ verifyPasswordWith pbkdf2 (2^) (toBytes password) ph
  lift $ toLoginInfo (toId aid)

loginByAccountIdSM
  :: (PersistBackend m)
  => Id Account
  -> SecureMem
  -> m (Maybe ())
loginByAccountIdSM aid password = runMaybeT $ do
  a <- MaybeT . fmap listToMaybe $ project AccountConstructor (AutoKeyField ==. fromId aid)
  ph <- MaybeT . return $ account_passwordHash a
  guard $ verifyPasswordWith pbkdf2 (2^) (toBytes password) ph
