_ = require 'lodash'
P = require 'bluebird'
Joi = require 'joi'
LRU = require 'lru-cache'
moment = require 'moment'
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
    @baseWsUrl = options.baseWsUrl ? 'wss://api.cogswell.io'
    @connectTimeout = options.connectTimeout ? 5000
    @autoReconnect = options.autoReconnect ? true
    @pingInterval = options.pingInterval ? 15000
    @sock = null
    @pingerRef = null
    @messageCount = 0
    @sequence = 0
    @outstanding = LRU
      max: 1000
      maxAge: 60 * 1000
      dispose: (sequence, info) ->
        console.log "Discarded sequence #{sequence}"
    
  # Publish a message to a channel.
  publish: (channel, message) ->
    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          sequence: seq
          directive: 'publish'
          channel: channel
          message: message
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error while publishing message:"
          logger.error message, error
          reject new error.PubSubError message, error 
        
      else
        message = "Could not publish a message as the socket is currently disconnected."
        logger.warn message
        reject new error.PubSubError message, null

  # Subscribe to a channel.
  subscribe: (channel) ->
    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          sequence: seq
          directive: 'subscribe'
          channel: channel
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error while subscribing to channel:"
          logger.error message, error
          reject new error.PubSubError message, error 
        
      else
        message = "Could not subscribe to channel as the socket is currently disconnected."
        logger.warn message
        reject new error.PubSubError message, null

  # Unsubscribe from a channel.
  unsubscribe: (channel) ->
    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        record =
          sequence: seq
          directive: 'unsubscribe'
          channel: channel
        
        @sock.send JSON.stringify(record)
        .then =>
          @outstanding.set seq,
            resolve: resolve
            reject: reject
        .catch (error) ->
          message = "Socket error while unsubscribing from channel:"
          logger.error message, error
          reject new error.PubSubError message, error 
        
      else
        message = "Could not unsubscribe from channel as the socket is currently disconnected."
        logger.warn message
        reject new error.PubSubError message, null

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
                  logger.info "Pub/Sub WebSocket replaced."
                  @emit 'reconnect'
                .catch (error) =>
                  logger.error "Error replacing Pub/Sub WebSocket", error
                  @emit 'error', error
              
              logger.info "Connection closed. Reconnecting in 5 seconds."

              setTimeout reconnect, 5000

            else
              @emit 'close'
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

            @emit 'open'

            pinger = =>
              logger.verbose "Sending PING to keep the Pub/Sub WebSocket alive."
              @sock.ping() if @sock?

            # Ping every 15 seconds to keep the connection alive 
            @pingerRef = setInterval pinger, @pingInterval

            resolve()

          # An error occurred
          @sock.on 'error', (error) =>
            @emit 'error', error

            if not hasConnected
              logger.error "WebSocket connect error:", error
              reject error
            else
              logger.error "WebSocket error:", error

          # Received a message
          @sock.on 'message', (msg) =>
            logger.verbose "Received a message:", msg

            try
              @messageCount += 1
              message = JSON.parse msg

              if message.sequence?
                {resolve, reject} = @outstanding.get message.sequence

                if message.code != 200
                  resolve
                    channel: message.channel
                    message: message.message
                else
                  reject(new errors.PubSubError(message.message, null, message.code))
              else if message.id?
                @emit 'message', msg
            catch error
              logger.error "Invalid message received: #{error}\n#{error.stack}"

          # WebSoket connection failure
          @sock.once 'connectFailed', (error) =>
            @emit 'connectFailed', error

            logger.error "Failed to connect to Pub/Sub WebSocket"

            reject new errors.ApiError("Server rejected the push WebSocket", error)

        catch error
          logger.error "Error creating WebSocket for namespace '#{@namespace}' channel #{jsonify(@attributes)}"
          reject new errors.ApiError("Error creating the push WebSocket", error)

    new P(connectHandler)


# exports
module.exports =
  connect: (keys, baseUrl) ->
    ws = new PubSubWebSocket keys, baseUrl
    ws.connect()
    ws
