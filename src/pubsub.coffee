_ = require 'lodash'
P = require 'bluebird'
Joi = require 'joi'
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
    @baseWsUrl = options.baseWsUrl ? 'https://api.cogswell.io'
    @connectTimeout = options.connectTimeout ? 5000
    @autoReconnect = options.autoReconnect ? true
    @pingInterval = options.pingInterval ? 15000
    @sock = null
    @pingerRef = null
    @messageCount = 0
    @lastMessageId = null
    @sequence = 0
    @outstanding = {}
    
  # Publish a message to a channel.
  publish: (channel, message) ->
    new P (resolve, reject) =>
      if @sock?
        seq = @sequence
        @sequence += 1
        
        directive =
          sequence: seq
          directive: 'publish'
          channel: channel
          message: message
        
        @sock.send JSON.stringify(directive)
        .then =>
          @outstanding[seq] =
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
        
        directive =
          sequence: seq
          directive: 'subscribe'
          channel: channel
        
        @sock.send JSON.stringify(directive)
        .then =>
          @outstanding[seq] =
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
        
        directive =
          sequence: seq
          directive: 'unsubscribe'
          channel: channel
        
        @sock.send JSON.stringify(directive)
        .then =>
          @outstanding[seq] =
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
            @pingerRef = setInterval pinger, @pingInterval

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


# exports
module.exports =
  connect: (keys, baseUrl) ->
    ws = new PubSubWebSocket keys, baseUrl
    ws.connect()
    ws
