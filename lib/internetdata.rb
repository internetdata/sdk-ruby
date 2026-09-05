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

require 'internetdata/errors'
require 'internetdata/retries'
require 'internetdata/transport'
require 'internetdata/database_api'
require 'internetdata/client'

# The official Ruby client library for the InternetData API.
#
#   client = InternetData::Client.new(api_key: ENV['INTERNETDATA_API_KEY'])
#   client.database.download('bogon_ip_v1', 'mmdb', './bogon_ip_v1.mmdb')
module InternetData
end
