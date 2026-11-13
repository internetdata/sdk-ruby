# frozen_string_literal: true

require 'internetdata/version'

# The wire layer, generated from spec/openapi.yaml by scripts/generate.sh.
# Models are loaded by glob because the set of them is the generator's to
# decide; they subclass ApiModelBase and so must follow it.
require 'internetdata/api_client'
require 'internetdata/api_error'
require 'internetdata/api_model_base'
require 'internetdata/configuration'
Dir[File.join(__dir__, 'internetdata', 'models', '*.rb')].sort.each { |model| require model }
Dir[File.join(__dir__, 'internetdata', 'api', '*.rb')].sort.each { |api| require api }

require 'internetdata/bogons'
require 'internetdata/errors'
require 'internetdata/result'
require 'internetdata/asn_result'
require 'internetdata/domain_result'
require 'internetdata/bogon'
require 'internetdata/cache'
require 'internetdata/retries'
require 'internetdata/transport'
require 'internetdata/database_api'
require 'internetdata/oauth_api'
require 'internetdata/client'

# The official Ruby client library for the InternetData API.
#
#   client = InternetData::Client.new
#   client.lookup('146.70.116.130').location['country']   # => "AT"
module InternetData
  # Whether an address is a bogon: private, loopback, link-local, documentation,
  # multicast or otherwise not routable on the public internet, including the
  # IPv6 equivalents and the 6to4 and Teredo ranges that wrap them.
  #
  # A client answers these itself, so they never cost a request. The same
  # predicate is on the client, which is how the README teaches it.
  def self.bogon?(ip)
    Bogon.bogon?(ip)
  end
end
