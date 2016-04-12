crypto = require 'crypto'

# Transform the record into JSON, UTF-8 encode it, sign with secret key
signRecord = (hexKey, record) ->
  json = JSON.stringify record

  keyBuffer = new Buffer(hexKey, 'hex')
  jsonBuffer = new Buffer(json, 'utf-8')
  jsonBufferB64 = jsonBuffer.toString 'base64'
  
  # Build the Payload-HMAC
  hmac = crypto.createHmac 'SHA256', keyBuffer
  hmac.update jsonBuffer
  hmacHexDigest = hmac.digest 'hex'

  signatureSummary =
    hmac: hmacHexDigest
    buffer: jsonBuffer
    bufferB64: jsonBufferB64
    contentLength: jsonBuffer.length
    record: record

  signatureSummary


# Exports
module.exports =
  signRecord: signRecord

