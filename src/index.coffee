# Vendor
p = require 'path'
Promise = require 'bluebird'
RateLimiter = require('limiter').RateLimiter
# promisify for better control flow
gaRateLimiter = Promise.promisifyAll new RateLimiter 1, 1000

# ==========

gaMaxRowsPerRequest = 10000

class GaExtractor
  constructor: (@config) ->
    throw new Error "clientEmail is required." if !@config.clientEmail
    if !@config.keyPath and !@config.keyContent
      throw new Error "Must provide either path to Service Account .pem key file, or key's content as string."

    @gApi = require "googleapis"
    @ga = Promise.promisifyAll @gApi.analytics({
      version: 'v3'
      params:
        "max-results": gaMaxRowsPerRequest # always extract everything API will return
        'ids': ('ga:' + @config.profileId) if @config.profileId
    }).data.ga

    # define auth obj; needed for initial auth & extractions
    @authClient = new @gApi.auth.JWT(
      @config.clientEmail,
      @config.keyPath, # key as .pem file
      @config.keyContent,
      "https://www.googleapis.com/auth/analytics.readonly", # scope uri
      @impersonatedUser
    )
    return

  auth: -> new Promise (resolve, reject) =>
    @authClient.authorize (err, token) ->
      # returns expiry_date: 1406182540 (16 days) and refresh_token: 'jwt-placeholder'
      if err
        reject new Error "OAuth error; err = #{ err.error }"
      else
        resolve token
      return
    @gApi.options auth: @authClient
    return

  extract: (queryObj) ->
    # limit # of concurrent requests to not hammer GA server
    @auth().bind(@).then gaRateLimiter.removeTokensAsync 1
      .then ->
        # .get(0) - for some reason data[1] is whole object returned by request again
        @ga.getAsync(queryObj).get(0).bind(@).then (data) ->
          results = data.rows
          return results unless data.totalResults > gaMaxRowsPerRequest

          # if totalResults > GA single request limit, paginate until all data's extracted
          runPromises = []
          runs = Math.ceil data.totalResults / gaMaxRowsPerRequest
          queryObj["start-index"] = gaMaxRowsPerRequest + 1
          while runs -= 1
            runPromise = @ga.getAsync(queryObj).get(0).then (data) ->
              results = results.concat data.rows
              return
            runPromises.push runPromise
            queryObj["start-index"] += gaMaxRowsPerRequest
          Promise.all(runPromises).then -> results
      .catch (err) ->
        throw new Error "Extraction error, err = #{ err.message }"
        return

# ==========

module.exports = GaExtractor