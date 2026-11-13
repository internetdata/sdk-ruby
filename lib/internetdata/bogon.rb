# frozen_string_literal: true

require 'ipaddr'

module InternetData
  # Addresses that are reserved rather than routed, answered here rather than on
  # the network.
  module Bogon
    # The objects every answer carries, by the spec's model for each. A bogon
    # answers each with every member its model has, empty.
    OBJECTS = {
      'location' => 'Location', 'asn' => 'Asn', 'company' => 'Company', 'abuse' => 'AbuseContact',
      'whois' => 'Whois', 'rwhois' => 'Rwhois', 'hosted_domains' => 'HostedDomains'
    }.freeze

    # A member's empty value, by the type the spec gives it.
    EMPTY = { String: '', Integer: 0, Float: 0, Boolean: false }.freeze

    module_function

    # Whether an address is a bogon: private, loopback, link-local,
    # documentation, multicast or otherwise not routable on the public internet,
    # including the IPv6 equivalents and the 6to4 and Teredo ranges that wrap
    # them.
    def bogon?(ip)
      addr = parse(ip)
      return false if addr.nil?

      addr = addr.native if addr.ipv4_mapped?
      (addr.ipv4? ? v4 : v6).any? { |range| range.include?(addr) }
    end

    # The IPv4 address an IPv4-mapped IPv6 address (::ffff:a.b.c.d, in any
    # spelling) carries, dotted, and any other address as given. A server
    # listening on :: sees every IPv4 visitor in that form, which read whole is
    # inside ::ffff:0:0/96, so judging it whole would answer every such visitor
    # locally as a bogon. ::a.b.c.d is IPv4-compatible rather than mapped, and
    # stays IPv6: IPAddr#native alone would unwrap that too.
    def unmapped(ip)
      addr = ip.to_s.include?(':') ? parse(ip) : nil
      addr&.ipv4_mapped? ? addr.native.to_s : ip
    end

    # The answer a bogon gets, in the shape the API answers one on a paid plan:
    # every flag present and false, every detail present and empty, the objects
    # every answer carries with every member empty, an empty hostname, and
    # `is_bogon` true.
    #
    # Deliberately that WIDEST shape regardless of your plan, so do not infer
    # which fields your plan includes from a bogon answer.
    def result(ip)
      raw = { 'ip' => ip, 'is_bogon' => true }
      Result::FLAGS.each { |flag| raw[flag] = false }
      Result::DETAILS.each { |detail| raw[detail] = {} }
      Result::DETAIL_LISTS.each { |detail| raw[detail] = [] }
      OBJECTS.each { |name, model| raw[name] = empty(InternetData.const_get(model)) }
      raw['hostname'] = ''
      Result.new(raw)
    end

    def empty(model)
      model.openapi_types.to_h { |attr, type| [model.attribute_map[attr].to_s, EMPTY.fetch(type)] }
    end

    # Parsed on first use rather than at load: a consumer that never looks an
    # address up should not pay for the table.
    def v4
      @v4 ||= Bogons::V4.map { |cidr| IPAddr.new(cidr) }.freeze
    end

    def v6
      @v6 ||= Bogons::V6.map { |cidr| IPAddr.new(cidr) }.freeze
    end

    def parse(ip)
      text = ip.to_s
      # IPAddr accepts a prefix, and "10.0.0.0/8" is not an address.
      return nil if text.include?('/')

      IPAddr.new(text)
    rescue IPAddr::Error
      nil
    end

    private_class_method :empty, :v4, :v6, :parse
  end
end
