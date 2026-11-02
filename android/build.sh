#!/usr/bin/env bash
# Build the signed APK inside Docker (nothing Android-related is installed on the host).
#   ./build.sh ["notes"]  unit tests + release APK (version +1) -> dist/jot.apk, copied to ../server/public/android/ (served at <server>/android/)
#                         with app.json, which the app checks to offer a one-tap update ("notes" shows in the banner)
#                         plus small patches from the last 2 versions (dist/history), which the app prefers over the full APK
#   ./build.sh test       unit tests only
# The signing key is keys/keystore.jks; its password is in keys/pass (both mode 600; back them up:
# a different key means the phone can't update the app in place).
set -euo pipefail
cd "$(dirname "$0")"
JOT_ORIGIN=${JOT_ORIGIN:-$(cat origin.txt 2>/dev/null || true)}                  # the notes server, e.g. https://notes.example.com
[ -n "$JOT_ORIGIN" ] || { echo "set JOT_ORIGIN or put the server address in origin.txt"; exit 1; }
mkdir -p keys dist .gradle-cache
docker image inspect jot-build >/dev/null 2>&1 || docker build -t jot-build -f Dockerfile.build .
docker image inspect jot-diff >/dev/null 2>&1 || docker build -t jot-diff -f Dockerfile.diff .
cp ../spec/fixtures.json ../spec/vectors.json app/src/test/resources/   # shared logic/crypto checks
cp ../mac/test/hl/hl-fixtures.json app/src/test/resources/                               # highlight.js output (Markup HLParse test)
mkdir -p app/src/main/assets
cp ../mac/Resources/highlight.min.js ../mac/Resources/jothl.js app/src/main/assets/   # code colouring, shared with the Mac app
if [ ! -f keys/keystore.jks ]; then
  umask 077; openssl rand -base64 24 | tr -d '/+=' > keys/pass
  docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/keys:/keys" jot-build \
    keytool -genkeypair -keystore /keys/keystore.jks -alias jot -keyalg EC -groupname secp256r1 -validity 20000 \
    -storepass "$(cat keys/pass)" -keypass "$(cat keys/pass)" -dname "CN=Jot"
fi
TASKS="testReleaseUnitTest"; [ "${1:-}" = test ] || TASKS="testReleaseUnitTest assembleRelease"
if [ "${1:-}" != test ]; then VER=$(( $(cat version.txt) + 1 )); echo "$VER" > version.txt; fi
docker run --rm -u "$(id -u):$(id -g)" --memory=2g -e KS_PASS="$(cat keys/pass)" -e JOT_ORIGIN="$JOT_ORIGIN" -e GRADLE_USER_HOME=/cache -e HOME=/cache/home -e ANDROID_USER_HOME=/cache/android \
  -v "$PWD:/src" -v "$PWD/.gradle-cache:/cache" -v "$PWD/keys:/keys:ro" jot-build gradle --no-daemon -q $TASKS
[ "${1:-}" = test ] && exit 0
cp app/build/outputs/apk/release/app-release.apk dist/jot.apk
docker run --rm -v "$PWD/dist:/d" jot-build apksigner verify /d/jot.apk
PUB=../server/public/android; mkdir -p "$PUB"
cp dist/jot.apk "$PUB/jot.apk.tmp" && mv "$PUB/jot.apk.tmp" "$PUB/jot.apk"
gzip -9 -c dist/jot.apk > "$PUB/jot.apk.gz.tmp" && mv "$PUB/jot.apk.gz.tmp" "$PUB/jot.apk.gz"   # sent to phones that accept gzip
# update patches: previous version's APK -> this one (bsdiff, made by mkpatch.py in the jot-diff image)
mkdir -p dist/history "$PUB/patches"
cp dist/jot.apk "dist/history/$VER.apk"
PATCHES="[]"
for OLD in $(ls dist/history | sed 's/\.apk$//' | grep -v "^$VER\$" | sort -n | tail -2); do
  OUT="$PUB/patches/$OLD-$VER.patch"
  if docker run --rm -u "$(id -u):$(id -g)" --memory=1500m -v "$PWD:/d" -v "$PUB/patches:/out" jot-diff \
       python mkpatch.py "dist/history/$OLD.apk" dist/jot.apk "/out/$OLD-$VER.patch.tmp"; then
    mv "$OUT.tmp" "$OUT"
    PATCHES=$(FROM="$OLD" FSHA=$(sha256sum "dist/history/$OLD.apk" | cut -d' ' -f1) PSIZE=$(stat -c %s "$OUT") P="$PATCHES" python3 -c '
import json, os
print(json.dumps(json.loads(os.environ["P"]) + [{"from": int(os.environ["FROM"]), "fromSha": os.environ["FSHA"], "size": int(os.environ["PSIZE"])}]))')
  else rm -f "$OUT.tmp"; echo "patch from $OLD failed; the full APK still works"; fi
done
find "$PUB/patches" -name '*.patch' ! -name "*-$VER.patch" -delete          # older patches can't reach this version
ls dist/history | sort -n | head -n -3 | sed 's|^|dist/history/|' | xargs -r rm -f   # keep the last 3 APKs
NOTES="${1:-Improvements}" VER="$VER" PATCHES="$PATCHES" SIZE=$(stat -c %s dist/jot.apk) SHA=$(sha256sum dist/jot.apk | cut -d' ' -f1) python3 -c '
import json, os
print(json.dumps({"versionCode": int(os.environ["VER"]), "versionName": "1." + os.environ["VER"], "size": int(os.environ["SIZE"]),
                  "sha256": os.environ["SHA"], "notes": os.environ["NOTES"], "patches": json.loads(os.environ["PATCHES"])}))' > "$PUB/app.json.tmp"
mv "$PUB/app.json.tmp" "$PUB/app.json"
cat "$PUB/app.json"
ls -la dist/jot.apk
