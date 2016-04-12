
class CogsError extends Error
  constructor: (@message, @cause, @statusCode, @details) ->
    super @message, @cause
    @stack = (new Error(@message)).stack

  toString: ->
    statusCode = if @statusCode? then "\nstatus-code: #{@statusCode}" else ""
    details = if @details? then "\ndetails: #{@details}" else ""
    stack = if @stack? then "\n#{@stack}" else ""
    causeStack = if @cause? then "\ncaused by:\n#{@cause.stack}" else ""

    "#{@message}#{statusCode}#{details}#{stack}#{causeStack}"

class ConfigError extends CogsError
  constructor: (@message, @cause) ->
    super @message, @cause

class MonitorError extends CogsError
  constructor: (@message, @cause) ->
    super @message, @cause

class TimeoutError extends CogsError
  constructor: (@message, @cause) ->
    super @message, @cause

class ApiError extends CogsError
class InfoError extends CogsError
class ToolsError extends CogsError

module.exports =
  ApiError: ApiError
  CogsError: CogsError
  ConfigError: ConfigError
  InfoError: InfoError
  MonitorError: MonitorError
  TimeoutError: TimeoutError
  ToolsError: ToolsError
