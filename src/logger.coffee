_ = require 'lodash'
moment = require 'moment'
winston = require 'winston'

winston.exitOnError = false

logger = undefined
setupLogger = (level = 'error') ->
  if level == 'off'
    logger = undefined
  else
    consoleConfig =
      level: level
      timestamp: -> moment.utc().toISOString()
    logger = new (winston.Logger)({
      exitOnError: false
      transports: [ new (winston.transports.Console)(consoleConfig) ]
    })

log = (level, text, args...) ->
  if logger?
    if _.isString(text)
      logger.log level, "[cogs-sdk]: #{text}", args...
    else
      logger.log level, "[cogs-sdk]: ", text, args...

setupLogger()

module.exports =
  setLogLevel: (level) -> setupLogger level
  setErrorLevel: -> setupLogger 'error'
  setWarnLevel: -> setupLogger 'warn'
  setInfoLevel: -> setupLogger 'info'
  setVerboseLevel: -> setupLogger 'verbose'
  setDebugLevel: -> setupLogger 'debug'
  turnLoggerOff: -> setupLogger 'off'
  log: (args...) -> log args...
  error: (args...) -> log 'error', args...
  warn: (args...) -> log 'warn', args...
  info: (args...) -> log 'info', args...
  verbose: (args...) -> log 'verbose', args...
  debug: (args...) -> log 'debug', args...

