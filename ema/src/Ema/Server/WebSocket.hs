{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}

module Ema.Server.WebSocket where

import Control.Monad.Logger
import Data.Default (Default (def))
import Data.LVar (LVar)
import Data.LVar qualified as LVar
import Ema.Asset (
  Asset (AssetGenerated, AssetStatic),
  Format (Html, Other),
 )
import Ema.Route.Class (IsRoute (RouteModel, routePrism))
import Ema.Route.Prism (
  fromPrism_,
 )
import Ema.Server.Common
import Ema.Site (EmaStaticSite)
import NeatInterpolation (text)
import Network.WebSockets (ConnectionException)
import Network.WebSockets qualified as WS
import Optics.Core (review)
import Text.Printf (printf)
import UnliftIO.Async (race)
import UnliftIO.Exception (try)

{- | A handler takes a websocket connection and the current model and then watches
   for websocket messages. It must return a new route to watch (after that, the
   returned route's HTML will be sent back to the client).

  Note that this is usually a long-running thread that waits for the client's
  messages. But you can also use it to implement custom server actions, by handling
  the incoming websocket messages or other IO events in any way you like.

  Also note that whenever the model is updated, the handler action will be
  stopped and then restarted with the new model as argument.
-}
newtype EmaWsHandler r = EmaWsHandler
  { unEmaWsHandler :: WS.Connection -> RouteModel r -> LoggingT IO Text
  }

instance Default (EmaWsHandler r) where
  def = EmaWsHandler $ \conn _model -> do
    msg :: Text <- liftIO $ WS.receiveData conn
    log LevelDebug $ "<~~ " <> show msg
    pure msg
    where
      log lvl (t :: Text) = logWithoutLoc "ema.ws" lvl t

data EmaServerOptions r = EmaServerOptions
  { emaServerShim :: LByteString
  , emaServerWsHandler :: EmaWsHandler r
  }

instance Default (EmaServerOptions r) where
  def =
    EmaServerOptions wsClientJS def

wsApp ::
  forall r.
  (Eq r, Show r, IsRoute r, EmaStaticSite r) =>
  (Loc -> LogSource -> LogLevel -> LogStr -> IO ()) ->
  LVar (RouteModel r) ->
  EmaWsHandler r ->
  WS.PendingConnection ->
  IO ()
wsApp logger model emaWsHandler pendingConn = do
  conn :: WS.Connection <- WS.acceptRequest pendingConn
  WS.withPingThread conn 30 pass . flip runLoggingT logger $ do
    subId <- LVar.addListener model
    let log lvl (s :: Text) =
          logWithoutLoc (toText @String $ printf "ema.ws.%.2d" subId) lvl s
    log LevelInfo "Connected"
    let wsHandler = unEmaWsHandler emaWsHandler conn
        sendRouteHtmlToClient path s = do
          decodeUrlRoute @r s path & \case
            Left err -> do
              log LevelError $ badRouteEncodingMsg err
              liftIO $ WS.sendTextData conn $ emaErrorHtmlResponse $ badRouteEncodingMsg err
            Right Nothing ->
              liftIO $ WS.sendTextData conn $ emaErrorHtmlResponse decodeRouteNothingMsg
            Right (Just r) -> do
              renderCatchingErrors s r >>= \case
                AssetGenerated Html html ->
                  liftIO $ WS.sendTextData conn $ html <> toLazy wsClientHtml
                -- HACK: We expect the websocket client should check for REDIRECT prefix.
                -- Not bothering with JSON response to avoid having to JSON parse every HTML dump.
                AssetStatic _staticPath ->
                  liftIO $ WS.sendTextData conn $ "REDIRECT " <> toText (review (fromPrism_ $ routePrism s) r)
                AssetGenerated Other _s ->
                  liftIO $ WS.sendTextData conn $ "REDIRECT " <> toText (review (fromPrism_ $ routePrism s) r)
              log LevelDebug $ " ~~> " <> show r
        -- @mWatchingRoute@ is the route currently being watched.
        loop mWatchingRoute = do
          -- Listen *until* either we get a new value, or the client requests
          -- to switch to a new route.
          currentModel <- LVar.get model
          race (LVar.listenNext model subId) (wsHandler currentModel) >>= \case
            Left newModel -> do
              -- The page the user is currently viewing has changed. Send
              -- the new HTML to them.
              sendRouteHtmlToClient mWatchingRoute newModel
              loop mWatchingRoute
            Right mNextRoute -> do
              -- The user clicked on a route link; send them the HTML for
              -- that route this time, ignoring what we are watching
              -- currently (we expect the user to initiate a watch route
              -- request immediately following this).
              sendRouteHtmlToClient mNextRoute =<< LVar.get model
              loop mNextRoute
    -- Wait for the client to send the first request with the initial route.
    mInitialRoute <- wsHandler =<< LVar.get model
    try (loop mInitialRoute) >>= \case
      Right () -> pass
      Left (connExc :: ConnectionException) -> do
        case connExc of
          WS.CloseRequest _ (decodeUtf8 -> reason) ->
            log LevelInfo $ "Closing websocket connection (reason: " <> reason <> ")"
          _ ->
            log LevelError $ "Websocket error: " <> show connExc
        LVar.removeListener model subId

-- Browser-side JavaScript code for interacting with the Haskell server
wsClientJS :: LByteString
wsClientJS =
  encodeUtf8
    [text|
        <script type="module" src="https://cdn.jsdelivr.net/npm/morphdom@2.6.1/dist/morphdom-umd.min.js"></script>

        <script type="module">
        ${wsClientJSShim}
        
        window.onpageshow = function () { init(false) };
        </script>
    |]
