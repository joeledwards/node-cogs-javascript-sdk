
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
  constructor: (message, cause) -> super message, cause

class MonitorError extends CogsError
  constructor: (message, cause) -> super message, cause

class TimeoutError extends CogsError
  constructor: (message, cause) -> super message, cause

class PushError extends CogsError
  constructor: (message, cause) -> super message, cause

class AuthKeyError extends CogsError
  constructor: (message, cause) -> super message, cause

class ApiError extends CogsError
  constructor: (message, cause, statusCode, details) ->
    super message, cause, statuscode, details

class InfoError extends CogsError
  constructor: (message, cause, statusCode, details) ->
    super message, cause, statuscode, details

class ToolsError extends CogsError
  constructor: (message, cause, statusCode, details) ->
    super message, cause, statuscode, details

class PubSubError extends CogsError
  constructor: (message, cause, statusCode, details) ->
    super message, cause, statuscode, details

class PubSubFailureResponse extends PubSubError
  constructor: (message, cause, statusCode, details, @record) ->
    super message, cause, statuscode, details

module.exports =
  ApiError: ApiError
  AuthKeyError: AuthKeyError
  CogsError: CogsError
  ConfigError: ConfigError
  InfoError: InfoError
  MonitorError: MonitorError
  PubSubError: PubSubError
  PubSubFailureResponse: PubSubFailureResponse
  PushError: PushError
  TimeoutError: TimeoutError
  ToolsError: ToolsError
