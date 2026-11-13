# frozen_string_literal: true

module InternetData
  # What every lookup answer shares: the response exactly as it came off the
  # wire, and whether your plan carries a member at all.
  module Answer
    # The response exactly as it came off the wire, with its original names.
    # Frozen, because the cache hands this same object to every later caller of
    # the address.
    attr_reader :raw

    def initialize(raw)
      @raw = deep_freeze(raw)
      freeze
    end

    # Whether your plan includes a member at all, told apart from a member your
    # plan includes that answered false.
    #
    #   result.included?(:is_vpn)   # => false, not in your plan
    #   result.is_vpn               # => nil
    def included?(field)
      @raw.key?(field.to_s)
    end

    def to_h
      @raw
    end

    def ==(other)
      other.is_a?(self.class) && other.raw == @raw
    end
    alias eql? ==

    def hash
      [self.class, @raw].hash
    end

    private

    def deep_freeze(value)
      case value
      when Hash then value.each { |_, v| deep_freeze(v) }.freeze
      when Array then value.each { |v| deep_freeze(v) }.freeze
      else value.freeze
      end
    end
  end

  # What a lookup of an address answers.
  #
  # An **absent** member is one your plan does not include. It never means "we
  # could not check", so `nil` and `false` are genuinely different answers: `nil`
  # is "not in your plan", `false` is "checked, and no".
  #
  # Ruby makes that easy to lose, because `nil` and `false` are both falsy. Read
  # the field itself (`is_vpn`) when the difference matters, ask {#included?}
  # when you need to know whether your plan carries it at all, and use the
  # predicate (`vpn?`) when you only care whether the address is flagged. A
  # predicate always answers `true` or `false`, never `nil`.
  #
  # A detail object that is present but empty (`{}`, or Web IP's `[]`) means the
  # flag above it is false. A populated one always carries every one of its keys.
  # Details and objects are the wire hashes with their original string keys, so
  # `result.vpn['provider']`, and the same holds inside them: a member a plan
  # leaves out of an object, such as `location['city']`, is absent, never empty.
  class Result
    include Answer

    FLAGS = %w[
      is_vpn is_tor is_relay is_resproxy is_dcproxy is_mobproxy is_pubproxy is_hosting is_cdn is_anycast
      is_carrier is_satellite is_ssh is_smtp is_web is_dns_resolver is_bittorrent
    ].freeze

    # The detail object behind each flag that has one; `is_anycast` has none.
    DETAILS = %w[
      vpn tor relay resproxy dcproxy mobproxy pubproxy hosting cdn carrier satellite ssh smtp dns_resolver
      bittorrent
    ].freeze

    # The details that are a list of rows rather than one object.
    DETAIL_LISTS = %w[web].freeze

    # The address that was looked up, normalized: `::ffff:a.b.c.d` answers as
    # `a.b.c.d`.
    def ip
      @raw['ip']
    end

    # Whether the address is reserved space, answered from the address alone.
    # Every answer. A bogon never reaches the network: this library answers it.
    def is_bogon
      @raw['is_bogon']
    end

    # `is_bogon` with an absent member read as false.
    def bogon?
      @raw['is_bogon'] == true
    end

    # Whether the address is a VPN service's server (VPN IP), or nil when your
    # plan does not include it. Paid plans and the trial.
    def is_vpn
      @raw['is_vpn']
    end

    # `is_vpn` with an absent member read as false.
    def vpn?
      @raw['is_vpn'] == true
    end

    # Whether the address is a Tor exit (Tor IP). Every answer.
    def is_tor
      @raw['is_tor']
    end

    # `is_tor` with an absent member read as false.
    def tor?
      @raw['is_tor'] == true
    end

    # Whether the address is an anonymizing relay such as iCloud Private Relay
    # (Relay IP). Every answer.
    def is_relay
      @raw['is_relay']
    end

    # `is_relay` with an absent member read as false.
    def relay?
      @raw['is_relay'] == true
    end

    # Whether the address is a residential proxy exit in Residential Proxy IP's
    # 90-day window, or nil when your plan does not include it. Paid plans and
    # the trial.
    def is_resproxy
      @raw['is_resproxy']
    end

    # `is_resproxy` with an absent member read as false.
    def resproxy?
      @raw['is_resproxy'] == true
    end

    # Whether the address is in Datacenter Proxy IP's 90-day window, or nil when
    # your plan does not include it. Paid plans and the trial.
    def is_dcproxy
      @raw['is_dcproxy']
    end

    # `is_dcproxy` with an absent member read as false.
    def dcproxy?
      @raw['is_dcproxy'] == true
    end

    # Whether the address is in Mobile Proxy IP's 90-day window, or nil when your
    # plan does not include it. Paid plans and the trial.
    def is_mobproxy
      @raw['is_mobproxy']
    end

    # `is_mobproxy` with an absent member read as false.
    def mobproxy?
      @raw['is_mobproxy'] == true
    end

    # Whether a public proxy listens on the address or its traffic left from it
    # (Public Proxy IP), or nil when your plan does not include it. Paid plans
    # and the trial.
    def is_pubproxy
      @raw['is_pubproxy']
    end

    # `is_pubproxy` with an absent member read as false.
    def pubproxy?
      @raw['is_pubproxy'] == true
    end

    # Whether the address is on a hosting or cloud network (Hosting IP), or nil
    # when your plan does not include it. Paid plans and the trial.
    def is_hosting
      @raw['is_hosting']
    end

    # `is_hosting` with an absent member read as false.
    def hosting?
      @raw['is_hosting'] == true
    end

    # Whether the address is on a content delivery network (CDN IP), or nil when
    # your plan does not include it. Paid plans and the trial.
    def is_cdn
      @raw['is_cdn']
    end

    # `is_cdn` with an absent member read as false.
    def cdn?
      @raw['is_cdn'] == true
    end

    # Whether the address is announced from many places at once (Anycast IP).
    # Every answer.
    def is_anycast
      @raw['is_anycast']
    end

    # `is_anycast` with an absent member read as false.
    def anycast?
      @raw['is_anycast'] == true
    end

    # Whether the address is in a mobile carrier's address space (Carrier IP).
    # Every answer.
    def is_carrier
      @raw['is_carrier']
    end

    # `is_carrier` with an absent member read as false.
    def carrier?
      @raw['is_carrier'] == true
    end

    # Whether the address is in a satellite operator's address space (Satellite
    # IP). Every answer.
    def is_satellite
      @raw['is_satellite']
    end

    # `is_satellite` with an absent member read as false.
    def satellite?
      @raw['is_satellite'] == true
    end

    # Whether an SSH server answered on the address (SSH IP). Every answer.
    def is_ssh
      @raw['is_ssh']
    end

    # `is_ssh` with an absent member read as false.
    def ssh?
      @raw['is_ssh'] == true
    end

    # Whether a mail server answered on the address (SMTP IP). Every answer.
    def is_smtp
      @raw['is_smtp']
    end

    # `is_smtp` with an absent member read as false.
    def smtp?
      @raw['is_smtp'] == true
    end

    # Whether a web server answered on the address on port 80 or 443 (Web IP).
    # Every answer.
    def is_web
      @raw['is_web']
    end

    # `is_web` with an absent member read as false.
    def web?
      @raw['is_web'] == true
    end

    # Whether an open DNS resolver answered on the address (DNS Resolver IP).
    # Every answer.
    def is_dns_resolver
      @raw['is_dns_resolver']
    end

    # `is_dns_resolver` with an absent member read as false.
    def dns_resolver?
      @raw['is_dns_resolver'] == true
    end

    # Whether a BitTorrent client was seen on the address in the last 90 days
    # (BitTorrent IP). Every answer.
    def is_bittorrent
      @raw['is_bittorrent']
    end

    # `is_bittorrent` with an absent member read as false.
    def bittorrent?
      @raw['is_bittorrent'] == true
    end

    # VPN IP's row for the address. Paid plans and the trial.
    def vpn
      @raw['vpn']
    end

    # Tor IP's row. Every answer.
    def tor
      @raw['tor']
    end

    # Relay IP's row. Every answer.
    def relay
      @raw['relay']
    end

    # Detail for `is_resproxy`. Paid plans and the trial.
    def resproxy
      @raw['resproxy']
    end

    # Detail for `is_dcproxy`. Paid plans and the trial.
    def dcproxy
      @raw['dcproxy']
    end

    # Detail for `is_mobproxy`. Paid plans and the trial.
    def mobproxy
      @raw['mobproxy']
    end

    # Detail for `is_pubproxy`. Paid plans and the trial.
    def pubproxy
      @raw['pubproxy']
    end

    # Detail for `is_hosting`. Paid plans and the trial.
    def hosting
      @raw['hosting']
    end

    # Detail for `is_cdn`. Paid plans and the trial.
    def cdn
      @raw['cdn']
    end

    # Detail for `is_carrier`. Paid plans and the trial.
    def carrier
      @raw['carrier']
    end

    # Detail for `is_satellite`. Paid plans and the trial.
    def satellite
      @raw['satellite']
    end

    # Detail for `is_ssh`. Paid plans and the trial.
    def ssh
      @raw['ssh']
    end

    # Detail for `is_smtp`. Paid plans and the trial.
    def smtp
      @raw['smtp']
    end

    # Detail for `is_web`: a row per port that answered, lowest first. Paid plans
    # and the trial.
    def web
      @raw['web']
    end

    # Detail for `is_dns_resolver`. Paid plans and the trial.
    def dns_resolver
      @raw['dns_resolver']
    end

    # Detail for `is_bittorrent`. Paid plans and the trial.
    def bittorrent
      @raw['bittorrent']
    end

    # Where the address is, as a wire hash (`result.location['country']`).
    # Every answer; the city and finer members on paid plans and the trial.
    def location
      @raw['location']
    end

    # The network announcing the address, from IP ASN, as a wire hash
    # (`result.asn['name']`), with asn 0 where none does. Every answer.
    def asn
      @raw['asn']
    end

    # Who uses the address, from IP Company. Every answer.
    def company
      @raw['company']
    end

    # The name the address's reverse DNS (PTR) record points to in IP RDNS,
    # empty when it has none. Every answer.
    def hostname
      @raw['hostname']
    end

    # Where to report abuse, from IP Abuse Contact. Every answer; the contact's
    # name, phone and the rest on paid plans and the trial.
    def abuse
      @raw['abuse']
    end

    # IP Whois's most specific record covering the address. Paid plans and the
    # trial.
    def whois
      @raw['whois']
    end

    # IP RWHOIS's most specific network covering the address. Paid plans and
    # the trial.
    def rwhois
      @raw['rwhois']
    end

    # How many domains IP Hosted Domains finds on the address, as
    # `{'total' => n}`: a count, never the list. Paid plans and the trial.
    def hosted_domains
      @raw['hosted_domains']
    end

    # On answers to a key on the free plan only: false while its organization's
    # daily trial lasts (every field for the first 100 lookups each UTC day),
    # true once the answer has Unlimited's; nil on any other answer.
    def trial_expired
      @raw['trial_expired']
    end

    # `trial_expired` with an absent member read as false.
    def trial_expired?
      @raw['trial_expired'] == true
    end

    def inspect
      "#<#{self.class} ip=#{ip.inspect} is_bogon=#{is_bogon.inspect} is_vpn=#{is_vpn.inspect}>"
    end
  end
end
