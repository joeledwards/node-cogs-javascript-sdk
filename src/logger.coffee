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
  if typeof text is string
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
  log: (args...) -> logger.log args... if logger?
  error: (args...) -> logger.error args... if logger?
  warn: (args...) -> logger.warn args... if logger?
  info: (args...) -> logger.info args... if logger?
  verbose: (args...) -> logger.verbose args... if logger?
  debug: (args...) -> logger.debug args... if logger?

