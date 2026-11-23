# syntax=docker/dockerfile:1
# Content of the aws-developer mixin: AWS CLI v2 and Node.js, staged under
# /out and copied onto scratch. The result is an overlay that lands on top
# of an agent workload (claude, codex, ...), so nothing from the build
# stage's base image travels with it.

# `aws help` renders its pages through groff or mandoc, and the agent
# workloads ship neither. An apt package cannot travel in an overlay, but
# a statically linked mandoc is a single file that runs on any base.
# Built on Alpine because a static glibc build of mandoc segfaults.
FROM alpine:3 AS mandoc
ARG MANDOC_VERSION=1.14.6
ARG MANDOC_SHA256=8bf0d570f01e70a6e124884088870cbed7537f36328d512909eb10cd53179d9c
RUN apk add --no-cache build-base curl zlib-dev zlib-static
RUN set -eux; \
    curl -fsSL "https://mandoc.bsd.lv/snapshots/mandoc-${MANDOC_VERSION}.tar.gz" -o /tmp/mandoc.tar.gz; \
    echo "${MANDOC_SHA256}  /tmp/mandoc.tar.gz" | sha256sum -c -; \
    mkdir /tmp/mandoc; \
    tar -xzf /tmp/mandoc.tar.gz -C /tmp/mandoc --strip-components=1; \
    cd /tmp/mandoc; \
    echo 'LDFLAGS="-static"' > configure.local; \
    ./configure; \
    make mandoc; \
    if readelf -l ./mandoc | grep -q INTERP; then echo "mandoc is not statically linked" >&2; exit 1; fi; \
    echo '.TH T 1' | ./mandoc -T utf8 > /dev/null

FROM debian:trixie-slim AS build
ARG TARGETARCH
ARG AWS_CLI_VERSION
ARG NODE_VERSION
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2. The installer writes absolute symlinks, so it runs against
# the paths the overlay will occupy and the tree is copied afterwards; the
# launchers in /usr/local/bin are recreated as relative links.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWS_CLI_VERSION}.zip" -o /tmp/awscli.zip; \
    unzip -q /tmp/awscli.zip -d /tmp; \
    /tmp/aws/install --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin; \
    aws --version | grep -q "^aws-cli/${AWS_CLI_VERSION} "; \
    mkdir -p /out/usr/local/bin; \
    cp -a /usr/local/aws-cli /out/usr/local/aws-cli; \
    ln -s ../aws-cli/v2/current/bin/aws /out/usr/local/bin/aws; \
    ln -s ../aws-cli/v2/current/bin/aws_completer /out/usr/local/bin/aws_completer; \
    rm -rf /tmp/aws /tmp/awscli.zip
COPY --from=mandoc /tmp/mandoc/mandoc /out/usr/local/bin/mandoc

# Node.js from the official release tarball, checked against the release's
# SHASUMS256.txt. It lives in /opt/node rather than /usr/local because the
# agent workloads hand /usr/local/share to the agent user (npm's global
# prefix is below it) and an overlay's directory entries replace the base's.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    file="node-v${NODE_VERSION}-linux-${arch}.tar.xz"; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${file}"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " ${file}\$" | sha256sum -c -; \
    mkdir -p /out/opt/node; \
    tar -xJf "${file}" -C /out/opt/node --strip-components=1 --no-same-owner; \
    /out/opt/node/bin/node --version | grep -qx "v${NODE_VERSION}"; \
    for bin in /out/opt/node/bin/*; do \
      ln -s "../../../opt/node/bin/$(basename "$bin")" "/out/usr/local/bin/$(basename "$bin")"; \
    done; \
    rm -f "${file}"

# Release archives keep the uid of the machine that packed them.
RUN chown -R 0:0 /out

FROM scratch
COPY --from=build /out /

# AWS profiles and credentials come from the sandbox's sbx-aws-developer
# broker on the host. Its export directory is mounted read-only at
# /mnt/aws-credentials: aws-config defines the profiles, and each of them
# calls this helper to read its credentials from credentials.json.
COPY --chmod=755 files/aws-credential-process /usr/local/bin/aws-credential-process
ENV AWS_CONFIG_FILE=/mnt/aws-credentials/aws-config

# The AWS CLI pages its output through less on a terminal by default.
ENV AWS_PAGER=""
