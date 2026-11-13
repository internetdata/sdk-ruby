# frozen_string_literal: true

# The published gem's lookups: without a key against prod's API and staging's,
# and with the CI key against staging's.
#
# Nothing here pins a field COUNT. A keyed answer is asserted to serve a
# superset of the keyless one, so a pricing change stays a pricing change
# instead of arriving as a red SDK build. What a keyless answer must satisfy:
# every member Unlimited answers, each present flag a real boolean, and a paid
# member ABSENT rather than false or 0.

require_relative '../lib/staging'

class LookupTest < Minitest::Test
  # A stable address with every Unlimited member populated, and the one the
  # README teaches.
  PROBE = '146.70.116.130'
  # A second public address: a keyless or free-plan batch of one is answered as
  # its lookup, so a refused batch sends two.
  SECOND = '8.8.8.8'
  ASN = 9009
  DOMAIN = 'example.com'
  # What Unlimited answers for an address, an AS and a domain.
  UNLIMITED = %w[ip is_bogon is_tor is_relay location asn company hostname abuse].freeze
  ASN_UNLIMITED = %w[asn name country registry allocated domain].freeze
  DOMAIN_UNLIMITED = %w[domain is_registered has_a has_aaaa has_mx has_ns has_cname].freeze

  def setup
    installed = Gem.loaded_specs['internetdata'].version
    skip "the lookups arrived in #{Staging::LOOKUPS_SINCE}, and #{installed} is installed" if
      installed < Staging::LOOKUPS_SINCE
  end

  def test_a_keyless_lookup_is_unlimiteds_answer_on_prod_and_staging
    [Staging::PROD_URL, Staging::BASE_URL].each do |base_url|
      result = keyless(base_url).lookup(PROBE)

      assert_equal PROBE, result.ip, base_url
      assert_equal false, result.is_bogon, "#{base_url}: a served answer is not a bogon"
      UNLIMITED.each { |field| assert result.included?(field), "#{base_url}: Unlimited answers #{field}" }
      assert_absent(result, %w[is_vpn is_hosting vpn whois hosted_domains trial_expired], base_url)
      InternetData::Result::FLAGS.each do |flag|
        next unless result.included?(flag)

        assert_includes [true, false], result.public_send(flag), "#{base_url}: #{flag} must be a real boolean"
      end
      %w[city latitude].each do |member|
        refute result.location.key?(member), "#{base_url}: location.#{member} is a paid member"
      end
    end
  end

  def test_a_keyless_asn_and_domain_lookup_is_unlimiteds_answer_on_prod_and_staging
    [Staging::PROD_URL, Staging::BASE_URL].each do |base_url|
      client = keyless(base_url)
      asn = client.lookup_asn(ASN)
      domain = client.lookup_domain(DOMAIN.upcase)

      assert_equal ASN, asn.asn, base_url
      ASN_UNLIMITED.each { |field| assert asn.included?(field), "#{base_url}: Unlimited answers #{field}" }
      assert_absent(asn, %w[type num_ips whois prefixes], base_url)
      assert_equal DOMAIN, domain.domain, "#{base_url}: the API answers the domain lowercase"
      DOMAIN_UNLIMITED.each { |field| assert domain.included?(field), "#{base_url}: Unlimited answers #{field}" }
      assert_absent(domain, %w[is_disposable dns ip_ranges disposable], base_url)
    end
  end

  def test_my_ip_answers_for_the_address_the_call_came_from_on_prod_and_staging
    [Staging::PROD_URL, Staging::BASE_URL].each do |base_url|
      result = keyless(base_url).my_ip

      assert_kind_of String, result.ip, base_url
      assert_equal false, result.is_bogon, "#{base_url}: a runner calls from a public address"
    end
  end

  def test_a_bogon_is_answered_without_touching_the_network
    client = keyless(Staging::BASE_URL)
    before = Staging.facts.length

    result = client.lookup('10.0.0.1')

    assert result.bogon?, 'a private address must be answered as a bogon'
    assert InternetData.bogon?('10.0.0.1'), 'the module function must agree with the client'
    assert_equal before, Staging.facts.length, 'the bogon path reached the network'
    # The widest shape whatever the plan.
    InternetData::Result::FLAGS.each do |flag|
      assert_equal false, result.public_send(flag), "#{flag} must be present and false on a bogon"
    end
  end

  def test_a_batch_without_a_key_is_refused_once_and_its_bogon_still_answered
    client = keyless(Staging::BASE_URL, cache: false)
    before = Staging.facts.length

    results = client.lookup_batch([PROBE, SECOND, '10.0.0.1'])

    assert results['10.0.0.1'].bogon?, '10.0.0.1 was not answered locally'
    refused = results[PROBE]
    assert_kind_of InternetData::Error, refused, 'a batch without a key must fail'
    assert_equal [:unauthorized, 401, false], [refused.kind, refused.status, refused.retryable?]
    assert_equal ['/batch'], Staging.facts[before..].map(&:path), 'one request, never retried'
    assert_equal [PROBE, SECOND], Staging.facts.last.ips, 'the bogon never left the client'
  end

  # Checked before any comparison: an unsent key answers the keyless shape,
  # which satisfies the containment below vacuously.
  def test_the_ci_key_reaches_the_wire_and_its_answer_contains_the_keyless_one
    skip Staging.skip_reason if Staging.skip_reason
    keyed = keyed_answer.raw
    keyless_fields = keyless(Staging::BASE_URL).lookup(PROBE).raw.keys

    (keyless_fields - keyed.keys).each { |field| flunk "the CI key's answer drops #{field}" }
    # A free-plan key's first 100 lookups of the UTC day are answered in full,
    # and the rest as Unlimited's: which half a run sees depends on the day.
    if keyed.key?('trial_expired')
      assert_equal !keyed['trial_expired'], keyed.key?('is_vpn'), 'trial_expired says which answer this is'
    end
  end

  def test_my_entitlement_reads_the_ci_keys_plan_and_usage
    skip Staging.skip_reason if Staging.skip_reason
    entitlement = Staging.entitlement

    assert_kind_of String, entitlement.plan.key
    assert_operator entitlement.usage.requests, :>=, 0
    assert_operator entitlement.usage.window_end, :>, entitlement.usage.window_start
  end

  def test_a_free_plan_keys_batch_of_two_is_refused_as_a_bad_request_once
    skip_unless_free_plan
    client = Staging.client(cache: false)
    before = Staging.facts.length

    results = client.lookup_batch([PROBE, SECOND])

    [PROBE, SECOND].each do |ip|
      refused = results[ip]
      assert_kind_of InternetData::Error, refused, "#{ip}: a free-plan key's batch of two must fail"
      assert_equal [:bad_request, 402, false], [refused.kind, refused.status, refused.retryable?]
    end
    assert_equal ['/batch'], Staging.facts[before..].map(&:path), 'one request, never retried'
    assert Staging.facts.last.carried_key, 'the key never reached the wire'
  end

  def test_a_free_plan_keys_batch_of_one_is_answered
    skip_unless_free_plan

    answer = Staging.client(cache: false).lookup_batch([PROBE])[PROBE]

    refute_kind_of InternetData::Error, answer, "a free-plan key's batch of one failed"
    assert_includes [true, false], answer.trial_expired, 'the answer carries trial_expired'
  end

  private

  def keyless(base_url, **options)
    Staging.facts
    InternetData::Client.new(base_url: base_url, **options)
  end

  def keyed_answer
    @keyed_answer ||= begin
      before = Staging.facts.length
      result = Staging.client.lookup(PROBE)
      sent = Staging.facts[before..]
      assert(sent.any? { |fact| fact.origin == Staging::BASE_URL && fact.carried_key },
             'the key never reached the wire')
      result
    end
  end

  def skip_unless_free_plan
    skip Staging.skip_reason if Staging.skip_reason
    tier = Staging.entitlement.plan.tier
    skip "the CI key is on the #{tier} plan, and this pins the free plan's batch" unless tier == 'free'
  end

  def assert_absent(result, fields, where)
    fields.each do |field|
      assert_nil result.public_send(field), "#{where}: #{field} is not in Unlimited, so it must be absent"
      refute result.included?(field), "#{where}: #{field} must not be reported as included"
      predicate = "#{field.delete_prefix('is_')}?"
      next unless result.respond_to?(predicate)

      assert_equal false, result.public_send(predicate), "#{where}: #{predicate} must answer false, never nil"
    end
  end
end
