# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 2.3.2 are described by their release commits.

## 2.6.1 - 2026-10-10

### Fixes

- Re-pin the spec to 2026.10.09: rotating a key needs apikeys.reveal ([`ed6b0df`](https://github.com/internetdata/sdk-ruby/commit/ed6b0df0c387921ecf2f8bd0d9f278c369aa5c2f))
- Send no Authorization header for a key of blanks alone ([`05b6fcd`](https://github.com/internetdata/sdk-ruby/commit/05b6fcdca0e8fdbb872746279dc257893c90cbc8))

## 2.6.0 - 2026-10-09

### Features

- Re-pin the spec to 2026.10.08, adding the Open databases' open flag ([`8a18e22`](https://github.com/internetdata/sdk-ruby/commit/8a18e22fe260fef355bb2ba8d8b52459eabc5d4e))

### Fixes

- Read a Retry-After as digits or an HTTP date, and nothing else ([`8b422ce`](https://github.com/internetdata/sdk-ruby/commit/8b422ced997413c0945f53966c7b6d7d5376733a))
- Carry the status when the download link answers 2xx, not its redirect ([`390b33c`](https://github.com/internetdata/sdk-ruby/commit/390b33cf9d8398dd740622aa4ee6995c1194e9e2))

## 2.5.2 - 2026-10-06

### Fixes

- Raise a 2xx that is not its answer as a retried server_error ([`0871929`](https://github.com/internetdata/sdk-ruby/commit/0871929b57df141e7bfbe06940490f18ff547868))

## 2.5.1 - 2026-10-04

### Fixes

- Re-pin the spec to 2026.10.03: metadata needs no license ([`0ddf019`](https://github.com/internetdata/sdk-ruby/commit/0ddf01954f7ec2da242381a787c2b1f190b566b0))

## 2.5.0 - 2026-09-29

### Features

- Add the authorization code sign-in, with PKCE ([`4996223`](https://github.com/internetdata/sdk-ruby/commit/4996223556280a0ae0558b3290b6284e8c4f8cb6))

## 2.4.1 - 2026-09-29

### Fixes

- README: link the evaluation request, not a mailbox ([`ef861c6`](https://github.com/internetdata/sdk-ruby/commit/ef861c69ea5f69ce07ec893fa2694c96e007a21b))

## 2.4.0 - 2026-09-27

### Features

- Re-pin the spec to 2026.09.26, adding its evaluation-sample fields ([`6c1becb`](https://github.com/internetdata/sdk-ruby/commit/6c1becb369451dcecfb95e4e0f8a41c63d8ab72a))

## 2.3.2 - 2026-09-24

### Fixes

- Refuse a timeout curl cannot hold, and cap every wait a server sets ([`2a754cf`](https://github.com/internetdata/sdk-ruby/commit/2a754cf93d60031313c5e25e243ccef5b26ea53a))
