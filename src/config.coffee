FS = require 'fs'
Joi = require 'joi'
Q = require 'q'

errors = require './errors'

# valid the config object
validateConfig = (config) ->
  schema = Joi.object().keys({
    base_url: Joi.string().uri().optional().default("https://api.cogswell.io", "URL for the Cogswell API.")
    api_key: Joi.object().keys({
      access: Joi.string().regex(/^[0-9a-fA-F]{32}$/).required()
      secret: Joi.string().regex(/^[0-9a-fA-F]{128}$/).optional()
    }).required()
    client_key: Joi.object().keys({
      salt:   Joi.string().regex(/^[0-9a-fA-F]{64}$/).required()
      secret: Joi.string().regex(/^[0-9a-fA-F]{64}$/).required()
    }).optional()
    http_request_timeout: Joi.number().integer().min(250).max(900000).optional().default(30000, "Default timeout of 30 seconds for HTTP requests.")
    websocket_connect_timeout: Joi.number().integer().min(250).max(900000).optional().default(30000, "Default timeout of 30 seconds for WebSocket connects.")
  })
  
  Q.nfcall Joi.validate, config, schema

# parse the JSON into the config object
parseConfig = (configJson) ->
  d = Q.defer()
  try
    rawConfig = JSON.parse configJson
    config = validateConfig(rawConfig)
    .then (config) ->
      config.base_ws_url = config.base_url.replace(/http/, 'ws')
      d.resolve config
    .catch (error) ->
      err = new errors.ConfigError("Error validating the config", error)
      console.error err
      d.reject err
  catch error
    console.error err
    err = new errors.ConfigError("Error parsing config JSON", error)
    d.reject err
  d.promise

# read the config file
readConfig = (configPath) ->
  Q.nfcall FS.readFile, configPath
  .then (configJson) ->
    parseConfig configJson

# check config exists and read
getConfig = (configPath) ->
  d = Q.defer()
  FS.exists configPath, (exists) ->
    if not exists
      d.reject new Error("Config file '#{configPath}' not found")
    else
      d.resolve readConfig(configPath)
  d.promise

# Parse a JSON file
readJson = (path) ->
  Q.nfcall FS.readFile, path
  .then (raw) ->
    Q(JSON.parse(raw))

# exports
module.exports =
  getConfig: getConfig
  readJson: readJson

