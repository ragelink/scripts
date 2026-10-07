# ecr-retag-verify

Check that two ECR image references hold the same image content, even when their
manifest digests differ.

```sh
ecr-retag-verify --repository my-app v1.2.3 prod
```

## Why

Promoting an image usually means giving a tested image a new tag (`v1.2.3` to
`prod`) or copying it to another repository. Afterwards you want proof that what
you deploy is the bits you tested. Comparing digests is the obvious check, and it
raises false alarms: the same image content can sit behind different manifest
digests (see the primer below).

ecr-retag-verify resolves both references to the image manifest for one platform
and compares what actually defines the image: the config digest and the ordered
list of layer digests. When the content is identical but digests differ, it says
why. When the content differs, it says where.

## Install

Needs python3 (3.8 or later) and the AWS CLI. Only manifests are read; no layer is
downloaded. Copy the script to any directory on your `PATH`:

```sh
install -m 0755 ecr-retag-verify/ecr-retag-verify ~/.local/bin/ecr-retag-verify
```

## Usage

```sh
# Did tagging v1.2.3 as prod keep the same image? (bare tags use --repository)
ecr-retag-verify --repository my-app v1.2.3 prod

# Promotion between repositories
ecr-retag-verify my-app:v1.2.3 my-app-prod:v1.2.3 --profile acme --region eu-west-1

# A digest against a tag, comparing the arm64 image of multi-platform indexes
ecr-retag-verify --platform linux/arm64 my-app@sha256:<digest> my-app:prod

# In a pipeline: the exit status decides, the JSON report is kept
ecr-retag-verify --json my-app:v1.2.3 my-app-prod:v1.2.3 > retag-report.json
```

A reference is `TAG`, `sha256:DIGEST`, `REPO:TAG` or `REPO@sha256:DIGEST`. Bare
tags and digests use `--repository`. Pass repository names, not registry URIs.

| Option | Meaning |
|---|---|
| `--repository REPO` | repository for bare tags and digests |
| `--platform OS/ARCH[/VARIANT]` | platform to pick from multi-platform indexes (default `linux/amd64`) |
| `--registry-id ID` | registry id (`<registry-id>`, an account id), when not the caller's account |
| `--json` | print the report as one JSON object |
| `--profile NAME`, `--region NAME` | AWS profile and region |

Example report (digests shortened):

```
source    my-app:v1.2.3
  manifest  sha256:7d4c…  OCI image index (linux/amd64, linux/arm64/v8; 1 attestation)
  image     sha256:e1b0…  OCI image manifest for linux/amd64
target    my-app-prod:v1.2.3
  manifest  sha256:a3f9…  Docker image manifest v2
  image     same as manifest (single-platform; platform not checked)
config    same       sha256:5c2e…
layers    same       3 layers
result    identical content

why the digests differ:
  - source is a multi-platform index and target a single-platform manifest: an index digest covers every platform and attestation it lists, so it never equals a platform manifest's digest
  - the image manifests use different media types (OCI image manifest vs Docker image manifest v2): converting between Docker and OCI formats rewrites the manifest, and so its digest
  - a retag inside the registry (aws ecr put-image with the original manifest) keeps the digest; pulling and pushing the image again may not
```

When the content differs, the report shows whether the config differs, and for
the layers: the counts, the first differing index (counting from 0), and how
many layer digests were added or removed.

Platform matching: `--platform linux/arm64` matches any arm64 variant, and
`linux/arm64/v8` also matches an arm64 entry that has no variant. Attestation
entries (`unknown/unknown`, or annotated as `attestation-manifest`) are skipped.
If several entries match, add the variant.

## Exit status

| Code | Meaning |
|---|---|
| 0 | identical image content (same config digest, same ordered layer digests) |
| 1 | the content differs |
| 2 | usage error, or a runtime error: image, repository or platform not found, unsupported manifest type, aws CLI failure |

## Digest primer

- Every image in ECR is a **manifest**. The digest you see is the sha256 of the
  manifest's bytes, so any change to those bytes changes it.
- A single-platform **image manifest** lists a config blob and layer blobs by
  digest. The config holds the environment, entrypoint, labels and build history,
  plus the digests of the uncompressed layers (`rootfs.diff_ids`). Config plus
  layers *are* the image.
- A multi-platform image is an **index** (an OCI image index or a Docker manifest
  list) that points at one image manifest per platform. BuildKit also adds
  attestation manifests (provenance, SBOM) that show up as `unknown/unknown`.

So the same content can sit behind different digests:

- **Index vs. single manifest.** An index digest covers every platform and
  attestation it lists, so it never equals a platform manifest's digest.
- **A rebuilt index.** Recreating an index with or without attestations, or with
  other platforms, gives it a new digest even when each platform's image is
  unchanged.
- **Docker vs. OCI media types.** Converting a manifest between the two formats
  rewrites its bytes.
- **Re-pushing.** `docker pull`, `docker tag` and `docker push`, or copying with a
  tool that rebuilds manifests, can rewrite the manifest (and drop or change
  annotations).

Layer digests are digests of the *compressed* blobs. Recompressing a layer (with
another tool, compression level or algorithm) changes its digest even when the
files inside are the same. If the configs match but layer digests differ, that is
almost always the cause, since the config pins the uncompressed contents.

A retag inside the registry keeps the digest, because it copies the manifest
bytes unchanged:

```sh
MANIFEST=$(aws ecr batch-get-image --repository-name my-app --image-ids imageTag=v1.2.3 \
  --accepted-media-types application/vnd.oci.image.index.v1+json \
    application/vnd.docker.distribution.manifest.list.v2+json \
    application/vnd.oci.image.manifest.v1+json \
    application/vnd.docker.distribution.manifest.v2+json \
  --query 'images[0].imageManifest' --output text)
aws ecr put-image --repository-name my-app --image-tag prod --image-manifest "$MANIFEST"
```

Afterwards, `ecr-retag-verify --repository my-app v1.2.3 prod` should report
`identical content (same manifest digest)`.

## IAM permissions

`ecr:BatchGetImage` on the repositories you compare. `ecr:GetDownloadUrlForLayer`
is not needed, because only manifests are read, never layers or config blobs.

## Limits

- A single-platform manifest is compared as is. Its platform is recorded in the
  config blob, which this tool does not download, so `--platform` cannot be
  checked against it.
- Nested indexes (an index entry that is itself an index) and Docker schema 1
  manifests are reported as errors.
- The comparison is of stored content. It cannot tell you that two different
  layer blobs hold the same files, only (via the config) that they probably do.

## Tests

`bash ecr-retag-verify/test.sh` runs the suite against a file-backed fake of
`aws ecr batch-get-image` serving a fixture registry: indexes with attestations,
Docker and OCI manifests, recompressed and reordered layers, and unsupported
media types. Nothing touches AWS. Name tests to run a subset:
`bash ecr-retag-verify/test.sh t_platform_arm64 t_json_report`.
