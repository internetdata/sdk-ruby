# frozen_string_literal: true

module InternetData
  # What a lookup of an AS answers.
  #
  # As with {Result}, an absent member is one your plan does not include, and
  # reads as `nil`, never as 0 or an empty string: Unlimited answers the AS's
  # registration (`asn`, `name`, `country`, `registry`, `allocated`, `domain`),
  # and paid plans and the trial add the rest. `whois` and `prefixes` are the
  # wire values with their original string keys.
  class AsnResult
    include Answer

    # The AS number.
    def asn
      @raw['asn']
    end

    # Its operator.
    def name
      @raw['name']
    end

    # The country its registry assigned it to.
    def country
      @raw['country']
    end

    # The registry that allocated it.
    def registry
      @raw['registry']
    end

    # When it was allocated.
    def allocated
      @raw['allocated']
    end

    # Its operator's domain.
    def domain
      @raw['domain']
    end

    # The kind of network it runs, or nil when your plan does not include it.
    # Paid plans and the trial.
    def type
      @raw['type']
    end

    # IPv4 addresses it announces. Paid plans and the trial.
    def num_ips
      @raw['num_ips']
    end

    # IPv4 prefixes it announces. Paid plans and the trial.
    def num_prefixes4
      @raw['num_prefixes4']
    end

    # IPv6 prefixes it announces. Paid plans and the trial.
    def num_prefixes6
      @raw['num_prefixes6']
    end

    # Its announcements RPKI calls valid. Paid plans and the trial.
    def rpki_valid
      @raw['rpki_valid']
    end

    # Its announcements RPKI calls invalid. Paid plans and the trial.
    def rpki_invalid
      @raw['rpki_invalid']
    end

    # Its announcements with no RPKI record. Paid plans and the trial.
    def rpki_not_found
      @raw['rpki_not_found']
    end

    # Its ASN Whois record, every column, empty where the registry states
    # nothing. Paid plans and the trial.
    def whois
      @raw['whois']
    end

    # What it announces, IPv4 then IPv6, up to 20000 a family, each with its
    # RPKI status. Paid plans and the trial.
    def prefixes
      @raw['prefixes']
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
      "#<#{self.class} asn=#{asn.inspect} name=#{name.inspect}>"
    end
  end
end
