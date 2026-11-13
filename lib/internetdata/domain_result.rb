# frozen_string_literal: true

module InternetData
  # What a lookup of a domain answers.
  #
  # As with {Result}, an absent member is one your plan does not include, and
  # reads as `nil`, never as false: Unlimited answers whether the domain is
  # registered and which record types it has, and paid plans and the trial add
  # the records themselves, its organization's IP ranges and Disposable Domain.
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

    # On answers to a key on the free plan only: false while its organization's
    # daily trial lasts, true once the answer has Unlimited's; nil on any other.
    def trial_expired
      @raw['trial_expired']
    end

    # `trial_expired` with an absent member read as false.
    def trial_expired?
      @raw['trial_expired'] == true
    end

    def inspect
      "#<#{self.class} domain=#{domain.inspect} is_registered=#{is_registered.inspect}>"
    end
  end
end
