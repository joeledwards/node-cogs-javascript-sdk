P = require 'bluebird'
EventEmitter = require 'eventemitter3'
{client: nodeWs, w3cwebsocket: browserWs} = require 'websocket'

class BaseWS extends EventEmitter
  constructor: (@url, @headers, timeout) ->
    super()

    @config =
      closeTimeout: timeout
      keepaliveInterval: 15000

# Node.js WebSocket
class NodeWS extends BaseWS
  constructor: (url, headers, timeout) ->
    super(url, headers, timeout)

    @socket = new nodeWs(@config)
    @connection = null

    @socket.on 'connectFailed', (error) =>
      setTimeout => @emit 'connectFailed', error

    @socket.on 'connect', (connection) =>
      @connection = connection

      connection.on 'error', (error) =>
        setTimeout => @emit 'error', error

      connection.on 'message', (message) =>
        try
          setTimeout => @emit 'message', message.utf8Data
        catch error
          setTimeout => @emit 'error', error
          

      connection.on 'close', =>
        setTimeout => @emit 'close'

      setTimeout => @emit 'open'

    @socket.connect url, undefined, undefined, headers

  # Close the connection if it has been established
  close: ->
    new P (resolve, reject) =>
      if @connection?
        @connection.once 'error', (error) => reject error
        @connection.once 'close', => resolve()
        @connection.close()
        @connection = null
        @socket = null
      else
        resolve()

  ping: ->
    @connection.ping() if @connection?

  send: (data) ->
    new P (resolve, reject) => 
      if @connection?
        @connection.send data, (error) ->
          if error?
            reject error
          else
            resolve()
      else
        reject new Error("Not connected.")


# Browser WebSocket
class BrowserWS extends BaseWS
  constructor: (url, headers, timeout) ->
    super(url, headers, timeout)

    @connected = false

    @socket = new browserWs(url, undefined, undefined, headers, @config)

    @socket.onopen =>
      @connected = true
      setImmediate => @emit 'open'

    @socket.onmessage (message) =>
      setImmediate => @emit 'message', message

    @socket.onclose =>
      setImmediate => @emit 'close'

    @socket.onerror (error) =>
      if @connected
        setImmediate => @emit 'error', error
      else
        setImmediate => @emit 'connectFailed', error

  # Close the WebSocket if it exists
  close: ->
    new P (resolve, reject) =>
      if @socket?
        @socket.onerror (error) => reject error
        @socket.onclose => resolve()
        @socket.close()
        @socket = null
      else
        resolve()

  ping: ->
    @socket.ping() if @socket?

  send: (data) ->
    new P (resolve, reject) =>
      if @socket?
        @socket.send data, (error) ->
          if error?
            reject error
          else
            resolve()
      else
        reject new Error("Not connected.")
    

isNode = new Function "try {return this===global;}catch(e){return false;}"

module.exports = -> if isNode() then NodeWS else BrowserWS

