P = require 'bluebird'
Joi = require 'joi'

fs = P.promisifyAll(require('fs'))

logger = require './logger'
errors = require './errors'

# valid the config object
validateWithJoi = (config) ->
  schema = Joi.object().keys({
    base_url: Joi.string().uri().optional().default("https://api.cogswell.io", "URL for the Cogswell API.")
    base_ws_url: Joi.string().uri().optional()
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
  
  P.promisify(Joi.validate)(config, schema)

# validate and supplement the config object
validateConfig = (configObj) ->
  new P (resolve, reject) ->
    config = validateWithJoi(configObj)
    .then (config) ->
      if not config.base_ws_url?
        config.base_ws_url = config.base_url.replace(/http/, 'ws')
      resolve config
    .catch (error) ->
      err = new errors.ConfigError("Error validating the config", error)
      logger.error err
      reject err

# parse the JSON into the config object
parseConfig = (configJson) ->
  new P (resolve, reject) ->
    try
      configObj = JSON.parse configJson
      resolve validateConfig(configObj)
    catch error
      logger.error err
      err = new errors.ConfigError("Error parsing config JSON", error)
      reject err

# read the config file
readConfig = (configPath) ->
  fs.readFileAsync configPath
  .then (configJson) ->
    parseConfig configJson

# check config exists and read
getConfig = (configPath) ->
  new P (resolve, reject) ->
    fs.exists configPath, (exists) ->
      if not exists
        reject new Error("Config file '#{configPath}' not found")
      else
        resolve readConfig(configPath)

# Parse a JSON file
readJson = (path) ->
  fs.readFileAsync path
  .then (raw) ->
    P.try(JSON.parse(raw))

# exports
module.exports =
  getConfig: getConfig
  readJson: readJson
  validateConfig: validateConfig

