FS = require 'fs'
Q = require 'q'
moment = require 'moment'
request = require 'request'

config = require './config'
errors = require './errors'

class InfoClient
  constructor: (@cfg) ->
    @baseUrl = @cfg.base_url

  getStatus: ->
    @makeRequest 'GET', "/status"

  getApiDocs: ->
    @makeRequest 'GET', "/api-docs"

  getBuildInfo: ->
    @makeRequest 'GET', "/build_info"

  makeRequest: (method, path, data) ->
    d = Q.defer()
    
    url = "#{@baseUrl}#{path}"
    options =
      uri: url
      method: method
      timeout: @cfg.http_request_timeout

    request options, (error, response) ->
      if error?
        d.reject new errors.InfoError("Error attempting to send a request to the Cogs server", error)
      else if response.statusCode != 200
        try
          record = JSON.parse json
          json = JSON.stringify record, null, 2
          d.reject new errors.InfoError("Received an error response from the server", undefined, response.statusCode, json)
        catch error
          d.reject new errors.InfoError("Received an error response from the server", undefined, response.statusCode, response.body)
      else
        try
          d.resolve JSON.parse(response.body)
        catch error
          d.reject new errors.InfoError("Error parsing response body (expected valid JSON)", error)

    d.promise


# exports
module.exports =
  getClient: (configPath) ->
    config.getConfig configPath
    .then (cfg) ->
      new InfoClient(cfg)
  
  getClientWithConfig: (cfg) ->
    Q(new InfoClient(cfg))

