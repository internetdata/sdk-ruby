# [<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="28"/>](https://internetdata.io/) InternetData Ruby Client Library

[![gem](https://img.shields.io/gem/v/internetdata.svg)](https://rubygems.org/gems/internetdata)
[![license](https://img.shields.io/github/license/internetdata/sdk-ruby.svg)](LICENSE)

The official Ruby client library for the [InternetData](https://internetdata.io) API.

It tells you what every InternetData database says about an IP address, an AS or a domain: where it is, who runs it, whether it is a VPN, proxy, Tor node or hosting server, and what it serves. It also downloads the databases your organization is licensed for.

## Getting Started

```bash
gem install internetdata
```

Or add it to your Gemfile:

```ruby
gem 'internetdata'
```

Requires Ruby 3.3 or newer, and libcurl at runtime, which the `curl` package brings on Debian and Alpine.

## Usage

**No API key needed to start.** Unlimited, the free plan, answers an address's location, network, company, abuse contact and reverse DNS, and its Tor, relay and anycast flags, with no daily or monthly cap, with a key or without one.

```ruby
require 'internetdata'

client = InternetData::Client.new

result = client.lookup('146.70.116.130')
result.location['country']  # => "AT"
result.asn['name']          # => "M247 Europe SRL"
result.is_tor               # => false
```

### With an API key

A paid plan answers every field: the VPN, proxy, hosting and CDN flags as well, the detail behind each flag, and an address's city, Whois, RWHOIS and hosted domains. A free account tries every field. Create a key in the [console](https://app.internetdata.io), then pass it in:

```ruby
client = InternetData::Client.new(api_key: ENV['INTERNETDATA_API_KEY'])

result = client.lookup('146.70.116.130')
result.is_vpn                # => true, on a paid plan
result.vpn['provider_name']  # => "Mullvad", on a paid plan
result.location['city']      # => "Vienna", on a paid plan
```

### AS and domain lookups

```ruby
asn = client.lookup_asn(9009)  # or 'AS9009'
asn.name                       # => "M247 Europe SRL"
asn.prefixes                   # what it announces, on a paid plan

domain = client.lookup_domain('example.com')
domain.is_registered           # => true
domain.dns                     # its records, on a paid plan
```

Both are sent as you give them, and the API reads `AS9009` and an internationalized domain too. Neither is cached. `lookup` takes an IP address alone, and raises a `:bad_request` for anything else before sending it.

### Your own address

```ruby
result = client.my_ip
result.ip   # => the address we saw this call come from
```

Same answer `lookup` would give for that address, and the same cost against your allowance. It is deliberately not cached: which address you are is the whole question, and a machine that moves between networks would otherwise be told where it used to be.

### Your plan and usage

```ruby
acct = client.my_entitlement
acct.plan.key          # => "data_4"
acct.plan.name         # => "Data", the name to show
acct.usage.requests    # => 580
acct.usage.window_end  # => when the allowance resets
```

Usage counts against the anniversary of your subscription on a paid plan, not the calendar month and not the billing period, and against its trial on the free plan; it is the same number a lookup is gated on. `hard_limit` is `nil` on an uncapped plan, which is not the same as zero.

Show `plan.name` and compare against `plan.key`: a plan's name can change, and its key never does. A value the API adds later to a plan's `tier`, a database's `standing` or `license_type`, a format or a download's `outcome` comes back as the string it served (from 2.20.0), so check for the values you know rather than assuming the list is complete.

### Is that crawler who it says it is?

Pass the `User-Agent` of the request you are deciding on, and with every field (a paid plan, or a free account's trial) the answer says whose agent it names and whether this address bears that out:

```ruby
result = client.lookup('66.249.66.1', user_agent: request.user_agent)
result.user_agent  # => {"agent"=>"Googlebot", "kind"=>"bot", "verdict"=>"verified"}

results = client.lookup_batch(ips, user_agents: { '66.249.66.1' => request.user_agent })
```

`verdict` is `verified` where the agent's operator vouches for the address, `spoofed` where it does not, `unverifiable` for a bot nothing published can confirm, and `not_bot` for a browser, an app or a script. `my_ip` takes `user_agent:` too. A batch's `user_agents` is keyed by each address as you list it, and an address with no agent, or an empty one, is looked up plainly. An answer with an agent is cached apart from the address's plain answer and from another agent's. Unlimited's answers, a private address's and a lookup that sent none carry no `user_agent` (`nil`).

### Batch lookup

Look up as many addresses as you like at once. Bogons and cached answers are handled locally, and everything else goes to the batch endpoint in chunks of up to 1000 addresses, in parallel. The batch endpoint needs a paid plan:

```ruby
results = client.lookup_batch(['146.70.116.130', '8.8.8.8', '1.1.1.1'])

results.each do |ip, result|
  if result.is_a?(InternetData::Error)
    warn "#{ip}: #{result.message}"
    next
  end
  puts "#{ip}: #{result.location['country']}"
end
```

Results are keyed by address, in the order you first listed each one, so duplicates in your list collapse into a single entry and one address failing never loses the rest: it carries its error as its value, with the status the API would have given that address on its own.

How many chunks are in flight at once, how many times a failed chunk is retried, and how long each chunk's request may take are configurable per call:

```ruby
results = client.lookup_batch(many_ips, concurrency: 4, retries: 4, timeout: 5)
```

### Caching

Address lookups are cached by default, so repeat lookups of the same address are free:

```ruby
client = InternetData::Client.new

result = client.lookup('146.70.116.130')   # API request
result2 = client.lookup('146.70.116.130')  # no API request, result was cached
```

You can change the default cache variables (max size, TTL in seconds) on initialization, or even disable it:

```ruby
client = InternetData::Client.new(cache_max_size: 50_000, cache_ttl: 6 * 60 * 60)
client_no_cache = InternetData::Client.new(cache: false)
```

### Private and reserved addresses

Private, loopback, link-local, documentation and multicast addresses (and their IPv6 equivalents, including the 6to4 and Teredo ranges) are answered locally, so they cost no request and no quota. The answer is the one the API gives a bogon on a paid plan, every flag false, whatever your plan:

```ruby
result = client.lookup('192.168.1.1')
result.is_bogon  # => true
result.is_vpn    # => false
```

The check is available on the client, which is handy when your inputs are addresses anyway:

```ruby
client.bogon?('10.0.0.1')   # => true
client.bogon?('8.8.8.8')    # => false
```

It is also on the module itself, if you want it without a client:

```ruby
InternetData.bogon?('10.0.0.1')   # => true
```

### Database downloads

Every database published today needs an API key carrying the `db.download` scope. The Open databases are licensed to every organization from the start and are free under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), and `list` marks them `open`. The rest are licensed by contract, one family at a time: if your organization doesn't have a license yet, [request an evaluation](https://internetdata.io/contact?purpose=evaluation&subject=Evaluation+license).

```ruby
client = InternetData::Client.new(api_key: ENV['INTERNETDATA_API_KEY'])

client.database.list.each do |database|
  puts [database.base, database.standing, database.versions.map(&:id).join(', ')].join(' ')
end
```

`list` returns one entry per database FAMILY, because a license is held against the family while a download names a specific version. `standing` is `licensed` if the family is yours today, `expired` if the term has ended, and `unlicensed` if it is published but has never been bought. `versions` carries the IDs you pass everywhere else, oldest first, and the formats each one is actually built in.

### What is inside a database

```ruby
meta = client.database.metadata('bogon_ip_v1')

meta.updated              # => '2026-09-04', the day this build was generated
meta.entries              # => rows in the build
meta.size['csvgz']        # => bytes you are about to move
meta.schema['csvgz']      # => [#<DatabaseMetadataColumn name="ip" type="string" ...>, ...]
meta.sample['mmdb']       # => a few real rows
```

Poll `updated` and `entries` to decide whether today's build is worth fetching; both are free of the transfer. `size` is also the honest way to budget a download before starting one.

### Downloading

`download` streams a file to a path and returns the number of bytes written. Nothing larger than a chunk is ever held in memory, whatever the database weighs:

```ruby
written = client.database.download('bogon_ip_v1', 'mmdb', './bogon_ip_v1.mmdb')
```

The bytes go to a neighboring `.part` file and the name only appears once the transfer completes, so an interruption cannot leave a truncated file that reads as a whole database, and a refresh that fails does not destroy the copy already there.

Or take the link and run the transfer yourself. The API answers a redirect to time-limited object storage, and that URL authorizes itself, so it can be handed to something holding no API key:

```ruby
url = client.database.download_url('bogon_ip_v1', 'mmdb')
```

Or, for a small database, take the bytes directly:

```ruby
bytes = client.database.download_bytes('bogon_asn_v1', 'csvgz')
```

`download_bytes` holds the whole file in memory and the catalog spans seven orders of magnitude, from a few hundred bytes to over 5 GiB, so use `download` for anything you have not checked with `metadata` first.

Each of the three downloads the build that is live unless you name one. A `database.updated` webhook names the build it announces and carries its `sha256`, so a receiver that downloads after the next publish asks for that build to get the file the hash is of:

```ruby
client.database.download('vpn_ip_v1', 'mmdb', './vpn_ip_v1.mmdb', build: event['data']['build'])
```

A build is kept 7 days. Past that the call raises `bad_request` with the message `BUILD_GONE`, and downloading without `build:` fetches the live one. A name that is not a build's shape (`20261105.0t53s5`) raises `ArgumentError` before anything is sent.

### Verifying what you got

```ruby
sums = client.database.checksums('bogon_ip_v1', 'mmdb')
sums.sha256   # also md5, sha1, sha512
```

### Download history

Your organization's recent attempts, newest first, refusals included, because a denial is what answers "it stopped working" and its absence answers nothing:

```ruby
client.database.downloads(limit: 20).each do |attempt|
  puts [attempt.created, attempt.dataset_id, attempt.format, attempt.outcome].join(' ')
end
```

### Timeouts and retries

```ruby
client = InternetData::Client.new(timeout: 10, retries: 4)

result = client.lookup('146.70.116.130', timeout: 2, retries: 0)
catalog = client.database.list(timeout: 5)
```

`timeout` is in seconds and bounds each attempt, body included, so a call that is retried can take longer in total. It defaults to 30 seconds, and 0 means no bound. The client's values are defaults: `lookup`, `lookup_asn`, `lookup_domain`, `lookup_batch`, `my_ip` and `my_entitlement` each take `timeout:` and `retries:` for that call alone, and `list`, `metadata`, `checksums`, `downloads`, `download_url` and every `client.oauth` method take `timeout:`. A negative value, anything that isn't a number, and anything past 2147483.647 seconds (the longest curl holds) raise `ArgumentError` where you pass them, before any request. So does a `retries` that isn't an Integer from 0, and a `concurrency` that isn't an Integer from 1 given to `Client.new`, which `lookup_batch` refuses as `:bad_request`.

`download` and `download_bytes` take no `timeout:` and raise `ArgumentError` if handed one, rather than accepting it and quietly doing nothing: a transfer runs to gigabytes and minutes, so any bound that suits a JSON call would abandon a healthy download. They bound only their connection with the client's value. `download_url` does take one, because minting the link is an ordinary API request - it bounds that request, not whatever you do with the link afterwards.

### Errors

Failures raise an `InternetData::Error` carrying a `kind` and a `retryable?` flag:

```ruby
begin
  client.lookup('146.70.116.130')
rescue InternetData::Error => e
  warn "#{e.kind} #{e.status} #{e.retryable?}: #{e.message}"
end
```

`kind` is one of `:bad_request`, `:unauthorized`, `:forbidden`, `:rate_limited`, `:quota_exceeded`, `:server_error` or `:network`. A lookup's `message` is the API's own words; a database call's refusal also carries `rc`, the API's result code, such as `NOT_LICENSED` or `LICENSE_EXPIRED`.

Note that `:rate_limited` and `:quota_exceeded` both arrive as HTTP 429 and are not the same thing. A rate limit is when the API faces extreme traffic bursts and so retrying later works; but a 429 without `Retry-After` is `:quota_exceeded`, which the library never retries. The API itself always sends `Retry-After` with a 429, so that one comes from something in between, such as a proxy; a paid key past its overage cap gets `cap_reached` instead. It waits the `Retry-After` the API sent, or its own backoff from 250 ms when that's past about 24.8 days.

### Sign in with OAuth (device flow)

A program running on a person's own machine can let them sign in with their browser and pick one of their API keys, instead of asking them to paste one.

```ruby
client = InternetData::Client.new
device = client.oauth.device_authorization('your-client-id', scope: 'account.read apikeys.read apikeys.reveal')
puts "Open #{device.verification_uri} and enter #{device.user_code}"

token = client.oauth.poll_device_token('your-client-id', device)
raise 'no API key was picked' if token.apikey.nil?

keyed = InternetData::Client.new(api_key: token.apikey)
```

`poll_device_token` raises `InternetData::OauthAccessDeniedError` when the person refuses and `InternetData::OauthExpiredTokenError` when the code expires first. `client.oauth.revoke('your-client-id', token.refresh_token)` signs the machine out. Only a client we registered, such as our CLI, can use the device flow: an app of your own signs people in with the authorization code flow below.

### Sign in with OAuth (authorization code)

An app that can take a browser redirect signs the person in there instead, with a PKCE pair made for that one sign-in:

```ruby
client = InternetData::Client.new
redirect_uri = 'http://127.0.0.1:8765/callback'
pkce = client.oauth.create_pkce

url = client.oauth.authorization_url('your-client-id', redirect_uri, pkce.challenge,
                                     scope: 'apikeys.use', state: 'your-state')
# Open url in the browser. Its redirect to redirect_uri carries code and state.
token = client.oauth.exchange_authorization_code('your-client-id', code, pkce.verifier, redirect_uri)
```

Check that `state` came back as you sent it before you exchange `code`, which works once. The client ID can also be the https URL of a client metadata document your app serves, and such an app is never handed a key, so `token.apikey` stays `nil`.

### Register a client

An app with no client ID, and no client metadata document to use as one, registers itself, then signs in with the `client_id` it gets back as the client ID for `authorization_url` and `exchange_authorization_code`:

```ruby
client = InternetData::Client.new
registration = client.oauth.register(['http://127.0.0.1:8765/callback'], client_name: 'Your App')
```

Each redirect URI must be https on a public host name, or http on a loopback address, which then matches any port. Nothing is kept until a person approves the client, so an app with no client ID saved can simply register again.

### Absent is not false

Unlimited leaves out the VPN, proxy, hosting, CDN, bot, carrier, satellite, SSH, SMTP, web, DNS resolver and BitTorrent flags and their detail (`bot` names the bot behind `is_bot`), an address's city and the rest of its paid location, its Whois, RWHOIS and hosted domains, and the paid members inside each shared object, such as `abuse['phone']`. A free-plan key's answer carries `trial_expired`, true once its trial is spent. A paid key's carries `cap_reached`, true once its organization's overage cap is reached, when the answer has Unlimited's fields and isn't billed. A field is present when your plan includes it and `nil` when it does not. `nil` means "not in your plan"; `false` means "we checked, and no".

```ruby
result.vpn?                   # false when absent, for when you only want the flag
result.included?(:is_vpn)     # false on Unlimited: not in your plan
result.location.key?('city')  # false on Unlimited
result.trial_expired == true  # a free-plan key's trial is spent
result.cap_reached == true    # a paid key is past its overage cap
```

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, and Ruby. See our GitHub at https://github.com/internetdata for more.

## About InternetData

Geolocation, anonymity, ownership, network, service and domain data for any IP address, AS or domain, by API or as databases you download.

[<picture><source media="(prefers-color-scheme: dark)" srcset="https://s3.internetdata.io/internetdata-public/brand/logo-dark.svg"><img src="https://s3.internetdata.io/internetdata-public/brand/logo.svg" alt="InternetData" height="40"/></picture>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).
