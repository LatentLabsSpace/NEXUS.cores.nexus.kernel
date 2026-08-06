# syntax=docker/dockerfile:1.7
#
# Thin {{SERVICE_PREFIX}} layer on the kernel hermes image.
#
# The base image is built by the `kernel-hermes` compose service from the
# pinned submodule at cores/nexus/kernel and handed to this build as the
# `kernel-hermes-image` named context (compose.yml additional_contexts).
# Everything heavy — mise, Claude Code, the hermes-agent venv, entrypoints,
# the universal firewall.d/_required/ and _optional/ allowlists — lives in
# that base.
#
# The stage is named `hermes` because the extended kernel compose service
# carries `build.target: hermes` through to this Dockerfile.
FROM kernel-hermes-image AS hermes

# Merge this repo's firewall drop-ins alongside the kernel's universal sets
# already present in the base image. Project drop-ins are warn-and-skip: a
# domain that fails DNS logs a warning instead of blocking the boot.
COPY .devcontainer/firewall.d/ /usr/local/bin/firewall.d/

# ─── Project-specific layers go below ────────────────────────────────────────
# Add language runtimes, engine binaries, system libraries, or an entrypoint
# override here. Pin external downloads via a _.jsonld file (the kernel's
# version-pin convention) rather than inlining version numbers.
