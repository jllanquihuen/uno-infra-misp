ARG DOCKER_HUB_PROXY=""
ARG MISP_UID=1001
ARG MISP_GID=1001


FROM "${DOCKER_HUB_PROXY}python:3.14-slim-trixie" AS python-build
ENV DEBIAN_FRONTEND=noninteractive
ARG MODULES_TAG
ARG MODULES_COMMIT
ARG MODULES_FLAVOR

# Make apt resilient to transient network failures (corporate proxies / captive portals).
RUN printf 'Acquire::Retries "5";\nAcquire::Retries::Delay "10";\n' > /etc/apt/apt.conf.d/80-retries

# Corporate CA injection (TLS-inspecting networks). Pass base64-encoded PEM via CUSTOM_CA_B64.
# No-op when empty, so builds without a CA are unaffected.
ARG CUSTOM_CA_B64=""
RUN <<-EOF
        if [ -n "${CUSTOM_CA_B64}" ]; then
            echo "... installing corporate root CA"
            echo "${CUSTOM_CA_B64}" | base64 -d > /usr/local/share/ca-certificates/corp-root-ca.crt
            update-ca-certificates
            ln -sf /etc/ssl/certs/ca-certificates.crt /usr/lib/ssl/cert.pem
        fi
EOF

RUN <<-EOF
        apt-get update
        if [ "${MODULES_FLAVOR}" = "slim" ]; then
            apt-get install -y --no-install-recommends \
                ca-certificates \
                git
        else
            apt-get install -y --no-install-recommends \
                ca-certificates \
                git \
                build-essential \
                libfuzzy-dev \
                libpoppler-cpp-dev
        fi
        apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*
EOF

RUN mkdir /wheels

RUN <<-EOF
        if [ ! -z ${MODULES_COMMIT} ]; then
            git clone https://github.com/MISP/misp-modules.git /srv/misp-modules && cd /srv/misp-modules && git checkout ${MODULES_COMMIT}
        else
            git clone --branch ${MODULES_TAG} --depth 1 https://github.com/MISP/misp-modules.git /srv/misp-modules
        fi
EOF

WORKDIR /srv/misp-modules
RUN pip install poetry poetry-plugin-bundle poetry-plugin-export
RUN <<-EOF
        if [ "${MODULES_FLAVOR}" = "slim" ]; then
            poetry export --without-hashes -f requirements.txt -o requirements.txt
        else
            poetry export -E all --without-hashes -f requirements.txt -o requirements.txt
        fi
EOF
RUN pip wheel -r requirements.txt --no-cache-dir -w /wheels/
RUN poetry build --output /wheels/

WORKDIR /srv/
RUN rm -rf /srv/misp-modules


FROM "${DOCKER_HUB_PROXY}python:3.14-slim-trixie"
ENV DEBIAN_FRONTEND=noninteractive
ARG MODULES_FLAVOR
ARG MISP_UID
ARG MISP_GID

# Make apt resilient to transient network failures (corporate proxies / captive portals).
RUN printf 'Acquire::Retries "5";\nAcquire::Retries::Delay "10";\n' > /etc/apt/apt.conf.d/80-retries

# Corporate CA injection for runtime HTTPS calls (enrichment services, feeds).
# Pass base64-encoded PEM via CUSTOM_CA_B64. No-op when empty.
ARG CUSTOM_CA_B64=""
RUN <<-EOF
        if [ -n "${CUSTOM_CA_B64}" ]; then
            echo "... installing corporate root CA"
            echo "${CUSTOM_CA_B64}" | base64 -d > /usr/local/share/ca-certificates/corp-root-ca.crt
            update-ca-certificates
            ln -sf /etc/ssl/certs/ca-certificates.crt /usr/lib/ssl/cert.pem
        fi
EOF

RUN <<-EOF
        apt-get update
        if [ "${MODULES_FLAVOR}" = "slim" ]; then
            :
        else
            apt-get install -y --no-install-recommends \
                libgl1 \
                libfuzzy2 \
                libpoppler-cpp2 \
                libzbar0 \
                tesseract-ocr
        fi
        apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*
EOF

RUN groupadd -g "${MISP_GID}" misp && \
    useradd  -u "${MISP_UID}" -g "${MISP_GID}" -m -d /home/misp -s /usr/sbin/nologin misp

COPY --from=python-build /wheels /wheels
RUN pip install --no-cache-dir /wheels/*.whl && rm -rf /wheels
RUN bash -c 'mkdir -p /custom/{action_mod,expansion,export_mod,import_mod} && chown -R misp:misp /custom'

USER misp

ENTRYPOINT [ "/usr/local/bin/misp-modules", "-l", "0.0.0.0", "-c", "/custom/"]
