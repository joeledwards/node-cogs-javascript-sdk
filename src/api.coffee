_ = require 'lodash'
P = require 'bluebird'
moment = require 'moment'
request = require 'request'
EventEmitter = require 'eventemitter3'

auth = require './auth'
config = require './config'
errors = require './errors'
logger = require './logger'
WebSocket = require('./ws')()

jsonify = (obj) -> JSON.stringify obj, null, 2

# Create the record for use in authenticating the tools client
makeRecord = (cfg) ->
  record =
    access_key: cfg.api_key.access
    client_salt: cfg.client_key.salt
    timestamp: moment.utc().toISOString()

isNode = -> window == undefined

class PushWebSocket extends EventEmitter
  constructor: (@cfg, @namespace, @attributes, @autoAcknowledge = true) ->
    @baseWsUrl = @cfg.base_ws_url
    @sock = null
    @pingerRef = null
    @messageCount = 0
    @lastMessageId = null
    @autoReconnect = @cfg.websocket_auto_reconnect ? true

  # Shutdown the WebSocket for good (prevents subsequent auto-reconnect)
  close: ->
    @autoReconnect = false

    if @pingerRef?
      try
        clearInterval @pingerRef
      catch error
        logger.error "Error clearing ping interval: #{error}\n#{error.stack}"
      finally
        @pingerRef = null

    if @sock?
      try
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

      logger.verbose "Acknowledging message #{messageId} with payload #{acknowledgement}"

      @sock.send JSON.stringify(acknowledgement)
      .then =>
        @emit 'acked', messageId
      .catch (error) ->
        logger.error "Error sending acknowledgement for message '#{messageId}': #{error}\n#{error.stack}"
    else
      logger.warn "The connection is not open, therefore message '#{messageId}' cannot be acknowledged."

  # Alias to the ack() method
  acknowledge: (messageId) -> @ack messageId

  # Establishes the socket if it is not yet connected
  connect: ->
    connectHandler = (resolve, reject) =>
      if @sock?
        resolve()
      else
        record = makeRecord @cfg
        record.namespace = @namespace
        record.attributes = @attributes

        data = auth.signRecord @cfg.client_key.secret, record
        hasConnected = false

        url = "#{@baseWsUrl}/push"
        headers =
          'Payload-HMAC': data.hmac
          'JSON-Base64': data.bufferB64
        timeout = @cfg.websocket_connect_timeout

        try
          @sock = new WebSocket(url, headers, timeout)

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
                  logger.info "Push WebSocket replaced for namespace '#{@namespace}' channel #{jsonify(@attributes)}"
                  @emit 'reconnect'
                .catch (error) =>
                  logger.error "Error replacing push WebSocket for namespace '#{@namespace}' channel #{jsonify(@attributes)} : #{error}\n#{error.stack}"
                  @emit 'error', error
              
              logger.info "Connection closed. Reconnecting in 5 seconds."

              setTimeout reconnect, 5000

            else
              @emit 'close'
              if hasConnected
                logger.info "Push WebSocket closed for namespace '#{@namespace}' channel #{jsonify(@attributes)}"
              else
                message = "Websocket closed before the connection was established for namespace '#{@namespace}' channel #{jsonify(@attributes)}"
                logger.info message
                reject new Error(message)

          # The WebSocket connection has been established
          @sock.once 'open', =>
            logger.info "Push WebSocket opened for namespace '#{@namespace}' channel #{jsonify(@attributes)}"
            hasConnected = true

            @emit 'open'

            pinger = =>
              logger.verbose "Sending PING to keep the push WebSocket alive."
              @sock.ping() if @sock?

            # Ping every 15 seconds to keep the connection alive 
            @pingerRef = setInterval pinger, 15000

            resolve()

          # An error occurred
          @sock.on 'error', (error) =>
            @emit 'error', error

            if not hasConnected
              logger.error "WebSocket connect error for namespace '#{@namespace}' channel #{jsonify(@attributes)} : #{error}\n#{error.stack}"
              reject error
            else
              logger.error "WebSocket error for namespace '#{@namespace}' channel #{jsonify(@attributes)} : #{error}\n#{error.stack}"

          # Received a message
          @sock.on 'message', (msg) =>
            @emit 'message', msg

            logger.verbose "Received message from namespace '#{@namespace}' channel #{jsonify(@attributes)} :", msg

            try
              @messageCount += 1
              message = JSON.parse msg
              @lastMessageId = message.message_id
              @ack(message.message_id) if @autoAcknowledge == true
            catch error
              logger.error "Invalid push message received: #{error}\n#{error.stack}"

          # WebSoket connection failure
          @sock.once 'connectFailed', (error) =>
            @emit 'connectFailed', error

            logger.error "Failed to connect to push WebSocket for namespace '#{@namespace}' channel #{jsonify(@attributes)}"

            reject new errors.ApiError("Server rejected the push WebSocket", error)

        catch error
          logger.error "Error creating WebSocket for namespace '#{@namespace}' channel #{jsonify(@attributes)}"
          reject new errors.ApiError("Error creating the push WebSocket", error)

    new P(connectHandler)

class ApiClient
  constructor: (@cfg) ->
    @_initialized = true

  baseUrl: -> @cfg?.base_url ? undefined
  baseWsUrl: -> @cfg?.base_ws_url ? undefined
  accessKey: -> @cfg?.api_key?.access ? undefined
  clientSalt: -> @cfg?.client_key?.salt ? undefined
  clientSecret: -> @cfg?.client_key?.secret ? undefined

  subscribe: (namespace, attributes, autoAcknowledge = true) ->
    try
      ws = new PushWebSocket(@cfg, namespace, attributes, autoAcknowledge)
      ws.connect()
      ws
    catch cause
      error = new PushError("Error creating the subscription WebSocket '#{namespace}' channel #{jsonify(attributes)}", cause)
      logger.error error
      throw error

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

      options =
        uri: "#{@baseUrl()}#{path}"
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

