# frozen_string_literal: true

# The published gem's `oauth` accessor against the staging authorization server,
# on a client built with NO key. Only what is safe to repeat: discovery, a revoke
# and an exchange of junk, and at most ONE device authorization per run, which
# nobody approves and which is never polled.

require_relative '../lib/staging'

class OauthTest < Minitest::Test
  # The one client ID the server holds, already public in the CLI's source.
  CLIENT_ID = 'internetdata-cli'
  SINCE = Gem::Version.new('2.3.0')
  # The console's device page. The API is served at the apex here, so a page
  # derived from the API host would be the landing page's, which a `/device`
  # suffix check alone still passes.
  DEVICE_PAGE = 'https://app-staging.internetdata.io/device'

  def setup
    installed = Gem.loaded_specs['internetdata'].version
    skip "the oauth accessor arrived in #{SINCE}, and #{installed} is installed" if installed < SINCE

    @oauth = InternetData::Client.new(base_url: Staging::BASE_URL).oauth
  end

  def test_metadata_names_the_host_it_was_asked_on
    metadata = @oauth.metadata

    assert_equal Staging::BASE_URL, metadata.issuer
    refute_nil metadata.device_authorization_endpoint
    assert_includes metadata.code_challenge_methods_supported, 'S256'
  end

  def test_revoking_junk_succeeds
    assert_nil @oauth.revoke(CLIENT_ID, 'mo_rt_sdk-ci-not-a-token')
  end

  def test_exchanging_an_unknown_device_code_is_an_expired_token
    error = assert_raises(InternetData::OauthExpiredTokenError) do
      @oauth.exchange_device_code(CLIENT_ID, 'mo_dc_sdk-ci-not-a-code')
    end

    assert_equal 400, error.status
  end

  # 30 a minute per source address, shared by every SDK's run, so a slow_down is
  # a pass: it is the server answering this request correctly.
  def test_one_device_authorization_starts_a_sign_in
    device = @oauth.device_authorization(CLIENT_ID, scope: 'account.read')

    refute_empty device.device_code
    refute_empty device.user_code
    assert_equal DEVICE_PAGE, device.verification_uri
    assert_operator device.expires_in, :>, 0
    assert_operator device.interval, :>, 0
  rescue InternetData::OauthRequestError => e
    assert_equal 'slow_down', e.error_code
  end
end
