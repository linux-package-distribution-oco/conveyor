#!/bin/sh
# The conveyor's own test of alpine.yml: the workflow's steps themselves, taken out of the file with yq
# and run in order against a pages site served on this machine - the same text a release runs, so a test
# cannot drift from the workflow (decision 2026-11-11-scripts-inline: the scripts live in the workflow).
#
# Four releases of two fixture packages whose source is a file beside the APKBUILD, as sxmo-utils's is:
#   fixt-one 1  -> the repository lists fixt-one, which installs
#   fixt-two 1  -> the repository lists fixt-one AND fixt-two (the second must not replace the first)
#   fixt-one 2  -> fixt-one at 2 only (the old one dropped), fixt-two still there
#   fixt-one 3, fixt-two retired by the declaration -> fixt-one only: listed, served, on the page
# Each release runs: the APKBUILD step, the kept-packages step, build, signed packaging, the front page,
# the live check, the signature check, a (local) deploy, and the verify job's install step in a clean Alpine.
#
# And the front page names, per package, what the reader of a redistributed binary is owed (AGPL-3.0 6(d)):
# its licence, its origin and where the exact source is - derived from the APKBUILD and the index, kept for
# the packages an earlier run published, and not lost for a package published before the conveyor kept them.
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
  export TAG="$pkg-v$VERSION"
  export RETIRE="${RETIRE:-}"
  # the publish job has the tag checked out: the package's folder as the project committed it
  mkdir -p "$run/pub/packaging/$pkg" && cp -R "$FIXTURES/$pkg/." "$run/pub/packaging/$pkg/"

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

# the front page's section of one package (the page writes each section over several lines)
section() { sed -n "/<section id=\"$1\">/,/<\/section>/p" "$tmp/pages/index.html"; }
# owes PKG TEXT...: the page says each text under that package - its licence, origin, source (AGPL-3.0 6(d))
owes() {
  s="$(section "$1")"; [ -n "$s" ] || fail "the front page has no section for $1"; p="$1"; shift
  for t in "$@"; do printf '%s\n' "$s" | grep -qF -- "$t" || fail "the front page does not say, of $p: $t"; done
}

release fixt-one 1
[ "$(idx)" = "fixt-one " ] || fail "after fixt-one 1 the repository lists: $(idx)"
ok "fixt-one 1: a package with a source beside its APKBUILD is built, signed, listed and installs"
saved one
owes fixt-one "MIT" "https://example.invalid/fixt-one" "fixture one, written for the conveyor's own test (no upstream)" \
  "https://github.com/nobody/conveyor-test/tree/fixt-one-v1/packaging/fixt-one"
ok "fixt-one 1: the page names its licence, its origin and where its exact source is"

release fixt-two 1
[ "$(idx)" = "fixt-one fixt-two " ] || fail "after fixt-two 1 the repository lists: $(idx), not fixt-one and fixt-two"
[ "$(apks fixt-one)" = 1 ] && [ "$(apks fixt-two)" = 1 ] || fail "a package file is missing after fixt-two 1"
grep -q 'apk add fixt-one' "$tmp/pages/index.html" && grep -q 'apk add fixt-two' "$tmp/pages/index.html" || fail "the front page does not name both"
ok "fixt-two 1: the second package did not replace the first; both listed, both installed"
saved two
owes fixt-two "AGPL-3.0-only" "https://example.invalid/fixt-two" "fixture two by an imaginary upstream" \
  "https://github.com/nobody/conveyor-test/tree/fixt-two-v1/packaging/fixt-two"
owes fixt-one "MIT" "fixture one, written for the conveyor's own test" "tree/fixt-one-v1/packaging/fixt-one"
owes fixt-two '&lt;b&gt; &amp; &quot;q&quot;'
ok "fixt-two 1: the page names the second package's licence, origin and source, and the first's as before"

release fixt-one 2
[ "$(idx)" = "fixt-one fixt-two " ] || fail "after fixt-one 2 the repository lists: $(idx)"
[ "$(apks fixt-one)" = 1 ] && [ -f "$(find "$tmp/pages/alpine" -name 'fixt-one-2-r0.apk')" ] || fail "fixt-one 2 did not replace fixt-one 1"
[ "$(apks fixt-two)" = 1 ] || fail "fixt-two was lost when fixt-one was rebuilt"
ok "fixt-one 2: the rebuilt package replaced its own earlier one and kept the other"
owes fixt-one "tree/fixt-one-v2/packaging/fixt-one"
owes fixt-two "AGPL-3.0-only" "fixture two by an imaginary upstream" "tree/fixt-two-v1/packaging/fixt-two"
section fixt-one | grep -qF "fixt-one-v1" && fail "the page still points fixt-one at its first release's source"
ok "fixt-one 2: the page's source for it is the new tag's, and the other package's is kept"

