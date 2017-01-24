assert = require 'assert'
durations = require '../src/index.coffee'
cogs = require '../src/errors.coffee'

describe "cogs-javascript-sdk", ->
  it "should work", (done) ->
    assert true, "Should be true"
    done()
  
  it "should detect classes", (done) ->
    error = new CogsError()
    assert(
      new Error() instanceof CogsError,
      "Should be an instance of CogsError")
    assert(
      new errors.CogsError() instanceof CogsError,
      "Should be an instance of CogsError")
    done()
      

