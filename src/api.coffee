_ = require 'lodash'
P = require 'bluebird'
FS = require 'fs'
moment = require 'moment'
request = require 'request'
WebSocket = require 'ws'
EventEmitter = require 'eventemitter3'

auth = require './auth'
config = require './config'
errors = require './errors'
logger = require './logger'

jsonify = (obj) -> JSON.stringify obj, null, 2

# Create the record for use in authenticating the tools client
makeRecord = (cfg) ->
  record =
    access_key: cfg.api_key.access
    client_salt: cfg.client_key.salt
    timestamp: moment.utc().toISOString()

class PushWebSocket extends EventEmitter
  constructor: (@cfg, @namespace, @attributes, @autoAcknowledge = true) ->
    @baseUrl = @cfg.base_ws_url
    @sock = null
    @pingerRef = null
    @messageCount = 0
    @lastMessageId = null
    @autoReconnect = @cfg.websocket_auto_reconnect ? true

  # Shutdown the WebSocket for good (prevents auto-reconnect)
  close: ->
    if @pingerRef?
      try
        clearInterval @pingerRef
      catch error
        logger.error "Error clearing ping interval: #{error}\n#{error.stack}"
      finally
        @pingerRef = null

    if @sock?
      try
        @autoReconnect = false
        @sock.close()
      catch error
        logger.error "Error while closing WebSocket: #{error}\n#{error.stack}"
      finally
        @sock = null

  # Alias to the close() method
  disconnect: -> @close()

  # Manually acknowledge that a message has been received
  ack: (messageId) ->
    if @sock?
      acknowledgement =
        event: "message-received"
        message_id: messageId
      @sock.send JSON.stringify(acknowledgement), (error) =>
        if error?
          logger.error "Error sending acknowledgement for message '#{messageId}': #{error}\n#{error.stack}"
        else
          @emit 'acked', messageId

  # Alias to the ack() method
  acknowledge: (messageId) -> @ack messageId

  # Establishes the socket if it is not yet connected
  connect: ->
    new P (resolve, reject) =>
      if @sock?
        resolve()
      else
        record = makeRecord @cfg
        record.namespace = @namespace
        record.attributes = @attributes

        data = auth.signRecord @cfg.client_key.secret, record
        hasConnected = false

        url = "#{@baseUrl}/push"
        options =
          headers:
            'Payload-HMAC': data.hmac
            'JSON-Base64': data.bufferB64
          timeout: @cfg.websocket_connect_timeout

        try
          @sock = new WebSocket(url, options)

          # The WebSocket was closed
          @sock.once 'close', =>
            if @autoReconnect == true
              @sock = null

              if @pingerRef?
                try
                  clearInterval @pingerRef
                catch error
                  logger.error "Error clearing pinger interval: #{error}\n#{error.stack}"
                finally
                  @pingerRef = null

              reconnect = =>
                @connect().then =>
                  logger.info "Push WebSocket replaced for namespace '#{@namespace}' topic #{jsonify(@attributes)}"
                  @emit 'reconnect'
                .catch (error) =>
                  logger.error "Error replacing push WebSocket for namespace '#{@namespace}' topic #{jsonify(@attributes)} : #{error}\n#{error.stack}"
                  @emit 'error', error
              
              logger.info "Connection closed. Reconnecting in 5 seconds."

              setTimeout reconnect, 5000

            else
              @emit 'close'
              if hasConnected
                logger.info "Push WebSocket closed for namespace '#{@namespace}' topic #{jsonify(@attributes)}"
              else
                message = "Websocket closed before the connection was established for namespace '#{@namespace}' topic #{jsonify(@attributes)}"
                logger.info message
                reject new Error(message)

          # The WebSocket connection has been established
          @sock.once 'open', =>
            logger.info "Push WebSocket opened for namespace '#{@namespace}' topic #{jsonify(@attributes)}"
            hasConnected = true

            @emit 'open'

            pinger = =>
              @sock.ping() if @sock?

            # Ping every 15 seconds to keep the connection alive 
            @pingerRef = setInterval pinger, 15000

            resolve()

          # An error occurred
          @sock.on 'error', (error) =>
            @emit 'error', error

            if not hasConnected
              logger.error "WebSocket connect error for namespace '#{@namespace}' topic #{jsonify(@attributes)} : #{error}\n#{error.stack}"
              reject error
            else
              logger.error "WebSocket error for namespace '#{@namespace}' topic #{jsonify(@attributes)} : #{error}\n#{error.stack}"

          # Received a message
          @sock.on 'message', (msg) =>
            @emit 'message', msg

            try
              @messageCount += 1
              message = JSON.parse msg
              @lastMessageId = message.message_id
              @ack(message.message_id) if @autoAcknowledge == true
            catch error
              logger.error "Invalid push message received: #{error}\n#{error.stack}"

          # WebSocket connection was rejected by the API
          @sock.on 'unexpected-response', (req, res) =>
            @emit 'unexpected-response', [req, res]

            logger.error "Unexpected response to WebSocket connect for namespace '#{@namespace}' topic #{jsonify(@attributes)}"

            res.on 'data', (raw) ->
              try
                record = JSON.parse json
                json = JSON.stringify record, null, 2
                reject new errors.ApiError("Server rejected the push WebSocket", undefined, res.statusCode, json)
              catch error
                reject new errors.ApiError("Server rejected the push WebSocket", undefined, res.statusCode, raw)
              false
            false

        catch error
          logger.error "Error creating WebSocket for namespace '#{@namespace}' topic #{jsonify(@attributes)}"
          reject new errors.ApiError("Error creating the push WebSocket", error)

