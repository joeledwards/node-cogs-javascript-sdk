_ = require 'lodash'
crypto = require 'crypto'
moment = require 'moment'
xor = require 'buffer-xor'

errors = require './errors'

KEY_PARTS = ['R', 'W', 'A']

# Parse and validate a project key.
splitKey = (key) ->
  parts = key.split '-'
  
  if parts.length != 3
    throw new errors.AuthKeyError "Invalid format for project key.", undefined
  
  [perm, identity, permKey] = parts
  
  if not KEY_PARTS.includes perm
    throw new errors.AuthKeyError "Invalid permission prefix for project key.", undefined

  if not identity.match(/^[0-9a-fA-F]+$/)
    throw new errors.AuthKeyError "Invalid format for key identity.", undefined

  if not permKey.match(/^[0-9a-fA-F]+$/)
    throw new errors.AuthKeyError "Invalid format for perm key.", undefined
  
  {
    perm: perm,
    identity: identity,
    key: permKey
  }

# Assemble the auth data
socketAuth = (keys) ->
  if keys.length < 1
    throw errors.AuthKeyException "No keys supplied.", undefined

  keys = _.uniqBy keys, (key) -> key.substr(0, 1)
  keyObjs = keys.map (key) -> splitKey key

  perms = keyObjs
  .map ({perm}) -> perm
  .join ''

  identity = _(keyObjs)
  .map ({identity}) -> identity
  .first()

  record =
    identity: identity
    permissions: perms
    timestamp: moment.utc().toISOString()
  
  sigs = _(keyObjs)
  .map ({key}) -> signRecord key, record
  .value()

  hmac = _(sigs)
  .map ({hmac}) -> new Buffer hmac, 'hex'
  .reduce xor, Buffer.alloc 32
  
  auth = _(sigs).first()
  auth.hmac = hmac.toString 'hex'
  auth.json = auth.buffer.toString()
  
  auth

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
  socketAuth: socketAuth
