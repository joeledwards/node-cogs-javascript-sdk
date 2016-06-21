_ = require 'lodash'
Q = require 'q'
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
    @initiatedClose = false
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
        @initiatedClose = true
        @sock.close()
      catch error
        logger.error "Error while closing WebSocket: #{error}\n#{error.stack}"
      finally
        @sock = null

    @removeAllListeners()

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
    d = Q.defer()
    if @sock?
      d.resolve()
    else
      record = makeRecord @cfg
      record.namespace = @namespace
      record.attributes = @attributes

      data = auth.signRecord @cfg.client_key.secret, record

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
          if @autoReconnect == true and @initiatedClose != true
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
                logger.error "Error replacing push WebSocket for namespace '#{@namespace}' topic #{jsonify(@attributes)} : ${error}\n${error.stack}"
                @emit 'error', error
            
            logger.info "Connection closed. Reconnecting in 5 seconds."

            setTimeout reconnect, 5000

          else
            logger.info "Push WebSocket closed for namespace '#{@namespace}' topic #{jsonify(@attributes)}"
            @emit 'close'

        # The WebSocket connection has been established
        @sock.once 'open', =>
          logger.info "Push WebSocket opened for namespace '#{@namespace}' topic #{jsonify(@attributes)}"

          @emit 'open'

          pinger = =>
            @sock.ping()

          # Ping every 15 seconds to keep the connection alive 
          @pingerRef = setInterval pinger, 15000

          d.resolve()

        # An error occurred
        @sock.on 'error', (error) =>
          @emit 'error', error

          logger.error "WebSocket error for namespace '#{@namespace}' topic #{jsonify(@attributes)} : #{error}\n#{error.stack}"

        # Received a message
        @sock.on 'message', (msg) =>
          @emit 'message', msg

          try
            @messageCount += 1
            message = JSON.parse msg
            @lastMessageId = message.message_id
            @ack(message.messageId) if @autoAcknowledge
          catch error
            logger.error "Invalid push message received: #{error}\n#{error.stack}"

        # WebSocket connection was rejected by the API
        @sock.on 'unexpected-response', (req, res) =>
          @emit 'unexpected-response', [req, res]

          res.on 'data', (raw) ->
            try
              record = JSON.parse json
              json = JSON.stringify record, null, 2
              d.reject new errors.ApiError("Server rejected the push WebSocket", undefined, res.statusCode, json)
            catch error
              d.reject new errors.ApiError("Server rejected the push WebSocket", undefined, res.statusCode, raw)
            false
          false

      catch error
        d.reject new errors.ApiError("Error creating the push WebSocket", error)

    d.promise

class ApiClient
  constructor: (@cfg) ->
    @baseUrl = @cfg.base_url

  accessKey: -> @cfg?.api_key?.access
  clientSalt: -> @cfg?.client_key?.salt
  clientSecret: -> @cfg?.client_key?.secret

  subscribe: (namespace, attributes) ->
    d = Q.defer()

    try
      ws = new PushWebSocket(@cfg, namespace, attributes)
      ws.connect()
      d.resolve ws
    catch error
      d.reject error

    d.promise

  sendEvent: (namespace, eventName, attributes, tags = undefined, debugDirective = undefined) ->
    record = makeRecord @cfg
    record.namespace = namespace
    record.event_name = eventName
    record.attributes = attributes
    record.tags = tags
    record.debug_directive = debugDirective

    data = auth.signRecord @cfg.client_key.secret, record

    @makeRequest 'POST', "/event", data

  getMessage: (namespace, attributes, messageId) ->
    record = makeRecord @cfg
    record.namespace = namespace
    record.attributes = attributes

    data = auth.signRecord @cfg.client_key.secret, record
    
    @makeRequest 'GET', "/message/#{messageId}", data

  makeRequest: (method, path, data) ->
    d = Q.defer()
    
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
        d.reject new errors.ApiError("Error attempting to send a request to the Cogs server", error)
      else if response.statusCode != 200
        try
          record = JSON.parse json
          json = JSON.stringify record, null, 2
          d.reject new errors.ApiError("Received an error response from the server", undefined, response.statusCode, json)
        catch error
          d.reject new errors.ApiError("Received an error response from the server", undefined, response.statusCode, response.body)
      else
        try
          d.resolve JSON.parse(response.body)
        catch error
          d.reject new errors.ApiError("Error parsing response body (expected valid JSON)", error)

    d.promise


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