# the page of a package whose source is a tarball at a public tag, the tag made from pkgver (as sxmo-utils's
# is): the URL as the APKBUILD expands it for the release, the files beside the APKBUILD as the tag's folder
# (the page step, on a fresh copy of the last release's publish folder, with another APKBUILD in it)
rm -rf "$tmp/pg"; cp -R "$tmp/run-fixt-one-2/pub" "$tmp/pg"; rm -rf "$tmp/pg/site"
cp "$FIXTURES/page-url/APKBUILD" "$tmp/pg/packaging/fixt-one/APKBUILD"
( export VERSION=1.18.1_p20261118 TAG=sxmo-utils-v1.18.1_p20261118 NAME=fixt-one
  run_step publish "The front page, the key, and the repository" "$tmp/pg" )
s="$(sed -n '/<section id="fixt-one">/,/<\/section>/p' "$tmp/pg/site/index.html")"
for t in "https://github.com/grenudi/sxmo-utils/archive/refs/tags/lab-20261118.1.tar.gz" \
  "sxmo-utils by ~mil on sr.ht; APKBUILD from Alpine aports; source our fork at the lab tag" \
  "tree/sxmo-utils-v1.18.1_p20261118/packaging/fixt-one"; do
  printf '%s\n' "$s" | grep -qF -- "$t" || fail "the page does not say, of a package at a public tag: $t"
done
ok "a source at a public tag: the page gives the tag's tarball as the APKBUILD expands it, and the folder at the release tag"

# a package that is live without the record the conveyor keeps (published before it kept one): the page
# still comes, with the licence and the url the index carries, and says the rest is not recorded yet
rm "$tmp/pages/alpine/v$RELEASE/conveyor-test/origins/fixt-two.json" || fail "the earlier run kept no record of fixt-two beside the index"
rm -rf "$tmp/pg"; cp -R "$tmp/run-fixt-one-2/pub" "$tmp/pg"; rm -rf "$tmp/pg/site"
( export NAME=fixt-one; run_step publish "The front page, the key, and the repository" "$tmp/pg" )
s="$(sed -n '/<section id="fixt-two">/,/<\/section>/p' "$tmp/pg/site/index.html")"
for t in "AGPL-3.0-only" "https://example.invalid/fixt-two" "not recorded"; do
  printf '%s\n' "$s" | grep -qF -- "$t" || fail "a package live without a record: the page does not say: $t"
done
ok "a package published before the record was kept: licence and url from the index, the rest said not recorded"

# an APKBUILD with no Origin line: the page says the origin is not stated, and still gives the source
rm -rf "$tmp/pg"; cp -R "$tmp/run-fixt-one-2/pub" "$tmp/pg"; rm -rf "$tmp/pg/site"
grep -v '^# Origin:' "$FIXTURES/page-url/APKBUILD" > "$tmp/pg/packaging/fixt-one/APKBUILD"
( export NAME=fixt-one; run_step publish "The front page, the key, and the repository" "$tmp/pg" )
s="$(sed -n '/<section id="fixt-one">/,/<\/section>/p' "$tmp/pg/site/index.html")"
for t in "not stated" "tree/fixt-one-v2/packaging/fixt-one"; do
  printf '%s\n' "$s" | grep -qF -- "$t" || fail "an APKBUILD with no Origin line: the page does not say: $t"
done
ok "an APKBUILD with no Origin line: the page says the origin is not stated"

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


# a retirement: a package the project no longer ships is dropped on purpose, and only when declared
# (`[alpine] retire = [...]`, read by the plan job as RETIRE): without it the deploy is refused (above:
# refuse "a live package the site does not hold"); with it the same site goes; a loss that is not
# declared is still refused.
rm -rf "$tmp/neg"; cp -R "$tmp/run-fixt-one-2/pub" "$tmp/neg"
cp "$tmp/index-one.tgz" "$tmp/neg/site/alpine/v$RELEASE/conveyor-test/$ARCH/APKINDEX.tar.gz"
( export NAME=fixt-one RETIRE=fixt-two; run_step publish "Nothing already live is lost" "$tmp/neg" )
ok "retired: a live package the site does not hold is let go when the declaration retires it"
rm -rf "$tmp/neg"; cp -R "$tmp/run-fixt-one-2/pub" "$tmp/neg"
cp "$tmp/index-two.tgz" "$tmp/neg/site/alpine/v$RELEASE/conveyor-test/$ARCH/APKINDEX.tar.gz"
( export NAME=fixt-two RETIRE=fixt-two; step_fails publish "Nothing already live is lost" "$tmp/neg" )
ok "refused: a loss the declaration does not retire (fixt-one, while fixt-two is retired)"

