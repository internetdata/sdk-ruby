# frozen_string_literal: true

module InternetData
  # What a lookup of a domain answers.
  #
  # As with {Result}, an absent member is one your plan does not include, and
  # reads as `nil`, never as false: Unlimited answers whether the domain is
  # registered and which record types it has, and paid plans and the trial add
  # the records themselves, the network announcing each address, the other
  # domains on its first IPv4 address, its organization's IP ranges, Disposable
  # Domain, its home page and the domains redirecting or linking to it.
  # Each flag has the three readers {Result}'s have: `is_disposable`,
  # `disposable?` and `included?(:is_disposable)`.
  class DomainResult
    include Answer

    # The domain, lowercase and in punycode.
    def domain
      @raw['domain']
    end

    # Whether it is a registered domain (Domain List). Every answer.
    def is_registered
      @raw['is_registered']
    end

    # `is_registered` with an absent member read as false.
    def registered?
      @raw['is_registered'] == true
    end

    # Whether it is a disposable email domain (Disposable Domain), or nil when
    # your plan does not include it. Paid plans and the trial.
    def is_disposable
      @raw['is_disposable']
    end

    # `is_disposable` with an absent member read as false.
    def disposable?
      @raw['is_disposable'] == true
    end

    # Whether it has A records. Every answer.
    def has_a
      @raw['has_a']
    end

    # `has_a` with an absent member read as false.
    def has_a?
      @raw['has_a'] == true
    end

    # Whether it has AAAA records. Every answer.
    def has_aaaa
      @raw['has_aaaa']
    end

    # `has_aaaa` with an absent member read as false.
    def has_aaaa?
      @raw['has_aaaa'] == true
    end

    # Whether it has MX records. Every answer.
    def has_mx
      @raw['has_mx']
    end

    # `has_mx` with an absent member read as false.
    def has_mx?
      @raw['has_mx'] == true
    end

    # Whether it has NS records. Every answer.
    def has_ns
      @raw['has_ns']
    end

    # `has_ns` with an absent member read as false.
    def has_ns?
      @raw['has_ns'] == true
    end

    # Whether it has a CNAME record. Every answer.
    def has_cname
      @raw['has_cname']
    end

    # `has_cname` with an absent member read as false.
    def has_cname?
      @raw['has_cname'] == true
    end

    # Its records in Domain DNS, up to 100 a type, as a wire hash
    # (`result.dns['mx']`). Paid plans and the trial.
    def dns
      @raw['dns']
    end

    # The network announcing each address in `dns.a` and then `dns.aaaa`, from
    # IP ASN, as wire hashes (`result.hosting.first['asn']['name']`); `[]` where
    # it resolves to none. Paid plans and the trial.
    def hosting
      @raw['hosting']
    end

    # From IP Hosted Domains, as a wire hash: the other registered domains on
    # its first IPv4 address (`ip`), how many (`total`) and up to 10, the most
    # popular first (`domains`). Paid plans and the trial.
    def cohosted_domains
      @raw['cohosted_domains']
    end

    # Its organization's IP ranges, from Domain IP Ranges. Paid plans and the
    # trial.
    def ip_ranges
      @raw['ip_ranges']
    end

    # Detail for `is_disposable`, `{}` when it is false. Paid plans and the
    # trial.
    def disposable
      @raw['disposable']
    end

    # What our crawl last read of its home page, as a wire hash: `url`,
    # `title`, `description`, `last_seen` and the external hosts it links to
    # (`links`), each empty where it holds none. Paid plans and the trial.
    def web
      @raw['web']
    end

    # The registered domains whose home page redirects to it, as a wire hash:
    # how many (`total`) and up to 10, the most popular first (`domains`). Paid
    # plans and the trial.
    def redirects
      @raw['redirects']
    end

    # The registered domains whose home page links to it, as a wire hash: how
    # many (`total`) and up to 10, the most popular first (`domains`). Paid
    # plans and the trial.
    def backlinks
      @raw['backlinks']
    end

    # On answers to a key on the free plan only: false while its organization's
    # trial of every field lasts, true once the answer has Unlimited's; nil on any other.
    def trial_expired
      @raw['trial_expired']
    end

    # `trial_expired` with an absent member read as false.
    def trial_expired?
      @raw['trial_expired'] == true
    end

    # On answers to a key on a paid plan only: false while the answer has every
    # field, true once its organization's overage cap is reached and the answer
    # has Unlimited's, which is not billed; nil on any other.
    def cap_reached
      @raw['cap_reached']
    end

    # `cap_reached` with an absent member read as false.
    def cap_reached?
      @raw['cap_reached'] == true
    end

    def inspect
      "#<#{self.class} domain=#{domain.inspect} is_registered=#{is_registered.inspect}>"
    end
  end
end
