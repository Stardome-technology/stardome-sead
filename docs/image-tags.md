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
| `latest` | the newest build of `main` | on every push to `main` | only with its digest, until the image's first release |
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

A production node references each image by a tag and the digest of the
multi-arch index that tag names:

- until the image's first release: `<image>:latest@sha256:<index digest>`;
- from its first release on: `<image>:X.Y.Z@sha256:<index digest>`.

Docker pulls by the digest, so a node runs the same build until the digest
changes. The tag stays in the reference so readers and update tools can tell
which tag the digest was read from.

Neither of these is a production pin:

- `latest` alone, since it moves on every push to `main`;
- a per-arch tag, since it moves with every build of its tag and covers one
  architecture only.

Read an index digest with:

```bash
docker buildx imagetools inspect ghcr.io/stardome-technology/stardome-sead/sead-core:latest
```

and take the `Digest:` line under `Name:`, the digest of the index, not one
of the per-platform digests listed under `Manifests:`.

The interim `latest@sha256:` form ends image by image: once ghcr.io lists an
`X.Y.Z` tag for an image, nodes switch that image's reference to
`X.Y.Z@sha256:<index digest>`.

## Where the images stand

No image has a release yet: every image on ghcr.io carries only `latest`, and
the images CI builds also carry `latest-amd64` and `latest-arm64`.

Stardome's CI builds sead-core, edge-service, source-data-service and the
gateway. pin-service, gossip-node and the tool images are still built and
pushed by hand, and only as `latest`; the source repository's CI is being
extended to build them. Until it is, those images get no `X.Y.Z` tag, and
nodes pin them as `latest@sha256:<index digest>`.
