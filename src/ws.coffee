P = require 'bluebird'
EventEmitter = require 'eventemitter3'
{client: nodeWs, w3cwebsocket: browserWs} = require 'websocket'

class BaseWS extends EventEmitter
  constructor: (url, headers, timeout) ->
    super()
    @headers = headers
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
      @emit 'connectFailed', error

    @socket.on 'connect', (connection) =>
      @connection = connection

      connection.on 'error', (error) =>
        @emit 'error', error

      connection.on 'message', (message) =>
        try
          @emit 'message', message.utf8Data
        catch error
          @emit 'error', error
          

      connection.on 'close', =>
        @emit 'close'

      @emit 'open'

    @socket.connect url, undefined, undefined, headers

  # Close the WebSocket if it exists
  close: ->
    @connection.close() if @connection?
    @connection = null
    @socket = null

  ping: ->
    @connection.ping() if @connection?

  send: (data) ->
    new P((resolve, reject) => 
      if @connection?
        @connection.send data, (error) ->
          if error?
            reject error
          else
            resolve()
      else
        reject new Error("Not connected.")
    )


# Browser WebSocket
class BrowserWS extends BaseWS
  constructor: (url, headers, timeout) ->
    super(url, headers, timeout)

    @connected = false

    @socket = new browserWs(url, undefined, undefined, headers, @config)

    @socket.onopen =>
      @connected = true
      @emit 'open'

    @socket.onmessage (message) =>
      @emit 'message', message

    @socket.onclose =>
      @emit 'close'

    @socket.onerror (error) =>
      if @connected
        @emit 'error', error
      else
        @emit 'connectFailed', error

  # Close the WebSocket if it exists
  close: ->
    if @socket?
      @socket.close()
    @socket = null

  ping: ->
    @socket.ping() if @socket?

  send: (data) ->
    new P((resolve, reject) ->
      if @socket?
        @socket.send data, (error) ->
          if error?
            reject error
          else
            resolve()
      else
        reject "Not connected."
    )
    

isNode = new Function "try {return this===global;}catch(e){return false;}"

module.exports = -> if isNode() then NodeWS else BrowserWS

