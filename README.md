# [<img src="https://docs.internetdata.io/logo.svg" alt="InternetData" width="24"/>](https://internetdata.io/) InternetData Ruby Client Library

[![gem](https://img.shields.io/gem/v/internetdata.svg)](https://rubygems.org/gems/internetdata)
[![license](https://img.shields.io/github/license/internetdata/sdk-ruby.svg)](LICENSE)

The official Ruby client library for the [InternetData](https://internetdata.io) API.

InternetData publishes IP and ASN databases: VPN and proxy address space, hosting and CDN ranges, provider catalogs, bogons and more, as gzipped CSV and as MMDB. This library lists the databases your organization is licensed for, tells you what is inside one before you fetch it, downloads it, and verifies the bytes you got.

## Getting Started

```bash
gem install internetdata
```

Or add it to your Gemfile:

```ruby
gem 'internetdata'
```

Requires Ruby 3.1 or newer.

## Usage

Every call needs an API key carrying the `db.download` scope. Database access is granted by contract, one database family at a time, so there is no self-serve tier: write to [dev@internetdata.io](mailto:dev@internetdata.io) to be licensed and issued a key.

```ruby
require 'internetdata'

client = InternetData::Client.new(api_key: ENV['INTERNETDATA_API_KEY'])

client.database.list.each do |database|
  puts [database.base, database.standing, database.versions.map(&:id).join(', ')].join(' ')
end
```

`list` returns one entry per database FAMILY, because a license is held against the family while a download names a specific version. `standing` is `licensed` if the family is yours today, `expired` if the term has ended, and `unlicensed` if it is published but has never been bought. `versions` carries the ids you pass everywhere else, oldest first, and the formats each one is actually built in.

**This listing is not the same for every key.** A database commissioned for a single customer is absent from the catalog for every other organization, rather than being listed as unlicensed. So a listing is only ever an answer about the key that asked. This library never caches one, and you should not carry an answer from one key over to another or treat it as the published catalog.

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

### Errors

Failures raise an `InternetData::Error` carrying a `kind` and a `retryable?` flag:

```ruby
begin
  client.database.download('vpn_ip_v1', 'mmdb', './vpn_ip_v1.mmdb')
rescue InternetData::Error => e
  warn "#{e.kind} #{e.status} #{e.retryable?}: #{e.rc}"
end
```

`kind` is one of `:bad_request`, `:unauthorized`, `:forbidden`, `:rate_limited`, `:quota_exceeded`, `:server_error` or `:network`. `rc` is the API's own result code, such as `NOT_LICENSED` or `LICENSE_EXPIRED`, which is usually the specific thing you want to read.

Note that `:rate_limited` and `:quota_exceeded` both arrive as HTTP 429 and are not the same thing. A rate limit is the API facing a burst, so retrying later works; a spent quota needs your allowance raised or the window to roll over. The library retries the first for you and never the second.

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, Ruby, and many popular frameworks such as Django, Rails, and Laravel. See our GitHub at https://github.com/internetdata for more.

## About InternetData

IP intelligence databases: VPN, proxy, hosting, CDN and relay address space, provider catalogs and network metadata, published as CSV and MMDB.

[<img src="https://docs.internetdata.io/logo.svg" alt="InternetData" width="96"/>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).
