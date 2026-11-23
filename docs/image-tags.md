# Image tags

This page sets how the SEAD images on ghcr.io are tagged, and which image
reference a node pins. The rules apply to every image below.

## Images

| Image | Kind |
|-------|------|
| `ghcr.io/stardome-technology/stardome-sead/sead-core` | service |
| `ghcr.io/stardome-technology/stardome-sead/edge-service` | service |
| `ghcr.io/stardome-technology/stardome-sead/pin-service` | service |
| `ghcr.io/stardome-technology/stardome-sead/source-data-service` | service |
| `ghcr.io/stardome-technology/stardome-sead/gossip-node` | service |
| `ghcr.io/stardome-technology/stardome-sead-gateway` | service |
| `ghcr.io/stardome-technology/stardome-sead/keygen` | tool |
| `ghcr.io/stardome-technology/stardome-sead/gen-token` | tool |
| `ghcr.io/stardome-technology/stardome-sead/gen-bootstrap` | tool |
| `ghcr.io/stardome-technology/stardome-sead/p2p-bridge` | tool, once it is published |

Each image is a multi-arch index for `linux/amd64` and `linux/arm64`.
The Compose files run the service images; operators run the tool images
with `docker run`. `p2p-bridge` isn't public on ghcr.io yet; these rules
apply to it once it is.

## Tags

| Tag | Names | Moves | A node pins it |
|-----|-------|-------|----------------|
| `X.Y.Z`, such as `1.4.0` | a release | never | yes, with its digest |
| `latest` | the newest build of `main` | on every push to `main` | never |
| `<tag>-amd64`, `<tag>-arm64` | one architecture's image for `<tag>` | with `<tag>` | never |

- **`X.Y.Z`** is a release. Stardome's CI publishes it when a git tag
  `vX.Y.Z` is pushed to the image's source repository, for both
  architectures. A release tag is never moved or deleted once published: to
  ship a fix, publish a new version.
- **`latest`** is for development. Stardome's CI moves it on every push to
  `main`, and a release build moves it too. Two nodes that pull `latest` at
  different times can run different builds.
- **`<tag>-amd64` and `<tag>-arm64`** are build steps. CI pushes one image per
  architecture under these tags, then merges them into the multi-arch index
  that `<tag>` names. They are not releases, and a node never pins them.

## What a node pins

A production node references each image by its release tag and the digest
of the multi-arch index that tag names:
`<image>:X.Y.Z@sha256:<index digest>`.

Docker pulls by the digest, so a node runs the same build until the digest
changes. The tag stays in the reference so readers and update tools can tell
which tag the digest was read from.

None of these is a production pin:

- `latest`, alone or with its digest, since it moves on every push to
  `main` and names no release;
- a per-arch tag, since it moves with every build of its tag and covers one
  architecture only.

Read an index digest with:

```bash
docker buildx imagetools inspect ghcr.io/stardome-technology/stardome-sead/sead-core:0.1.0
```

and take the `Digest:` line under `Name:`, the digest of the index, not one
of the per-platform digests listed under `Manifests:`.

## Where the images stand

The first release is `0.1.0`. Stardome's CI published it, for both
architectures, for every image in the table except `p2p-bridge`: the six
service images and `keygen`, `gen-token` and `gen-bootstrap`. The same CI
now builds all of them, and moves `latest` with each push to `main`.
`p2p-bridge` is deprecated, since gossip-node replaces it, and has no
release.

From `0.1.0`, every image runs as `sead`, uid and gid `10001`, where older
builds ran some services as uid `100` and others as root. A node set up with
older images changes its files' owner when it switches to `0.1.0`: see the
README, "Moving a node to the v0.1.0 user".
