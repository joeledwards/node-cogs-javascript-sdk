_ = require 'lodash'
P = require 'bluebird'
Joi = require 'joi'
LRU = require 'lru-cache'
moment = require 'moment'
dialect = require 'cogs-pubsub-dialect'
request = require 'request'
EventEmitter = require 'eventemitter3'

auth = require './auth'
config = require './config'
errors = require './errors'
logger = require './logger'
WebSocket = require('./ws')()

jsonify = (obj) -> JSON.stringify obj, null, 2

isNode = -> window == undefined

class PubSubWebSocket extends EventEmitter
  constructor: (@keys, @options) ->
    super()

    @baseWsUrl = @options.baseWsUrl ? 'wss://api.cogswell.io'
    @connectTimeout = @options.connectTimeout ? 5000
    @autoReconnect = @options.autoReconnect ? true
    @pingInterval = @options.pingInterval ? 15000
    @logLevel = @options.logLevel ? 'error'

    logger.setLogLevel @logLevel
    logger.info "Set logger level to '#{@logLevel}'"

    if @options?
      logger.info "Options based to new Pub/Sub WebSocket:\n
          #{JSON.stringify(@options, null, 2)}"

    @handlers = {}
    @sock = null
    @pingerRef = null
    @recordCount = 0
    @sequence = 0
    @outstanding = LRU
      max: 1000
      maxAge: 60 * 1000
      dispose: (sequence, info) ->
        logger.info "Discarded old sequence #{sequence}"

  # Fetch the client UUID from the server.
  clientUuid: ->
    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          seq: seq
          action: 'client-uuid'
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error while requesting client UUID:"
          logger.error message, error
          reject new errors.PubSubError message, error 
        
      else
        message = "Could not fetch the client UUID as the socket is currently disconnected."
        logger.warn message
        reject new errors.PubSubError message, null

    .then (response) -> response.uuid
    
  # Publish a message to a channel.
  publish: (channel, message) ->
    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          seq: seq
          action: 'pub'
          chan: channel
          msg: message
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error while publishing message:"
          logger.error message, error
          reject new errors.PubSubError message, error 
        
      else
        message = "Could not publish a message as the socket is currently disconnected."
        logger.warn message
        reject new errors.PubSubError message, null

  # Subscribe to a channel.
  subscribe: (channel, handler) ->
    if typeof handler == 'function'
      @handlers[channel] = handler

    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          seq: seq
          action: 'subscribe'
          channel: channel
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error while subscribing to channel:"
          logger.error message, error
          reject new errors.PubSubError message, error 
        
      else
        message = "Could not subscribe to channel as the socket is currently disconnected."
        logger.warn message
        reject new errors.PubSubError message, null

    .then (response) -> response.channels

    .catch (error) =>
      logger.error "Error subscribing to channel '#{channel}'", error
      delete @handlers[channel]

  # Unsubscribe from a channel.
  unsubscribe: (channel) ->
    delete @handlers[channel]

    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          seq: seq
          action: 'unsubscribe'
          channel: channel
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error while unsubscribing from channel:"
          logger.error message, error
          reject new errors.PubSubError message, error 
        
      else
        message = "Could not unsubscribe from channel as the socket is currently disconnected."
        logger.warn message
        reject new errors.PubSubError message, null

    .then (response) -> response.channels

  # Unsubscribe from a channel.
  unsubscribeAll: ->
    @handlers = {}

    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          seq: seq
          action: 'unsubscribe-all'
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error while unsubscribing from channel:"
          logger.error message, error
          reject new errors.PubSubError message, error 
        
      else
        message = "Could not unsubscribe from channel as the socket is currently disconnected."
        logger.warn message
        reject new errors.PubSubError message, null

    .then (response) -> response.channels

  # List all channels to which this connection is subscribed.
  listSubscriptions: ->
    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          seq: seq
          action: 'subscriptions'
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error listing connection subscriptions:"
          logger.error message, error
          reject new errors.PubSubError message, error 
        
      else
        message = "Could not list channel subscriptions as the socket is currently disconnected."
        logger.warn message
        reject new errors.PubSubError message, null

    .then (response) -> response.channels

  # Shutdown the WebSocket for good (prevents subsequent auto-reconnect)
  close: ->
    @autoReconnect = false

    if @pingerRef?
      try
        clearInterval @pingerRef
      catch error
        logger.error "Error clearing ping interval:", error
      finally
        @pingerRef = null

    @unsubscribeAll()
    .finally =>
      if @sock?
        try
          @sock.close()
        catch error
          logger.error "Error while closing WebSocket:", error
        finally
          @sock = null

  # Alias to the close() method
  disconnect: -> @close()

  # Establishes the socket if it is not yet connected
  connect: ->
    connectHandler = (resolve, reject) =>
      if @sock?
        resolve()
      else
        data = auth.socketAuth @keys
        hasConnected = false

        if data?
          logger.info "Finished assembling auth data:\n
              #{JSON.stringify(data, null, 2)}"

        url = "#{@baseWsUrl}/push"
        headers =
          'Payload': data.bufferB64
          'PayloadHMAC': data.hmac
        timeout = @connectTimeout

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
                  logger.error "Error clearing pinger interval:", error
                finally
                  @pingerRef = null

              reconnect = =>
                @connect().then =>
                  setImmediate => @emit 'reconnect'
                  logger.info "Pub/Sub WebSocket replaced."
                .catch (error) =>
                  setImmediate => @emit 'error', error
                  logger.error "Error replacing Pub/Sub WebSocket", error
              
              logger.info "Connection closed. Reconnecting in 5 seconds."

              setTimeout reconnect, 5000

            else
              setImmediate => @emit 'close'

              if hasConnected
                logger.info "Pub/Sub WebSocket closed."
              else
                message = "Websocket closed before the connection was established"
                logger.info message
                reject new Error(message)

          # The WebSocket connection has been established
          @sock.once 'open', =>
            logger.info "Pub/Sub WebSocket opened."
            hasConnected = true

            setImmediate => @emit 'open'

            pinger = =>
              logger.verbose "Sending PING to keep the Pub/Sub WebSocket alive."
              @sock.ping() if @sock?

            # Ping every 15 seconds to keep the connection alive 
            @pingerRef = setInterval pinger, @pingInterval

            resolve()

          # An error occurred
          @sock.on 'error', (error) =>
            setImmediate => @emit 'error', error

            if not hasConnected
              logger.error "WebSocket connect error:", error
              reject error
            else
              logger.error "WebSocket error:", error

          # Received a record
          @sock.on 'message', (rec) =>
            logger.verbose "Received a record:", rec
            @recordCount += 1

            validation = dialect.parseAndAutoValidate rec

            if not validation.isValid
              error = validation.error
              message = 'Unknown action or bad record format from server'
              setImmediate => @emit 'error', new errors.PubSubError("#{message}: #{rec}", error)

              logger.error "#{message}: #{error}\n#{error.stack}"
            else
              record = validation.value

              if record.seq?
                promise = @outstanding.get record.seq

                if not promise?
                  message = 'Received a record containing an unknown sequence number.'
                  setImmediate => @emit 'error', new errors.PubSubError("#{message}: #{rec}")

                  logger.error "#{message}: #{rec}"
                else
                  {resolve, reject} = promise
                  @outstanding.del record.seq

                  if record.code == 200
                    resolve record
                  else
                    reject(new errors.PubSubFailureResponse(
                      record.message, null, record.code, record.details, record
                    ))
              else if record.action == 'msg'
                {id, action, time, chan, msg} = record

                @handlers[chan]?(chan, msg, id)

                setImmediate =>
                  @emit 'message',
                    channel: chan
                    message: msg
                    timestamp: time
                    id: id
              else
                setImmediate => @emit 'error', new errors.PubSubError("#{message}: #{rec}")

                message = 'Valid, but un-handled response type.'
                logger.error "#{message}"

          # WebSocket connection failure
          @sock.once 'connectFailed', (error) =>
            setImmediate => @emit 'connectFailed', error

            logger.error "Failed to connect to Pub/Sub WebSocket"
            reject new errors.ApiError("Server rejected the push WebSocket", error)

        catch error
          logger.error "Error creating WebSocket for namespace '#{@namespace}' channel #{jsonify(@attributes)}"
          reject new errors.ApiError("Error creating the push WebSocket", error)

    new P(connectHandler)


# exports
module.exports =
  connect: (keys, options) ->
    ws = new PubSubWebSocket keys, options
    ws.connect().then -> ws

