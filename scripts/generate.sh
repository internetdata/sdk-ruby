#!/bin/bash

# Regenerates the wire layer from the PINNED spec in spec/openapi.yaml.
#
# The generator runs in its official container, so nothing has to be installed
# locally, and it reads the committed spec rather than a URL, so the build is
# reproducible and offline. Refresh the spec with scripts/download-spec.sh, run
# this, and commit both together so a reviewer sees which spec produced which
# client.
#
# The output is COMMITTED. A gem installs from source with no build step, so a
# gitignored client would ship a package that cannot require itself.

set -euo pipefail

cd "$(dirname "$0")/.."

GENERATOR_IMAGE="${GENERATOR_IMAGE:-openapitools/openapi-generator-cli:v7.25.0}"

PROPS="gemName=internetdata,moduleName=InternetData,hideGenerationTimestamp=true"

# The spec's `Error` schema is the API's `{rc}` envelope. Left alone it generates
# InternetData::Error, which is the name Ruby convention reserves for a gem's own
# exception base class, so the two would be the same constant.
MODELS="Error=ErrorEnvelope"

# The three v2 wrapper schemas are inline in the spec, so the generator names them
# after the operation and status code (ListDatabases200Response). They are public
# API here. --model-name-mappings does NOT reach an inline schema; only
# --inline-schema-name-mappings does, keyed by the generator's own placeholder name.
NAMES="listDatabases_200_response=DatabaseList"
NAMES="${NAMES},listDownloads_200_response=DownloadList"
NAMES="${NAMES},databaseChecksumV2_200_response=DatabaseChecksumsResponse"

# The published spec still carries the v1 endpoints, which are a legacy, per-
# customer surface authenticated by a `?apikey=` query parameter this gem does
# not offer. Selecting the v2 tag and the ten schemas it reaches keeps them out
# of the generator's output entirely, rather than emitting a v1 client and then
# deleting it - a file that is never written cannot be left behind stale.
SELECT="apis=DatabaseV2"
SELECT="${SELECT},models=Database:DatabaseVersion:DatabaseMetadata:DatabaseMetadataColumn"
SELECT="${SELECT}:DbChecksums:Download:Error:DatabaseList:DownloadList:DatabaseChecksumsResponse"
# The two named enums. A schema reachable from a selected model is NOT pulled in
# automatically - leave them out and the deserializer const_gets a class that
# was never written.
SELECT="${SELECT}:DatabaseFormat:Standing"
SELECT="${SELECT},supportingFiles,apiTests=false,modelTests=false,apiDocs=false,modelDocs=false"

rm -rf .gen
mkdir -p .gen

docker run --rm \
    -v "$PWD/spec:/spec:ro" \
    -v "$PWD/.gen:/out" \
    "$GENERATOR_IMAGE" generate \
    -i /spec/openapi.yaml \
    -g ruby --library typhoeus \
    -o /out \
    --model-name-mappings "$MODELS" \
    --inline-schema-name-mappings "$NAMES" \
    --global-property "$SELECT" \
    --additional-properties="$PROPS" \
    >/dev/null

# Only the wire layer is taken. The generator also emits lib/internetdata.rb and
# lib/internetdata/version.rb, which are OURS, plus a gemspec, Gemfile, Rakefile,
# README, rubocop config, travis and gitlab CI files and an rspec suite - all of
# which would overwrite the repo if the output were unpacked over it.
rm -rf lib/internetdata/{api,models} lib/internetdata/{api_client,api_error,api_model_base,configuration}.rb
cp -R .gen/lib/internetdata/api lib/internetdata/api
cp -R .gen/lib/internetdata/models lib/internetdata/models
for f in api_client api_error api_model_base configuration ; do
    cp ".gen/lib/internetdata/${f}.rb" "lib/internetdata/${f}.rb"
done

rm -rf .gen
echo "regenerated the wire layer under lib/internetdata from spec/openapi.yaml"
grep -m1 '^  version:' spec/openapi.yaml
