ARG BASE=mirror.gcr.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
FROM ${BASE}
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
COPY .cache/cacert.pem /etc/ssl/certs/ca-certificates.crt
RUN sed -i 's|http://ports.ubuntu.com|https://ports.ubuntu.com|g;s|http://archive.ubuntu.com|https://archive.ubuntu.com|g;s|http://security.ubuntu.com|https://security.ubuntu.com|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
RUN apt-get -o Acquire::Retries=3 -o Acquire::https::Timeout=30 -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt -o APT::Update::Error-Mode=any update && \
    apt-get -o Acquire::Retries=3 -o Acquire::https::Timeout=30 -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt install -y \
      bash jq curl ca-certificates openssl iproute2 util-linux procps coreutils \
      python3 make gcc libpcre2-dev zlib1g-dev libssl-dev shellcheck socat \
      systemd systemd-sysv dbus certbot python3-certbot-dns-cloudflare qrencode git xz-utils && \
    rm -rf /var/lib/apt/lists/*
COPY .cache/core-linux-${TARGETARCH}.tar.gz /tmp/core.tar.gz
COPY .cache/nginx-1.30.6.tar.gz /tmp/nginx.tar.gz
COPY .cache/geoip-cn.srs /opt/test-assets/geoip-cn.srs
COPY dependencies.lock.json /opt/test-assets/dependencies.lock.json
RUN expected=$(jq -r --arg a "sing-box-1.14.4-linux-${TARGETARCH}.tar.gz" '.assets[$a].sha256' /opt/test-assets/dependencies.lock.json) && \
    printf '%s  /tmp/core.tar.gz\n' "$expected" | sha256sum -c - && \
    expected=$(jq -r '.nginx.sha256' /opt/test-assets/dependencies.lock.json) && \
    printf '%s  /tmp/nginx.tar.gz\n' "$expected" | sha256sum -c - && \
    tar -xzf /tmp/core.tar.gz -C /tmp && install -m755 /tmp/sing-box-*/sing-box /usr/local/bin/sb-core && \
    tar -xzf /tmp/nginx.tar.gz -C /tmp && cd /tmp/nginx-1.30.6 && \
    ./configure --prefix=/opt/nginx --sbin-path=/usr/local/sbin/nginx --with-http_ssl_module --with-http_v2_module --with-stream --with-stream_ssl_module && \
    make -j2 && make install && rm -rf /tmp/*
WORKDIR /workspace
ENV SB_CORE=/usr/local/bin/sb-core
CMD ["bash", "tests/unit.sh"]
