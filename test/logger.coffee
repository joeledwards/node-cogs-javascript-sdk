assert = require 'assert'
logger = require '../src/logger'

describe "cogs-sdk-logger", ->
  it "should filter log statements below the configured level", (done) ->
    logger.setLogLevel 'warn'
    logger.turnLoggerOff()
    logger.error "Testing error"
    logger.warn "Testing warn"
    logger.info "Testing info [YOU SHOULD NOT SEE THIS]"
    logger.verbose "Testing verbose [YOU SHOULD NOT SEE THIS]"
    logger.debug "Testing debug [YOU SHOULD NOT SEE THIS]"

    logger.setInfoLevel()
    logger.error "Testing error"
    logger.warn "Testing warn"
    logger.info "Testing info"
    logger.verbose "Testing verbose [YOU SHOULD NOT SEE THIS]"
    logger.debug "Testing debug [YOU SHOULD NOT SEE THIS]"

    done()

  it "should permit any input valid for the underlying logger", (done) ->
    obj =
      a: 1
      b: 2
    logger.log 'info', "an object:", obj

    done()
