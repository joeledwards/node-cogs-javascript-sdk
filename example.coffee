Q = require 'q'
cogs = require './src'

cogs.info.getClient 'cogs-tools.json'

.then (client) ->
  Q.all [client.getApiDocs(), client.getBuildInfo()]

.then (data) ->
  console.log "API Docs:\n#{JSON.stringify(data[0], null, 2)}"
  console.log ''
  console.log "Build Info:\n#{JSON.stringify(data[1], null, 2)}"

.catch (error) ->
  console.error "Error fetching the Cogs data: #{error}\n#{error.stack}"
