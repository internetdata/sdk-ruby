# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 2.3.2 are described by their release commits.

## 2.11.1 - 2026-11-14

### Fixes

- Re-pin the spec to 2026.11.13 as republished: the ip.lookup scope 403 ([`c62080f`](https://github.com/internetdata/sdk-ruby/commit/c62080f5f2e4803cc0d00b11960ee5f525bbb6c9))

## 2.11.0 - 2026-11-14

### Features

- Add the framework middleware core ([`48c2631`](https://github.com/internetdata/sdk-ruby/commit/48c263187e1632a4dfef385f923650536c89218d))

### Fixes

- Resolve Rails at the top level, not inside our own namespace ([`b3a8b74`](https://github.com/internetdata/sdk-ruby/commit/b3a8b746aebe418242da33d08943761ea9dc6580))
- Word the non-IP refusal as the other InternetData SDKs do ([`ebe69ff`](https://github.com/internetdata/sdk-ruby/commit/ebe69ffdd3eef8c9569c00e51e0d5e7f87a9c537))

## 2.10.1 - 2026-11-13

### Fixes

- Re-pin the spec to 2026.11.13 again: a detail object requires no member ([`b56c567`](https://github.com/internetdata/sdk-ruby/commit/b56c567c5cde63716c625604e5c42c64e7d1c057))
- Refuse a lookup of anything but an IP address before sending it ([`c6045b9`](https://github.com/internetdata/sdk-ruby/commit/c6045b99ae7b3b67f46882f7be44237e009cdab6))
- Send every request to the client's base URL, whatever the spec's servers ([`2e7db4b`](https://github.com/internetdata/sdk-ruby/commit/2e7db4b2202e6e88142677ad898bd65b5b262b94))

## 2.10.0 - 2026-11-13

### Features

- Look up an address, an AS or a domain on api.internetdata.io ([`0dd201c`](https://github.com/internetdata/sdk-ruby/commit/0dd201cae62bb89fc460194ffa1db269e0e9af62))

### Fixes

- Re-pin the spec to 2026.11.13: the lookup and entitlement operations ([`41ddc2c`](https://github.com/internetdata/sdk-ruby/commit/41ddc2c671a5293102686fbbd6d078cb6f1f7e1f))

## 2.9.2 - 2026-11-13

### Fixes

- End a device poll at its deadline with no request past it ([`6b51fd3`](https://github.com/internetdata/sdk-ruby/commit/6b51fd3482beac6418ae3337424bd8455777a326))

## 2.9.1 - 2026-11-09

### Fixes

- Re-pin the spec to 2026.11.08: the token and revoke descriptions ([`13066cb`](https://github.com/internetdata/sdk-ruby/commit/13066cb21199bc3dc97e77dc1c8616f06d8495f9))

## 2.9.0 - 2026-11-07

### Features

- Download a named build: download_url, download and download_bytes take build: ([`cd80ae3`](https://github.com/internetdata/sdk-ruby/commit/cd80ae39599074a07332ce41c1237a895fe8a0d1))

## 2.8.8 - 2026-11-06

### Fixes

- Re-pin the spec to 2026.11.05: the download's build parameter ([`9c751d0`](https://github.com/internetdata/sdk-ruby/commit/9c751d0378128fa8702e7235c025f0af47a6f29d))

## 2.8.7 - 2026-11-03

### Fixes

- Re-pin the spec to 2026.11.02: ID and IDs in its descriptions ([`5a7c26c`](https://github.com/internetdata/sdk-ruby/commit/5a7c26cae06feef9c276363aeb681aa9ab384f24))
- Write ID and IDs in prose, never id or ids ([`bfceeb2`](https://github.com/internetdata/sdk-ruby/commit/bfceeb21a69cdc3e8e164f087ef4297ac69ad08b))

## 2.8.6 - 2026-10-31

### Fixes

- Read a database sample row only as an object ([`946ac9b`](https://github.com/internetdata/sdk-ruby/commit/946ac9b9d71c814c059e9964cb102ee96b01d121))
- Refuse a retries that is not an Integer from 0, where the client is built ([`1d08358`](https://github.com/internetdata/sdk-ruby/commit/1d08358ffb7d2e539fe03d2da98c11b90f69ed25))
- Refuse a key holding a control character, where the client is built ([`281c1cf`](https://github.com/internetdata/sdk-ruby/commit/281c1cfdf0af9230a0067a9f7052bb8880ca30cc))

## 2.8.5 - 2026-10-29

### Fixes

- Read a lowercase t or z in a date-time ([`d2c7fd5`](https://github.com/internetdata/sdk-ruby/commit/d2c7fd587cc82b6060340d1d879e1ad56cc0445b))

## 2.8.4 - 2026-10-21

### Fixes

- Re-pin the spec to 2026.10.21: a 403 for a refused address ([`0f3ade1`](https://github.com/internetdata/sdk-ruby/commit/0f3ade1e008e58bf65a466e17d2294dced18e013))

## 2.8.3 - 2026-10-20

### Fixes

- Read a database date only in its RFC 3339 form, on a real day ([`e251fa3`](https://github.com/internetdata/sdk-ruby/commit/e251fa30c67294117271dc9c36a325d3da4a6038))

## 2.8.2 - 2026-10-19

### Fixes

- Refuse a null the spec does not allow, at any depth ([`9a85aee`](https://github.com/internetdata/sdk-ruby/commit/9a85aee718922ba5c98b47a79d09e0e3d22f08b8))
- Read a Retry-After date only when it names a real day ([`fc2cfb5`](https://github.com/internetdata/sdk-ruby/commit/fc2cfb569b3c50a9fd41e1e6bb9c80b2ee919c58))

## 2.8.1 - 2026-10-18

### Fixes

- Re-pin the spec to 2026.10.18: client_id_issued_at is int64 ([`38a96b2`](https://github.com/internetdata/sdk-ruby/commit/38a96b23684b21485141fb7e4816d33b64f82978))

## 2.8.0 - 2026-10-18

### Features

- Add oauth.register, for RFC 7591 dynamic client registration ([`0dfa926`](https://github.com/internetdata/sdk-ruby/commit/0dfa926fd5692d7cd7536f6798323680aff3f6e8))

## 2.7.0 - 2026-10-17

### Features

- Re-pin the spec to 2026.10.16: dynamic client registration ([`622cfdd`](https://github.com/internetdata/sdk-ruby/commit/622cfdd00f80cce386bf85122c4dc372cc0d31e2))

## 2.6.4 - 2026-10-16

### Fixes

- Retry a database answer whose member has the wrong type ([`890dd72`](https://github.com/internetdata/sdk-ruby/commit/890dd726ec230b6b515d716ab28c62b101eef5a5))

## 2.6.3 - 2026-10-16

### Fixes

- Re-pin the spec to 2026.10.15: three descriptions in US spelling ([`1461baa`](https://github.com/internetdata/sdk-ruby/commit/1461baaf57dc4d7408a1ba3a3eb0496c3b553a7e))

## 2.6.2 - 2026-10-13

### Fixes

- Re-pin the spec to 2026.10.13: Open databases come with a license ([`38225fa`](https://github.com/internetdata/sdk-ruby/commit/38225fa7997ccbba9c76517b416725512f54e9f1))

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
