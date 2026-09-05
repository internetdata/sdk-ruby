# frozen_string_literal: true

# The staging fixtures the test files share: the guard that this is the PUBLISHED
# gem, the request recorder, one client, and the budget that keeps a mistaken id
# from pulling a real database through CI.

require 'json'
require 'minitest/autorun'
require 'typhoeus'
require 'internetdata'

module Staging
  BASE_URL = 'https://staging.internetdata.io'

  # The credential is a read-only console key for one org, licensed to a couple
  # of the smallest published databases, so a run may download everything it is
  # entitled to and still move a few kilobytes.
  SECRET = 'INTERNETDATA_STAGING_KEY'

  # Every transfer is budgeted against `metadata`'s published size BEFORE it
  # starts. The licensed databases are under 4 KB; published ones reach 5.34 GiB,
  # so a mistyped id is the difference between a free run and a very slow one.
  SIZE_CEILING = 8 * 1024 * 1024

  module_function

  # The whole point of this package: exercise the gem a stranger installs.
  #
  # A suite pointed at the working tree passes every test and says nothing, and
  # bundler makes that easy to do by accident, so the resolved source is checked
  # rather than assumed. Called at load, so no test can run before it holds.
  def assert_published!
    spec = Gem.loaded_specs['internetdata']
    raise 'internetdata is not in the bundle at all' if spec.nil?

    if defined?(Bundler::Source::Path) && spec.source.is_a?(Bundler::Source::Path)
      raise "internetdata came from a path source at #{spec.gem_dir}, which is not a release"
    end

    repo = File.expand_path('../..', __dir__)
    if spec.gem_dir == repo || spec.gem_dir.start_with?("#{repo}/")
      raise "internetdata was loaded from #{spec.gem_dir}, inside this repository, not from RubyGems"
    end

    puts "==> testing internetdata #{spec.version} from #{spec.gem_dir}"
  end

  def key
    value = ENV[SECRET].to_s
    value.empty? ? nil : value
  end

  def skip_reason
    "#{SECRET} is not set" if key.nil?
  end

  # What a test is allowed to remember about a request it made.
  #
  # Only derived facts leave here. An assertion that fails prints its operands,
  # and these logs are public, so a request is recorded as an origin and a path
  # and the key itself is never held.
  Fact = Struct.new(:origin, :path, :carried_key, keyword_init: true)

  def facts
    @facts ||= begin
      # A `before` hook that answers nil or false SKIPS the request outright, and
      # a hook ending on an assignment does exactly that. It must return true.
      Typhoeus.before { |request| note(request) }
      []
    end
  end

  def note(request)
    uri = URI.parse(request.url)
    facts << Fact.new(origin: "#{uri.scheme}://#{uri.host}", path: uri.path,
                      carried_key: carries_key?(request))
    true
  end

  def carries_key?(request)
    secret = key
    return false if secret.nil?
    return true if request.url.include?(secret)

    (request.options[:headers] || {}).any? { |_, value| value.to_s.include?(secret) }
  end

  def client(**options)
    facts
    InternetData::Client.new(api_key: key, base_url: BASE_URL, **options)
  end

  # The families this org holds a live license for, which is what a download may
  # be attempted against. Everything else in the listing is published but not
  # bought, and asking for it is the refusal one of the tests wants.
  def licensed(databases)
    databases.select { |database| database.standing == 'licensed' }
  end

  def unlicensed(databases)
    databases.reject { |database| database.standing == 'licensed' }
  end
end

Staging.assert_published!
