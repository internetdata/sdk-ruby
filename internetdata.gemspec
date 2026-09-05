# frozen_string_literal: true

require_relative 'lib/internetdata/version'

Gem::Specification.new do |spec|
  spec.name = 'internetdata'
  spec.version = InternetData::VERSION
  spec.authors = ['Mslm Dev']
  spec.email = ['dev@internetdata.io']

  spec.summary = 'Official Ruby client library for the InternetData API.'
  spec.description = 'Download InternetData IP and ASN databases, and read their metadata, ' \
                     'checksums and download history.'
  spec.homepage = 'https://internetdata.io'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => 'https://github.com/internetdata/sdk-ruby',
    'bug_tracker_uri' => 'https://github.com/internetdata/sdk-ruby/issues',
    'changelog_uri' => 'https://github.com/internetdata/sdk-ruby/releases',
    'documentation_uri' => 'https://docs.internetdata.io',
  }

  spec.files = Dir['lib/**/*.rb'] + %w[LICENSE README.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'typhoeus', '~> 1.4'
end