# and the release that retires: fixt-two is not kept, so it leaves the index, the pages and the page's list
( export RETIRE=fixt-two; release fixt-one 3 )
[ "$(idx)" = "fixt-one " ] || fail "after fixt-one 3 retiring fixt-two the repository lists: $(idx)"
[ "$(apks fixt-two)" = 0 ] || fail "the retired fixt-two is still served"
grep -q 'apk add fixt-two' "$tmp/pages/index.html" && fail "the front page still offers the retired fixt-two"
[ -z "$(section fixt-two)" ] || fail "the front page still has a section for the retired fixt-two"
[ -f "$tmp/pages/alpine/v$RELEASE/conveyor-test/origins/fixt-two.json" ] && fail "the record of the retired fixt-two is still served"
owes fixt-one "MIT" "tree/fixt-one-v3/packaging/fixt-one"
ok "fixt-one 3 retiring fixt-two: only fixt-one is listed, served and on the page"

# the declaration's side: the plan job reads `[alpine] retire` as a list of package names, and stops on
# anything else, and on a package retiring itself
plan_with() {  # RETIRE_LINE: the plan step's directory, with a declaration that has that line under [alpine]
  rm -rf "$tmp/plan"; mkdir -p "$tmp/plan/packaging"; touch "$tmp/plan/out" "$tmp/plan/packaging/k.pub"
  printf '[package]\nname = "fixt-one"\n\n[alpine]\napkbuild = "packaging/fixt-one/APKBUILD"\nkey = "packaging/k.pub"\n%s\n' "$1" > "$tmp/plan/packaging/conveyor.toml"
}
plan_with 'retire = ["fixt-two", "fixt-three"]'
( export DECLARATION=packaging/conveyor.toml TAG=v1 GITHUB_OUTPUT="$tmp/plan/out" RETIRE_NOW=""; run_step plan "The declaration, read" "$tmp/plan" ) >/dev/null
grep -qx 'retire=fixt-two fixt-three' "$tmp/plan/out" || fail "the plan step does not hand on the retired names: $(grep retire "$tmp/plan/out")"
plan_with ''
( export DECLARATION=packaging/conveyor.toml TAG=v1 GITHUB_OUTPUT="$tmp/plan/out" RETIRE_NOW=""; run_step plan "The declaration, read" "$tmp/plan" ) >/dev/null
grep -qx 'retire=' "$tmp/plan/out" || fail "a declaration with no retire line retires nothing"
for bad in 'retire = ["fixt-one"]' 'retire = "fixt-two"' 'retire = ["fixt two"]' 'retire = [1]'; do
  plan_with "$bad"
  ( export DECLARATION=packaging/conveyor.toml TAG=v1 GITHUB_OUTPUT="$tmp/plan/out" RETIRE_NOW=""; step_fails plan "The declaration, read" "$tmp/plan" ) >/dev/null 2>&1 || fail "the plan step takes: $bad"
done
ok "the declaration: retire is a list of package names, none of them its own"

# a retirement made after the release tag cannot be in the declaration the tag holds: the caller may say it
# in the call (`retire:`, a space-separated list), and it is merged with the declaration's
plan_with 'retire = ["fixt-two"]'
( export DECLARATION=packaging/conveyor.toml TAG=v1 GITHUB_OUTPUT="$tmp/plan/out" RETIRE_NOW="fixt-three fixt-two"; run_step plan "The declaration, read" "$tmp/plan" ) >/dev/null
grep -qx 'retire=fixt-two fixt-three' "$tmp/plan/out" || fail "the plan step does not merge the call's retire with the declaration's: $(grep retire "$tmp/plan/out")"
plan_with ''
( export DECLARATION=packaging/conveyor.toml TAG=v1 GITHUB_OUTPUT="$tmp/plan/out" RETIRE_NOW="fixt-two"; run_step plan "The declaration, read" "$tmp/plan" ) >/dev/null
grep -qx 'retire=fixt-two' "$tmp/plan/out" || fail "the plan step does not take the call's retire alone: $(grep retire "$tmp/plan/out")"
for bad in "fixt-one" "fixt/two" "-x" "a;b"; do
  plan_with ''
  ( export DECLARATION=packaging/conveyor.toml TAG=v1 GITHUB_OUTPUT="$tmp/plan/out" RETIRE_NOW="$bad"; step_fails plan "The declaration, read" "$tmp/plan" ) >/dev/null 2>&1 || fail "the plan step takes a call that retires: $bad"
done
ok "the call's retire: merged with the declaration's, names only, none the run's own"

echo "all ok"
