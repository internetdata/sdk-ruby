# frozen_string_literal: true

require 'typhoeus'

module InternetData
  DEFAULT_BASE_URL = 'https://internetdata.io'
  DEFAULT_RETRIES = 2
  DEFAULT_TIMEOUT = 30

  # A client for the InternetData API.
  #
  # Every database published today needs an API key carrying the `db.download`
  # scope, granted by contract one family at a time. The key is still OPTIONAL:
  # a client built without one sends no `Authorization` header at all, which is
  # what a database served without a license would need, and `oauth` needs none.
  class Client
    # The licensed database downloads, and everything about them.
    attr_reader :database
    # Signing a person in with OAuth, which needs no API key at all.
    attr_reader :oauth

    # @param api_key [String, nil] a key carrying the `db.download` scope. Omit
    #   it and no credential is sent; every database published today answers 401.
    # @param retries [Integer] extra attempts for a transient failure. Each waits
    #   the server's `Retry-After` when it sent one of at most about 24.8 days,
    #   and otherwise a backoff of 250 ms that doubles per retry.
    # @param timeout [Numeric] seconds allowed for one API call, 0 for no bound. It
    #   also bounds the CONNECT phase of a transfer, which is otherwise unlimited.
    # @raise [ArgumentError] for a `timeout` that is negative, not a finite number,
    #   or past 2147483.647 seconds (2**31 - 1 ms), the longest curl holds.
    # @param transport [Transport, nil] override the HTTP layer, mostly for tests.
    def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, retries: DEFAULT_RETRIES,
                   timeout: DEFAULT_TIMEOUT, transport: nil)
      @transport = transport || Transport.new(
        Transport::Config.new(api_key: api_key, base_url: base_url, timeout: timeout),
      )
      @database = DatabaseApi.new(@transport, retries: retries)
      @oauth = OauthApi.new(@transport, retries: retries)
    end
  end
end
