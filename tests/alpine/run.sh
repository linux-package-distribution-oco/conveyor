#!/bin/sh
# The conveyor's own test of alpine.yml: the workflow's steps themselves, taken out of the file with yq
# and run in order against a pages site served on this machine - the same text a release runs, so a test
# cannot drift from the workflow (decision 2026-11-11-scripts-inline: the scripts live in the workflow).
#
# Three releases of two fixture packages whose source is a file beside the APKBUILD, as sxmo-utils's is:
#   fixt-one 1  -> the repository lists fixt-one, which installs
#   fixt-two 1  -> the repository lists fixt-one AND fixt-two (the second must not replace the first)
#   fixt-one 2  -> fixt-one at 2 only (the old one dropped), fixt-two still there
# Each release runs: the APKBUILD step, the kept-packages step, build, signed packaging, the front page,
# the live check, the signature check, a (local) deploy, and the verify job's install step in a clean Alpine.
#
# Needs: docker, yq (mikefarah), jq, curl, openssl. No key but a throwaway one made here.
# ALPINE_YML=path tests another copy of the workflow (default: the one beside this repository's tests).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
yml="${ALPINE_YML:-$here/../../.github/workflows/alpine.yml}"
RELEASE=3.24
ARCH=x86_64
FIXTURES="$here/fixtures"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok  $*"; }
for t in docker yq jq curl openssl; do command -v "$t" >/dev/null || fail "$t is needed"; done

