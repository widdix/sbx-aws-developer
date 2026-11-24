# syntax=docker/dockerfile:1
# The sbx-aws-developer broker: runs on the host's Docker, one container
# per sandbox. It reads the SSO session from the mounted ~/.aws and exports
# temporary credentials for the profiles given as arguments to /data, the
# directory the sandbox mounts. Published as widdix/sbx-aws-developer.
FROM debian:trixie-slim
LABEL org.opencontainers.image.source=https://github.com/widdix/sbx-aws-developer
LABEL org.opencontainers.image.description="Hands temporary AWS credentials of selected profiles to a Docker Sandbox"
LABEL org.opencontainers.image.licenses=Apache-2.0
ARG TARGETARCH
ARG AWS_CLI_VERSION=2.42.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq unzip \
 && rm -rf /var/lib/apt/lists/*

# TARGETARCH is empty with the legacy builder, which Docker Engine uses
# without the buildx plugin; the architecture of the base image is the same.
RUN set -eux; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWS_CLI_VERSION}.zip" -o /tmp/awscli.zip; \
    unzip -q /tmp/awscli.zip -d /tmp; \
    /tmp/aws/install; \
    aws --version | grep -q "^aws-cli/${AWS_CLI_VERSION} "; \
    rm -rf /tmp/aws /tmp/awscli.zip

# No COPY --chmod: the legacy builder does not support it.
COPY sbx-aws-developer-broker /usr/local/bin/sbx-aws-developer-broker
RUN chmod 755 /usr/local/bin/sbx-aws-developer-broker

# The container runs as the host user, so files written to the mounted
# ~/.aws and export directory belong to that user. HOME points to the
# mount target of ~/.aws.
ENV HOME=/home/sbx-aws-developer
ENV AWS_PAGER=""
RUN mkdir -p /home/sbx-aws-developer /data && chmod 777 /home/sbx-aws-developer /data
WORKDIR /data

ENTRYPOINT ["sbx-aws-developer-broker"]
