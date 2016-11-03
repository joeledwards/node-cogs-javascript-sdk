P = require 'bluebird'
moment = require 'moment'
request = require 'request'

config = require './config'
errors = require './errors'
logger = require './logger'

class InfoClient
  constructor: (@cfg) ->
    @_initialized = true

  baseUrl: -> @cfg?.base_url ? undefined

  getStatus: ->
    @makeRequest 'GET', "/status"

  getApiDocs: ->
    @makeRequest 'GET', "/api-docs"

  getBuildInfo: ->
    @makeRequest 'GET', "/build_info"

  makeRequest: (method, path, data) ->
    new P (resolve, reject) =>
      url = "#{@baseUrl()}#{path}"
      options =
        uri: url
        method: method
        timeout: @cfg.http_request_timeout

      request options, (error, response) ->
        if error?
          reject new errors.InfoError("Error attempting to send a request to the Cogs server", error)
        else if response.statusCode != 200
          try
            record = JSON.parse json
            json = JSON.stringify record, null, 2
            reject new errors.InfoError("Received an error response from the server", undefined, response.statusCode, json)
          catch error
            reject new errors.InfoError("Received an error response from the server", undefined, response.statusCode, response.body)
        else
          try
            resolve JSON.parse(response.body)
          catch error
            reject new errors.InfoError("Error parsing response body (expected valid JSON)", error)


# exports
module.exports =
  getClient: (configPath) ->
    config.getConfig configPath
    .then (cfg) ->
      logger.setLogLevel(cfg.log_level) if cfg.log_level?
      new InfoClient(cfg)
  
  getClientWithConfig: (cfg) ->
    logger.setLogLevel(cfg.log_level) if cfg.log_level?
    P.resolve(new InfoClient(cfg))