tmp="$(mktemp -d)"
cname="conveyor-test-pages-$$"
cleanup() {
  docker rm -f "$cname" >/dev/null 2>&1 || true
  # the containers ran as root: remove what they wrote the same way
  docker run --rm -v "$tmp:/t" "alpine:$RELEASE" sh -c 'rm -rf /t/* /t/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# the throwaway signing key: an RSA key, its public half beside the APKBUILD as a project commits it
KEYNAME=conveyor-test-20261118.rsa
openssl genrsa -out "$tmp/$KEYNAME" 2048 2>/dev/null
openssl rsa -in "$tmp/$KEYNAME" -pubout -out "$tmp/$KEYNAME.pub" 2>/dev/null
APK_SIGNING_KEY="$(cat "$tmp/$KEYNAME")"
KEY="packaging/$KEYNAME.pub"

# the pages site: a directory served over http, replaced as a deploy replaces it
mkdir "$tmp/pages"
docker run -d --name "$cname" -p 127.0.0.1::8080 -v "$tmp/pages:/www:ro" "alpine:$RELEASE" \
  sh -c 'apk add -q --no-cache busybox-extras && exec httpd -f -p 8080 -h /www' >/dev/null
port="$(docker port "$cname" 8080/tcp | head -1 | sed 's/.*://')"
PAGES_BASE="http://127.0.0.1:$port"
up=no
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do curl -s -o /dev/null "$PAGES_BASE/" && { up=yes; break; }; sleep 2; done
[ "$up" = yes ] || fail "the local pages server did not come up"

# step JOB NAME: the run text of that step, as the workflow says it
step() {
  S_JOB="$1" S_NAME="$2" yq -r '.jobs[strenv(S_JOB)].steps[] | select(.name == strenv(S_NAME)) | .run' "$yml"
}
# run_step JOB NAME DIR [docker]: run it in DIR, its declared env taken from this shell (a name it
# declares that this test does not provide is a failure: the workflow changed what a step reads)
run_step() {
  job="$1"; name="$2"; dir="$3"
  text="$(step "$job" "$name")"
  [ -n "$text" ] && [ "$text" != null ] || fail "$job: no step named \"$name\" in $yml"
  for k in $(S_JOB="$job" S_NAME="$name" yq -r '.jobs[strenv(S_JOB)].steps[] | select(.name == strenv(S_NAME)) | .env // {} | keys | .[]' "$yml"); do
    eval "[ -n \"\${$k+x}\" ]" || fail "$job/$name reads $k, which this test does not provide"
  done
  echo "--- $job: $name"
  ( cd "$dir" && sh -eu -c "$text" ) || fail "$job: $name"
}

# step_fails JOB NAME DIR: the step must refuse (exit non-zero) - a guard that never fires is no guard
step_fails() {
  job="$1"; name="$2"; dir="$3"
  text="$(step "$job" "$name")"
  [ -n "$text" ] && [ "$text" != null ] || fail "$job: no step named \"$name\" in $yml"
  echo "--- $job: $name (it must refuse)"
  if ( cd "$dir" && sh -eu -c "$text" ); then fail "$job: $name passed where it must refuse"; fi
}

origins() { tar -xzOf "$1" APKINDEX | sed -n 's/^o://p' | sort -u | tr '\n' ' '; }

# release PKG VERSION: one run of the workflow for that package at that version
release() {
  pkg="$1"; VERSION="$2"
  run="$tmp/run-$pkg-$VERSION"
  mkdir -p "$run/project/packaging/$pkg" "$run/pub/packaging"
  cp -R "$FIXTURES/$pkg/." "$run/project/packaging/$pkg/"
  cp "$tmp/$KEYNAME.pub" "$run/project/packaging/" && cp "$tmp/$KEYNAME.pub" "$run/pub/packaging/"
  export NAME="$pkg" REPO=conveyor-test APKBUILD="packaging/$pkg/APKBUILD" TITLE="conveyor test packages"
  export VERSION RELEASE KEY ARCH APK_SIGNING_KEY PAGES_BASE
  export GITHUB_REPOSITORY_OWNER=nobody GITHUB_REPOSITORY=nobody/conveyor-test

  run_step build "The APKBUILD for this release - its folder whole, its version" "$run"
  run_step build "The packages the repository already holds, kept" "$run"
  run_step build "Build (the project's code - in a container of its own, which never sees the key)" "$run"
  run_step build "Package and index, signed (a fresh container, the only one with the key)" "$run"

  cp -R "$run/out" "$run/pub/built"
  run_step publish "The front page, the key, and the repository" "$run/pub"
  run_step publish "Nothing is deployed unless every signature verifies" "$run/pub"
  run_step publish "Nothing already live is lost" "$run/pub"
  # the deploy: the site is replaced by this run's, as Pages replaces it
  docker run --rm -v "$tmp/pages:/p" -v "$run/pub/site:/s:ro" "alpine:$RELEASE" sh -c 'rm -rf /p/* /p/.[!.]* ; cp -a /s/. /p/'

  # the verify job: a clean Alpine, the page's own lines, every package it lists
  text="$(step verify "The page's own lines, then every package, as a phone takes it")"
  [ -n "$text" ] && [ "$text" != null ] || fail "verify: no install step in $yml"
  echo "--- verify: the page's own lines, then every package"
  docker run --rm --network host -e NAME -e VERSION -e REPO -e RELEASE -e PAGES_BASE \
    -e GITHUB_REPOSITORY_OWNER -e GITHUB_REPOSITORY "alpine:$RELEASE" sh -eu -c "$text" || fail "verify: install of $pkg $VERSION"
}

idx() { curl -fsS "$PAGES_BASE/alpine/v$RELEASE/conveyor-test/$ARCH/APKINDEX.tar.gz" -o "$tmp/live.tgz" && origins "$tmp/live.tgz"; }
apks() { find "$tmp/pages/alpine" -name "$1-[0-9]*.apk" | wc -l | tr -d ' '; }
saved() { cp "$tmp/pages/alpine/v$RELEASE/conveyor-test/$ARCH/APKINDEX.tar.gz" "$tmp/index-$1.tgz"; }

release fixt-one 1
[ "$(idx)" = "fixt-one " ] || fail "after fixt-one 1 the repository lists: $(idx)"
ok "fixt-one 1: a package with a source beside its APKBUILD is built, signed, listed and installs"
saved one

release fixt-two 1
[ "$(idx)" = "fixt-one fixt-two " ] || fail "after fixt-two 1 the repository lists: $(idx), not fixt-one and fixt-two"
[ "$(apks fixt-one)" = 1 ] && [ "$(apks fixt-two)" = 1 ] || fail "a package file is missing after fixt-two 1"
grep -q 'apk add fixt-one' "$tmp/pages/index.html" && grep -q 'apk add fixt-two' "$tmp/pages/index.html" || fail "the front page does not name both"
ok "fixt-two 1: the second package did not replace the first; both listed, both installed"
saved two

release fixt-one 2
[ "$(idx)" = "fixt-one fixt-two " ] || fail "after fixt-one 2 the repository lists: $(idx)"
[ "$(apks fixt-one)" = 1 ] && [ -f "$(find "$tmp/pages/alpine" -name 'fixt-one-2-r0.apk')" ] || fail "fixt-one 2 did not replace fixt-one 1"
[ "$(apks fixt-two)" = 1 ] || fail "fixt-two was lost when fixt-one was rebuilt"
ok "fixt-one 2: the rebuilt package replaced its own earlier one and kept the other"

# the guard before the deploy: a site that would lose what is live is refused
# (the pages hold fixt-one 2 and fixt-two 1; run-fixt-one-2/pub is the last release's publish folder)
refuse() {  # CASE NAME INDEX_OR_NONE: the live check on a copy of that site, with that index in it
  rm -rf "$tmp/neg"; cp -R "$tmp/run-fixt-one-2/pub" "$tmp/neg"
  i="$tmp/neg/site/alpine/v$RELEASE/conveyor-test/$ARCH/APKINDEX.tar.gz"
  if [ "$3" = none ]; then rm "$i"; else cp "$3" "$i"; fi
  NAME="$2" step_fails publish "Nothing already live is lost" "$tmp/neg"
  ok "refused: $1"
}
export REPO=conveyor-test RELEASE ARCH GITHUB_REPOSITORY_OWNER=nobody GITHUB_REPOSITORY=nobody/conveyor-test PAGES_BASE
refuse "a live package the site does not hold" fixt-one "$tmp/index-one.tgz"
refuse "a live package at a version the site does not hold" fixt-two "$tmp/index-two.tgz"
refuse "a live architecture the site has no index for" fixt-one none

echo "all ok"
