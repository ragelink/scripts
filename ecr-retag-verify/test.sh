#!/usr/bin/env bash
# Tests for ecr-retag-verify: bash ecr-retag-verify/test.sh [t_name ...]
#
# aws is a file-backed fake placed first on PATH. It serves `ecr batch-get-image`
# from the fixture registry built below, so nothing here touches AWS.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$HERE/ecr-retag-verify
BASE_PATH=$PATH
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ecr-retag-verify-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# ---------- fixture registry ----------
# Digests are synthetic: a three-letter hex label repeated with "0123", unique per
# name and free of long digit runs. digests.sh exports them as NAME=sha256:...
python3 - "$ROOT/registry.json" "$ROOT/digests.sh" <<'PY'
import json, sys

OCI_INDEX = "application/vnd.oci.image.index.v1+json"
DOCKER_LIST = "application/vnd.docker.distribution.manifest.list.v2+json"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
ATTESTATION = {"vnd.docker.reference.type": "attestation-manifest"}
D = {}

def dg(name):
    if name not in D:
        n = len(D)
        label = "".join("abcdef"[(n // 6 ** k) % 6] for k in (2, 1, 0))
        D[name] = "sha256:" + ((label + "0123") * 10)[:64]
    return D[name]

for name in ("CFG_AMD CFG_ARM CFG_NEW CFG_EXTRA CFG_ARMV6 CFG_ARMV7 CFG_ATT "
             "L1 L2 L3 L2Z L4 LA1 LA2 LV6 LV7 LATT").split():
    dg(name)

def image(media_type, config, layers, annotations=None):
    oci = media_type == OCI_MANIFEST
    m = {"schemaVersion": 2, "mediaType": media_type,
         "config": {"mediaType": "application/vnd.oci.image.config.v1+json" if oci
                    else "application/vnd.docker.container.image.v1+json", "digest": D[config], "size": 1469},
         "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip" if oci
                     else "application/vnd.docker.image.rootfs.diff.tar.gzip", "digest": D[l], "size": 3000 + i}
                    for i, l in enumerate(layers)]}
    if annotations:
        m["annotations"] = annotations
    return m

def entry(target, media_type, os_, arch, variant=None, annotations=None):
    e = {"mediaType": media_type, "digest": D[target], "size": 1000, "platform": {"architecture": arch, "os": os_}}
    if variant:
        e["platform"]["variant"] = variant
    if annotations:
        e["annotations"] = annotations
    return e

def index(media_type, entries):
    return {"schemaVersion": 2, "mediaType": media_type, "manifests": entries}

registry = {"my-app": {"tags": {}, "manifests": {}}, "my-app-prod": {"tags": {}, "manifests": {}}}

def put(repo, name, manifest, media_type="from-manifest", tags=()):
    # media_type None: the fake leaves imageManifestMediaType out of its response
    registry[repo]["manifests"][dg(name)] = {
        "mediaType": manifest.get("mediaType") if media_type == "from-manifest" else media_type,
        "manifest": json.dumps(manifest, indent=3)}
    for tag in tags:
        registry[repo]["tags"][tag] = D[name]

put("my-app", "IMG_AMD", image(OCI_MANIFEST, "CFG_AMD", ["L1", "L2", "L3"]), tags=["single"])
put("my-app", "IMG_AMD_DOCKER", image(DOCKER_MANIFEST, "CFG_AMD", ["L1", "L2", "L3"]), tags=["docker"])
put("my-app-prod", "IMG_AMD_DOCKER", image(DOCKER_MANIFEST, "CFG_AMD", ["L1", "L2", "L3"]), tags=["v1.2.3"])
put("my-app", "IMG_ARM", image(OCI_MANIFEST, "CFG_ARM", ["LA1", "LA2"]))
put("my-app", "IMG_ATT", {"schemaVersion": 2, "mediaType": OCI_MANIFEST,
                          "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                                     "digest": D["CFG_ATT"], "size": 167},
                          "layers": [{"mediaType": "application/vnd.in-toto+json", "digest": D["LATT"],
                                      "size": 1500}]})
put("my-app", "IMG_RECOMP", image(OCI_MANIFEST, "CFG_AMD", ["L1", "L2Z", "L3"]), tags=["recomp"])
put("my-app", "IMG_NEWCFG", image(OCI_MANIFEST, "CFG_NEW", ["L1", "L2", "L3"]), tags=["newcfg"])
put("my-app", "IMG_EXTRA", image(OCI_MANIFEST, "CFG_EXTRA", ["L1", "L2", "L3", "L4"]), tags=["extra"])
put("my-app", "IMG_SWAPPED", image(OCI_MANIFEST, "CFG_AMD", ["L2", "L1", "L3"]), tags=["swapped"])
put("my-app", "IMG_ARMV6", image(OCI_MANIFEST, "CFG_ARMV6", ["LV6"]))
put("my-app", "IMG_ARMV7", image(OCI_MANIFEST, "CFG_ARMV7", ["LV7"]))
put("my-app", "IMG_ANNOTATED", image(OCI_MANIFEST, "CFG_AMD", ["L1", "L2", "L3"],
                                     {"org.opencontainers.image.created": "2026-01-01T00:00:00Z"}), tags=["annotated"])
put("my-app", "IMG_FALLBACK", image(OCI_MANIFEST, "CFG_AMD", ["L1", "L2", "L3"]), media_type=None, tags=["fallback"])
untyped = image(OCI_MANIFEST, "CFG_AMD", ["L1", "L2", "L3"])
del untyped["mediaType"]
put("my-app", "IMG_UNTYPED", untyped, media_type=None, tags=["untyped"])
schema1 = {"schemaVersion": 1, "name": "my-app", "tag": "old", "architecture": "amd64",
           "fsLayers": [{"blobSum": D["L1"]}], "history": [{"v1Compatibility": "{}"}]}
put("my-app", "SCHEMA1", schema1, media_type="application/vnd.docker.distribution.manifest.v1+prettyjws",
    tags=["schema1"])
put("my-app", "SCHEMA1_UNTYPED", schema1, media_type=None, tags=["schema1nt"])
put("my-app", "ODDTYPE", {"schemaVersion": 2, "mediaType": "application/vnd.example.thing+json"},
    media_type=None, tags=["oddtype"])

put("my-app", "IDX_MULTI", index(OCI_INDEX, [
    entry("IMG_AMD", OCI_MANIFEST, "linux", "amd64"),
    entry("IMG_ARM", OCI_MANIFEST, "linux", "arm64", "v8"),
    entry("IMG_ATT", OCI_MANIFEST, "unknown", "unknown",
          annotations=dict(ATTESTATION, **{"vnd.docker.reference.digest": D["IMG_AMD"]})),
]), tags=["v1.2.3", "prod"])
put("my-app", "IDX_REBUILT", index(OCI_INDEX, [
    entry("IMG_AMD", OCI_MANIFEST, "linux", "amd64"),
    entry("IMG_ARM", OCI_MANIFEST, "linux", "arm64", "v8"),
]), tags=["rebuilt"])
put("my-app", "IDX_ATTFIRST", index(OCI_INDEX, [  # an attestation that claims a real platform, listed first
    entry("IMG_ATT", OCI_MANIFEST, "linux", "amd64", annotations=ATTESTATION),
    entry("IMG_AMD", OCI_MANIFEST, "linux", "amd64"),
]), tags=["attfirst"])
put("my-app", "IDX_LIST", index(DOCKER_LIST, [
    entry("IMG_AMD_DOCKER", DOCKER_MANIFEST, "linux", "amd64"),
]), tags=["list"])
put("my-app", "IDX_ARMONLY", index(OCI_INDEX, [
    entry("IMG_ARM", OCI_MANIFEST, "linux", "arm64", "v8"),
    entry("IMG_ATT", OCI_MANIFEST, "unknown", "unknown", annotations=ATTESTATION),
]), tags=["armonly"])
put("my-app", "IDX_ARM32", index(OCI_INDEX, [
    entry("IMG_ARMV6", OCI_MANIFEST, "linux", "arm", "v6"),
    entry("IMG_ARMV7", OCI_MANIFEST, "linux", "arm", "v7"),
]), tags=["arm32"])
put("my-app", "IDX_ARM64NV", index(OCI_INDEX, [
    entry("IMG_ARM", OCI_MANIFEST, "linux", "arm64"),
]), tags=["arm64nv"])
put("my-app", "IDX_NESTED", index(OCI_INDEX, [
    entry("IDX_REBUILT", OCI_INDEX, "linux", "amd64"),
]), tags=["nested"])

with open(sys.argv[1], "w") as f:
    json.dump(registry, f)
with open(sys.argv[2], "w") as f:
    f.writelines("%s=%s\n" % kv for kv in sorted(D.items()))
PY
# shellcheck source=/dev/null
. "$ROOT/digests.sh"

# ---------- fake aws ----------
FAKEBIN=$ROOT/bin
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/aws" <<'EOF'
#!/usr/bin/env python3
# File-backed fake of `aws ecr batch-get-image`: strict about its arguments, and it
# answers like the real API (unknown repository: an error; unknown image or a media
# type outside --accepted-media-types: an entry in "failures").
import json, os, sys

state = os.environ["FAKE"]
argv = sys.argv[1:]
with open(os.path.join(state, "aws.calls"), "a") as log:
    log.write(" ".join(argv) + "\n")

def fail(msg, code=254):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

if os.path.exists(os.path.join(state, "aws_broken")):
    fail('Unable to locate credentials. You can configure credentials by running "aws configure".', 253)

ACCEPTED = ["application/vnd.oci.image.index.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.v2+json"]
rest, i = [], 0
while i < len(argv):  # global options may come first
    if argv[i] in ("--profile", "--region") and i + 1 < len(argv):
        i += 2
        continue
    rest.append(argv[i])
    i += 1
if rest[:2] != ["ecr", "batch-get-image"]:
    fail("fake aws: unexpected call: " + " ".join(argv), 2)
opts, j = {}, 2
while j < len(rest):
    key = rest[j]
    if key in opts:
        fail("fake aws: repeated " + key, 2)
    if key == "--accepted-media-types":
        j += 1
        values = []
        while j < len(rest) and not rest[j].startswith("--"):
            values.append(rest[j])
            j += 1
        opts[key] = values
    elif key in ("--repository-name", "--registry-id", "--image-ids", "--output") and j + 1 < len(rest):
        opts[key] = rest[j + 1]
        j += 2
    else:
        fail("fake aws: unexpected argument: " + key, 2)
if (opts.get("--output") != "json" or opts.get("--accepted-media-types") != ACCEPTED
        or "--repository-name" not in opts or "--image-ids" not in opts):
    fail("fake aws: unexpected batch-get-image arguments: " + " ".join(argv), 2)

registry = json.load(open(os.environ["REGISTRY"]))
name = opts["--repository-name"]
repo = registry.get(name)
if repo is None:
    fail("An error occurred (RepositoryNotFoundException) when calling the BatchGetImage operation: "
         "The repository with name '%s' does not exist in the registry" % name)
kind, _, value = opts["--image-ids"].partition("=")
if kind == "imageTag":
    digest = repo["tags"].get(value)
elif kind == "imageDigest":
    digest = value if value in repo["manifests"] else None
else:
    fail("fake aws: bad --image-ids " + opts["--image-ids"], 2)
image_id = {kind: value}
out = {"images": [], "failures": []}
if digest is None:
    out["failures"].append({"imageId": image_id, "failureCode": "ImageNotFound",
                            "failureReason": "Requested image not found"})
else:
    stored = repo["manifests"][digest]
    if stored["mediaType"] and stored["mediaType"] not in ACCEPTED:
        out["failures"].append({"imageId": image_id, "failureCode": "UnsupportedImageType",
                                "failureReason": "The image manifest media type is not accepted"})
    else:
        img = {"repositoryName": name, "imageId": dict(image_id, imageDigest=digest),
               "imageManifest": stored["manifest"]}
        if stored["mediaType"]:
            img["imageManifestMediaType"] = stored["mediaType"]
        out["images"].append(img)
print(json.dumps(out, indent=4))
EOF
chmod +x "$FAKEBIN/aws"

# Refuse to run unless the fake wins on PATH: the tests must never reach real AWS.
[ "$(PATH=$FAKEBIN:$BASE_PATH command -v aws)" = "$FAKEBIN/aws" ] || { echo "fake aws is not first on PATH" >&2; exit 1; }

# ---------- helpers ----------
fail() { echo "    $*" >&2; exit 1; }
run() {  # run ARGS...: the tool's stdout and stderr in $FAKE/out and $FAKE/err, exit status in RC
  RC=0
  PATH=$FAKEBIN:$BASE_PATH "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" </dev/null || RC=$?
}
calls() {  # calls PATTERN: how many aws calls match PATTERN
  local n
  n=$(grep -c -- "$1" "$FAKE/aws.calls" 2>/dev/null) || true
  echo "${n:-0}"
}
expect_rc() { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC; stderr: $(cat "$FAKE/err")"; }
expect_out() { grep -qF -- "$1" "$FAKE/out" || fail "stdout lacks: $1"; }
expect_err() { grep -qF -- "$1" "$FAKE/err" || fail "stderr lacks: $1"; }
refute_out() {
  if grep -qF -- "$1" "$FAKE/out"; then fail "stdout has: $1"; fi
}

one_test() {  # runs in its own subshell, with fresh fake AWS state
  FAKE=$ROOT/$1
  mkdir -p "$FAKE"
  export FAKE REGISTRY=$ROOT/registry.json AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION
  "$1"
}

PASSED=0
FAILED=""
run_test() {
  local rc=0
  set +e
  (set -e; one_test "$1")
  rc=$?
  set -e
  if [ $rc = 0 ]; then
    PASSED=$((PASSED + 1))
    echo "ok   $1"
  else
    FAILED="$FAILED $1"
    echo "FAIL $1"
  fi
}

# ---------- identical content ----------
t_same_digest_on_both_tags() {
  run --repository my-app v1.2.3 prod
  expect_rc 0
  expect_out "result    identical content (same manifest digest)"
  expect_out "manifest  $IDX_MULTI  OCI image index (linux/amd64, linux/arm64/v8; 1 attestation)"
  refute_out "why the digests differ"
  [ "$(calls "imageDigest=$IMG_AMD")" = 1 ] || fail "the platform manifest should be fetched once"
}

t_index_vs_single_manifest() {
  run --repository my-app v1.2.3 single
  expect_rc 0
  expect_out "image     $IMG_AMD  OCI image manifest for linux/amd64"
  expect_out "image     same as manifest (single-platform; platform not checked)"
  expect_out "config    same       $CFG_AMD"
  expect_out "layers    same       3 layers"
  expect_out "result    identical content"
  expect_out "source is a multi-platform index and target a single-platform manifest"
  expect_out "aws ecr put-image with the original manifest"
}

t_docker_vs_oci_media_types() {
  run --repository my-app single docker
  expect_rc 0
  expect_out "manifest  $IMG_AMD_DOCKER  Docker image manifest v2"
  expect_out "the image manifests use different media types (OCI image manifest vs Docker image manifest v2)"
  run --repository my-app list v1.2.3
  expect_rc 0
  expect_out "the indexes use different media types (Docker manifest list vs OCI image index)"
}

t_rebuilt_index_without_attestations() {
  run --repository my-app v1.2.3 rebuilt
  expect_rc 0
  expect_out "the indexes list different entries (source: linux/amd64, linux/arm64/v8; 1 attestation; target: linux/amd64, linux/arm64/v8; no attestations)"
  refute_out "image manifests"
}

t_annotations_differ() {
  run --repository my-app single annotated
  expect_rc 0
  expect_out "the image manifests carry different annotations"
}

# ---------- different content ----------
t_recompressed_layer() {
  run --repository my-app single recomp
  expect_rc 1
  expect_out "config    same       $CFG_AMD"
  expect_out "layers    DIFFERENT  source 3, target 3; first difference at index 1; 1 added, 1 removed"
  expect_out "result    content differs"
  expect_out "the layers were most likely recompressed"
}

t_different_config() {
  run --repository my-app single newcfg
  expect_rc 1
  expect_out "config    DIFFERENT  source $CFG_AMD"
  expect_out "target $CFG_NEW"
  expect_out "layers    same       3 layers"
  expect_out "the layers are identical but the configs differ"
}

t_layer_added() {
  run --repository my-app single extra
  expect_rc 1
  expect_out "layers    DIFFERENT  source 3, target 4; first difference at index 3; 1 added, 0 removed"
  expect_out "a rebuild almost always changes it"
  expect_out "recompression changes them even for the same files"
}

t_layer_order_matters() {
  run --repository my-app single swapped
  expect_rc 1
  expect_out "first difference at index 0; 0 added, 0 removed"
  expect_out "both sides have the same layers, in a different order"
}

# ---------- platforms ----------
t_platform_arm64() {
  run --platform linux/arm64 --repository my-app v1.2.3 rebuilt
  expect_rc 0
  expect_out "image     $IMG_ARM  OCI image manifest for linux/arm64/v8"
  refute_out "$IMG_AMD"
}

t_arm64_without_variant_matches_v8() {
  run --platform linux/arm64/v8 --repository my-app arm64nv v1.2.3
  expect_rc 0
  expect_out "image     $IMG_ARM  OCI image manifest for linux/arm64"
}

t_arm_variants() {
  run --platform linux/arm/v7 --repository my-app arm32 arm32
  expect_rc 0
  expect_out "image     $IMG_ARMV7  OCI image manifest for linux/arm/v7"
  refute_out "$IMG_ARMV6"
  run --platform linux/arm --repository my-app arm32 arm32
  expect_rc 2
  expect_err "linux/arm matches several images (linux/arm/v6, linux/arm/v7); add a variant to --platform"
}

t_attestations_skipped() {
  run --repository my-app attfirst single
  expect_rc 0
  expect_out "image     $IMG_AMD  OCI image manifest for linux/amd64"
  expect_out "OCI image index (linux/amd64; 1 attestation)"
  [ "$(calls "imageDigest=$IMG_ATT")" = 0 ] || fail "fetched the attestation manifest"
}

t_platform_missing() {
  run --repository my-app armonly single
  expect_rc 2
  expect_err "source my-app:armonly: no linux/amd64 image in the index; it has: linux/arm64/v8"
  if grep -q unknown "$FAKE/err"; then fail "attestations listed as platforms"; fi
  [ ! -s "$FAKE/out" ] || fail "printed a report"
}

# ---------- references and lookups ----------
t_tag_not_found() {
  run --repository my-app v1.2.3 nope
  expect_rc 2
  expect_err "target my-app:nope: ImageNotFound (Requested image not found)"
  [ ! -s "$FAKE/out" ] || fail "printed a report"
}

t_repository_not_found() {
  run nosuch:v1 my-app:v1.2.3
  expect_rc 2
  expect_err "aws ecr batch-get-image failed: An error occurred (RepositoryNotFoundException)"
}

t_cross_repository_promotion() {
  run my-app:v1.2.3 my-app-prod:v1.2.3
  expect_rc 0
  expect_out "target    my-app-prod:v1.2.3"
  expect_out "result    identical content"
  [ "$(calls "--repository-name my-app-prod --image-ids imageTag=v1.2.3 ")" = 1 ] || fail "target not read from my-app-prod"
}

t_digest_references() {
  run "my-app@$IMG_AMD" my-app:docker
  expect_rc 0
  expect_out "source    my-app@$IMG_AMD"
  [ "$(calls "--repository-name my-app --image-ids imageDigest=$IMG_AMD ")" = 1 ] || fail "not fetched by digest"
  run --repository my-app "$IMG_AMD" single
  expect_rc 0
  expect_out "result    identical content (same manifest digest)"
}

t_json_report() {
  run --json --repository my-app single recomp
  expect_rc 1
  python3 - "$FAKE/out" "$IMG_AMD" "$L2" "$L2Z" <<'PY' || fail "unexpected JSON report"
import json, sys
r = json.load(open(sys.argv[1]))
image, l2, l2z = sys.argv[2:5]
assert r["identical"] is False and r["platform"] == "linux/amd64", r
assert r["config"]["same"] is True, r["config"]
layers = r["layers"]
assert (layers["same"], layers["source_count"], layers["target_count"], layers["first_difference"]) == (False, 3, 3, 1), layers
assert layers["added"] == [l2z] and layers["removed"] == [l2], layers
assert r["source"]["image"]["digest"] == image and r["source"]["manifest"]["index"] is False, r["source"]
assert r["source"]["reference"] == "my-app:single" and r["source"]["tag"] == "single", r["source"]
assert r["notes"], r
PY
  run --json --repository my-app v1.2.3 single
  expect_rc 0
  python3 - "$FAKE/out" <<'PY' || fail "unexpected JSON report"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["identical"] is True and r["manifest_digests_equal"] is False and r["image_digests_equal"] is True, r
assert r["source"]["image"]["platform"] == "linux/amd64" and r["target"]["image"]["platform"] is None, r
assert r["source"]["manifest"]["platforms"] == ["linux/amd64", "linux/arm64/v8"], r["source"]["manifest"]
assert r["source"]["manifest"]["attestations"] == 1 and len(r["source"]["layers"]) == 3, r["source"]
PY
}

t_profile_region_registry_id_on_every_call() {
  run --profile acme --region eu-west-1 --registry-id 123456 --repository my-app v1.2.3 single
  expect_rc 0
  [ "$(calls "")" = 3 ] || fail "expected 3 aws calls (index, its amd64 image, single)"
  [ "$(calls "^--profile acme --region eu-west-1 ecr batch-get-image --repository-name my-app --registry-id 123456 ")" = 3 ] ||
    fail "--profile, --region or --registry-id missing from a call"
  mv "$FAKE/aws.calls" "$FAKE/aws.calls.first"
  run --repository my-app v1.2.3 single
  expect_rc 0
  [ "$(calls "^ecr batch-get-image --repository-name my-app --image-ids ")" = 3 ] ||
    fail "without the options, calls must not carry them"
}

# ---------- unsupported manifests and failures ----------
t_unsupported_media_types() {
  run --repository my-app schema1 single
  expect_rc 2
  expect_err "source my-app:schema1: UnsupportedImageType"
  run --repository my-app schema1nt single
  expect_rc 2
  expect_err "Docker schema 1 manifests are not supported"
  run --repository my-app oddtype single
  expect_rc 2
  expect_err "unsupported manifest media type application/vnd.example.thing+json"
}

t_media_type_fallbacks() {
  run --repository my-app fallback single  # no imageManifestMediaType: use the manifest's own
  expect_rc 0
  expect_out "manifest  $IMG_FALLBACK  OCI image manifest"
  run --repository my-app untyped single  # no media type anywhere: go by structure
  expect_rc 0
  expect_out "manifest  $IMG_UNTYPED  OCI image manifest"
}

t_nested_index_rejected() {
  run --repository my-app nested single
  expect_rc 2
  expect_err "source my-app:nested: nested indexes are not supported"
}

t_aws_failure() {
  touch "$FAKE/aws_broken"
  run --repository my-app v1.2.3 single
  expect_rc 2
  expect_err "Unable to locate credentials"
  [ ! -s "$FAKE/out" ] || fail "printed a report"
}

t_argument_errors() {
  run
  expect_rc 2
  expect_err "usage: ecr-retag-verify"
  run my-app:v1.2.3
  expect_rc 2
  expect_err "the following arguments are required: TARGET"
  run v1.2.3 prod
  expect_rc 2
  expect_err "v1.2.3: no repository"
  run --platform linux my-app:a my-app:b
  expect_rc 2
  expect_err "expected OS/ARCH or OS/ARCH/VARIANT"
  run my-app@sha256:abc my-app:b
  expect_rc 2
  expect_err "invalid digest"
  run "My-App:v1" my-app:b
  expect_rc 2
  expect_err "invalid repository name"
  run --bogus my-app:a my-app:b
  expect_rc 2
  expect_err "unrecognized arguments: --bogus"
  run -h
  expect_rc 0
  expect_out "usage: ecr-retag-verify"
  expect_out "exit status: 0 identical content, 1 content differs, 2 usage or runtime error"
  run -V
  expect_rc 0
  expect_out "ecr-retag-verify 1.0.0"
  [ ! -e "$FAKE/aws.calls" ] || fail "aws ran for invalid arguments"
}

echo "ecr-retag-verify tests, $(python3 --version)"
for t in ${1+"$@"}; do
  declare -F "$t" >/dev/null || { echo "no such test: $t" >&2; exit 2; }
done
for t in ${1+"$@"} $([ $# -gt 0 ] || declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  run_test "$t"
done
echo "$PASSED passed${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
