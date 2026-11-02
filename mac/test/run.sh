#!/bin/bash
# Builds and runs the Linux tests for JotCore.swift in Docker (swift:6.0-noble), with a throwaway notes server.
set -euo pipefail
cd "$(dirname "$0")"
SPEC=$(cd ../../spec && pwd)
node $SPEC/fixtures.mjs >/dev/null
cp ../Sources/JotCore.swift Sources/JotTest/JotCore.swift
D=$(mktemp -d); PORT=$((20000 + RANDOM % 20000)); O=http://127.0.0.1:$PORT
DATA_DIR=$D/srv PORT=$PORT node ../../server/server.js & SRV=$!
trap 'kill $SRV; rm -rf $D' EXIT
RUN="docker run --rm --network host -u $(id -u):$(id -g) -e HOME=/tmp -v $PWD:/t -v $SPEC:/spec:ro -v $D:/d -w /t swift:6.0-noble"
$RUN swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "^Compiling Crypto" | tail -20
B=.build/release/JotTest
$RUN $B fixtures /spec/fixtures.json
$RUN $B sync1 $O /d/state
docker run --rm --network host -v $SPEC:/spec:ro -v $PWD:/t node:22-bookworm-slim node /t/node-phase.mjs $O
$RUN $B sync2 $O /d/state
