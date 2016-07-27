FS = require 'fs'
Joi = require 'joi'
Q = require 'q'

logger = require './logger'
errors = require './errors'

# valid the config object
validateWithJoi = (config) ->
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
    http_request_timeout: Joi.number().integer().min(250).max(900000).optional().default(30000, 'Default timeout of 30,000 milliseconds for HTTP requests.')
    websocket_connect_timeout: Joi.number().integer().min(250).max(900000).optional().default(30000, 'Default timeout of 30,000 milliseconds for WebSocket connects.')
    websocket_auto_reconnect: Joi.boolean().optional().default(true, 'Use this field to control auto-reconnect, defaults to true.')
    log_level: Joi.only('off', 'error', 'warn', 'info', 'verbose', 'debug').optional().default('error', 'Sets the log level for the SDK, defaults to "error"')
  })
  
  Q.nfcall Joi.validate, config, schema

# validate and supplement the config object
validateConfig = (configObj) ->
  d = Q.defer()
  config = validateWithJoi(configObj)
  .then (config) ->
    config.base_ws_url = config.base_url.replace(/http/, 'ws')
    d.resolve config
  .catch (error) ->
    err = new errors.ConfigError("Error validating the config", error)
    logger.error err
    d.reject err
  d.promise

# parse the JSON into the config object
parseConfig = (configJson) ->
  d = Q.defer()
  try
    configObj = JSON.parse configJson
    d.resolve validateConfig(configObj)
  catch error
    logger.error err
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
  validateConfig: validateConfig

