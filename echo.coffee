require 'log-a-log'

P = require 'bluebird'
uuid = require 'uuid'
moment = require 'moment'
{api, tools} = require './src'

configFile = "#{process.env['HOME']}/cogs-qa.json"
namespace = 'chat'

channel =
  channel: uuid.v4()

getAttributes = ->
  channel: channel.channel
  timestamp: moment.utc().toISOString()
  message: "Hello, Cogs! [#{uuid.v4()}]"

getEventName = -> "chat-message-#{uuid.v1()}"
msgCount = 0

jsonify = (obj) -> JSON.stringify(obj, null, 2)
beautify = (json) -> jsonify(JSON.parse(json))

# Deliver one event to Cogs
sendAnEvent = (client) ->
  new P (resolve, reject) ->
    client.sendEvent namespace, getEventName(), getAttributes()
    .then (result) ->
      console.log "Event Sent:\n#{jsonify(result)}"
      resolve result
    .catch (error) ->
      console.error "Error sending event:", error
      reject error

# Setup the Cogs SDK
tools.getClient configFile
.then (client) -> client.getApiClientWithNewKey()
.then (client) ->
  console.log "Subscribing to channel #{JSON.stringify(channel)}"

  client.subscribe namespace, getAttributes(), false, 'echo-as-message'

  .then (ws) ->
    new P (resolve, reject) ->
      ws.once 'close', ->
        console.log 'Connection closed.'
        resolve()

      ws.on 'message', (message) ->
        msgCount += 1
        currCount = msgCount
        console.log "Received Message:\n#{beautify(message)}"

        msg = JSON.parse message

        ws.ack msg.message_id

        client.getMessage namespace, channel, msg.message_id
        .then (message) ->
          console.log "Fetched #{currCount} of 2 messages [#{msg.message_id}]"
          ws.close() if msgCount > 1
        .catch (error) ->
          console.error "Error fetching message:", error
          ws.close()

      ws.once 'ack', (messageId) ->
        console.log "A message has been acknowledged #{messageId}"

      ws.once 'error', (error) ->
        console.error "Error in push WebSocket:", error
        ws.close()
        reject error

      ws.once 'connectFailed', (error) ->
        console.error "Error connecting push WebSocket:", error
        reject error

      ws.once 'open', ->
        console.log "Push WebSocket opened."

        sendAnEvent client
        .then -> sendAnEvent client
        .catch (error) ->
          console.error "Error sending an event:", error
          ws.close()
          reject error

    .then ->
      client.getChannelSummary namespace, getAttributes()
      .then (summary) ->
        console.log "Channel summary:", summary
      .catch (error) ->
        console.error "Error fetching channel summary:", error

  .catch (error) ->
    console.error "Error subscribing to push WebSocket:", error

.catch (error) ->
  console.error "Error:", error