class ApiClient
  constructor: (@cfg) ->
    @baseUrl = @cfg.base_url

  accessKey: -> @cfg?.api_key?.access
  clientSalt: -> @cfg?.client_key?.salt
  clientSecret: -> @cfg?.client_key?.secret

  subscribe: (namespace, attributes, autoAcknowledge = true) ->
    new P (resolve, reject) =>
      try
        ws = new PushWebSocket(@cfg, namespace, attributes, autoAcknowledge)
        ws.connect()
        .then -> resolve ws
        .catch (error) -> reject error
      catch error
        reject error

  sendEvent: (namespace, eventName, attributes, tags = undefined, debugDirective = undefined) ->
    record = makeRecord @cfg
    record.namespace = namespace
    record.event_name = eventName
    record.attributes = attributes
    record.tags = tags
    record.debug_directive = debugDirective

    data = auth.signRecord @cfg.client_key.secret, record

    @makeRequest 'POST', "/event", data

  getChannelSummary: (namespace, attributes) ->
    record = makeRecord @cfg
    record.namespace = namespace
    record.attributes = attributes

    data = auth.signRecord @cfg.client_key.secret, record

    @makeRequest 'POST', "/channel_summary", data

  getMessage: (namespace, attributes, messageId) ->
    record = makeRecord @cfg
    record.namespace = namespace
    record.attributes = attributes

    data = auth.signRecord @cfg.client_key.secret, record
    
    @makeRequest 'GET', "/message/#{messageId}", data

  makeRequest: (method, path, data) ->
    new P (resolve, reject) =>
      isGet = method == 'GET'
      contentType = if not isGet then 'application/json' else undefined
      jsonB64Header = if isGet then data.bufferB64 else undefined
      payload = if not isGet then data.buffer else undefined

      url = "#{@baseUrl}#{path}"
      options =
        uri: url
        method: method
        headers:
          'Payload-HMAC': data.hmac
          'Content-Type': contentType
          'JSON-Base64': jsonB64Header
        body: payload
        timeout: @cfg.http_request_timeout

      request options, (error, response) ->
        if error?
          reject new errors.ApiError("Error attempting to send a request to the Cogs server", error)
        else if response.statusCode != 200
          try
            record = JSON.parse json
            json = JSON.stringify record, null, 2
            reject new errors.ApiError("Received an error response from the server", undefined, response.statusCode, json)
          catch error
            reject new errors.ApiError("Received an error response from the server", undefined, response.statusCode, response.body)
        else
          try
            resolve JSON.parse(response.body)
          catch error
            reject new errors.ApiError("Error parsing response body (expected valid JSON)", error)


# exports
module.exports =
  getClient: (configPath) ->
    config.getConfig configPath
    .then (cfg) ->
      logger.setLogLevel(cfg.log_level) if cfg.log_level?
      new ApiClient(cfg)

  getClientWithConfig: (cfg) ->
    config.validateConfig cfg
    .then (cfg) ->
      logger.setLogLevel(cfg.log_level) if cfg.log_level?
      new ApiClient(cfg)

