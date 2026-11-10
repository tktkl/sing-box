ARG BASE=mirror.gcr.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
FROM ${BASE}
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive SB_CORE=/usr/local/bin/sb-core
COPY .cache/cacert.pem /etc/ssl/certs/ca-certificates.crt
RUN find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i -E 's#http://(ports.ubuntu.com|archive.ubuntu.com|security.ubuntu.com|deb.debian.org|security.debian.org)#https://\1#g' {} + && \
    apt-get -o Acquire::Retries=3 -o Acquire::https::Timeout=30 update && \
    apt-get -o Acquire::Retries=3 -o Acquire::https::Timeout=30 install -y --no-install-recommends \
      bash jq curl ca-certificates openssl iproute2 util-linux procps coreutils shellcheck tar gzip && \
    rm -rf /var/lib/apt/lists/*
COPY .cache/core-linux-${TARGETARCH}.tar.gz /tmp/core.tar.gz
COPY .cache/geoip-cn.srs /opt/test-assets/geoip-cn.srs
COPY dependencies.lock.json /opt/test-assets/dependencies.lock.json
RUN expected=$(jq -r --arg a "sing-box-1.14.4-linux-${TARGETARCH}.tar.gz" '.assets[$a].sha256' /opt/test-assets/dependencies.lock.json) && \
    printf '%s  /tmp/core.tar.gz\n' "$expected" | sha256sum -c - && \
    tar -xzf /tmp/core.tar.gz -C /tmp && install -m755 /tmp/sing-box-*/sing-box /usr/local/bin/sb-core && rm -rf /tmp/*
WORKDIR /workspace
CMD ["bash", "tests/unit.sh"]
