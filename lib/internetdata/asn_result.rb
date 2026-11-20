# frozen_string_literal: true

module InternetData
  # What a lookup of an AS answers.
  #
  # As with {Result}, an absent member is one your plan does not include, and
  # reads as `nil`, never as 0 or an empty string: Unlimited answers the AS's
  # registration (`asn`, `name`, `country`, `registry`, `allocated`, `domain`),
  # and paid plans and the trial add the rest. `whois` and `prefixes` are the
  # wire values with their original string keys, as are `hosted_domains` and
  # the neighbor lists.
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

    # Its rank in ASN Extended by customer cone, 1 the largest; 0 for an AS
    # seen in no AS path. Paid plans and the trial.
    def rank
      @raw['rank']
    end

    # Whether it is one of the transit-free networks at the top of the
    # hierarchy. Paid plans and the trial.
    def tier1
      @raw['tier1']
    end

    # `tier1` with an absent member read as false.
    def tier1?
      @raw['tier1'] == true
    end

    # How many AS numbers it gets transit from. Paid plans and the trial.
    def num_upstreams
      @raw['num_upstreams']
    end

    # Those AS numbers, ascending, up to 20000. Paid plans and the trial.
    def upstreams
      @raw['upstreams']
    end

    # How many AS numbers it exchanges its own and its customers' routes with.
    # Paid plans and the trial.
    def num_peers
      @raw['num_peers']
    end

    # Those AS numbers, ascending, up to 20000. Paid plans and the trial.
    def peers
      @raw['peers']
    end

    # How many AS numbers it provides transit to. Paid plans and the trial.
    def num_downstreams
      @raw['num_downstreams']
    end

    # Those AS numbers, ascending, up to 20000. Paid plans and the trial.
    def downstreams
      @raw['downstreams']
    end

    # How many registered domains it hosts (`total`) and the 10 most popular
    # (`domains`), with the wire's string keys. Paid plans and the trial.
    def hosted_domains
      @raw['hosted_domains']
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
      "#<#{self.class} asn=#{asn.inspect} name=#{name.inspect}>"
    end
  end
end
