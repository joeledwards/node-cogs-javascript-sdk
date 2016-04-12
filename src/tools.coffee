_ = require 'lodash'
FS = require 'fs'
Q = require 'q'
moment = require 'moment'
request = require 'request'

api = require './api'
auth = require './auth'
config = require './config'
errors = require './errors'

# Create the record for use in authenticating the tools client
makeRecord = (cfg) ->
  record =
    access_key: cfg.api_key.access
    timestamp: moment.utc().toISOString()

makeSigned = (cfg) ->
  record = makeRecord cfg
  auth.signRecord cfg.api_key.secret, record

class ToolsClient
  constructor: (@cfg) ->
    @baseUrl = @cfg.base_url

  accessKey: -> @cfg?.api_key?.access
  secretKey: -> @cfg?.api_key?.secret

  getApiClientWithNewKey: ->
    @newClientKey()
    .then (record) =>
      apiCfg = _.cloneDeep(@cfg)
      apiCfg.api_key.secret = undefined
      apiCfg.client_key =
        salt: record.client_salt
        secret: record.client_secret

      api.getClientWithConfig apiCfg

  getNamespaceSchema: (namespace) ->
    data = makeSigned @cfg
    @makeRequest 'GET', "/namespace/#{namespace}/schema", data
    
  newRandomUuid: ->
    data = makeSigned @cfg
    @makeRequest 'POST', "/random_uuid", data

  newClientKey: ->
    data = makeSigned @cfg
    @makeRequest 'POST', "/client_secret", data

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
        d.reject new errors.ToolsError("Error attempting to send a request to the Cogs server", error)
      else if response.statusCode != 200
        try
          record = JSON.parse json
          json = JSON.stringify record, null, 2
          d.reject new errors.ToolsError("Received an error response from the server", undefined, response.statusCode, json)
        catch error
          d.reject new errors.ToolsError("Received an error response from the server", undefined, response.statusCode, response.body)
      else
        try
          d.resolve JSON.parse(response.body)
        catch error
          d.reject new errors.ToolsError("Error parsing response body (expected valid JSON)", error)

    d.promise


# exports
module.exports =
  getClient: (configPath) ->
    config.getConfig configPath
    .then (cfg) ->
      new ToolsClient(cfg)
  
  getClientWithConfig: (cfg) ->
    Q(new ToolsClient(cfg))

