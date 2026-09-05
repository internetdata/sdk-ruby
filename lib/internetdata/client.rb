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
  # what a database served without a licence would need.
  class Client
    # The licensed database downloads, and everything about them.
    attr_reader :database

    # @param api_key [String, nil] a key carrying the `db.download` scope. Omit
    #   it and no credential is sent; every endpoint published today answers 401.
    # @param retries [Integer] extra attempts for a transient failure.
    # @param timeout [Numeric] seconds allowed for one API call. It also bounds the
    #   CONNECT phase of a transfer, which is otherwise unlimited.
    # @param transport [Transport, nil] override the HTTP layer, mostly for tests.
    def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, retries: DEFAULT_RETRIES,
                   timeout: DEFAULT_TIMEOUT, transport: nil)
      @transport = transport || Transport.new(
        Transport::Config.new(api_key: api_key, base_url: base_url, timeout: timeout),
      )
      @database = DatabaseApi.new(@transport, retries: retries)
    end
  end
end
