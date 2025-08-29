# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.2.4

ARG BUILDER_OS="ubuntu-noble-20250716"
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-${BUILDER_OS}"

FROM ghcr.io/by275/base:ubuntu AS prebuilt
FROM ghcr.io/by275/base:ubuntu24.04 AS base
FROM ${BUILDER_IMAGE} AS builder

ARG DEBIAN_FRONTEND="noninteractive"
ARG TARGETPLATFORM

RUN \
    echo "*** install build dependencies ***" && \
    apt-get update -y && \
    # System packages
    apt-get install -y \
        build-essential \
        git \
        curl && \
    # Node.js and Yarn
    curl -sL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g yarn && \
    # Hex and Rebar
    mix local.hex --force && \
    mix local.rebar --force

# prepare build dir
WORKDIR /app

# set build ENV
ENV MIX_ENV="prod"
ENV ERL_FLAGS="+JPperf true"

# install mix dependencies
COPY src/mix.exs src/mix.lock ./
RUN \
    mix deps.get --only $MIX_ENV && \
    mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY src/config/config.exs src/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY src/priv priv
COPY src/lib lib
COPY src/assets assets

# Compile assets
RUN \
    yarn --cwd assets install && \
    mix assets.deploy && \
    mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY src/config/runtime.exs config/

COPY src/rel rel
RUN mix release

FROM base AS ytdlp

RUN \
    echo "*** install yt-dlp/FFmpeg-Builds ***" && \
    apt-get update && \
    apt-get install -yq --no-install-recommends \
        xz-utils \
    && \
    export FFMPEG_FILE=$(case ${TARGETPLATFORM:-linux/amd64} in \
    "linux/amd64")   echo "ffmpeg-n7.1-latest-linux64-gpl-7.1.tar.xz"    ;; \
    "linux/arm64")   echo "ffmpeg-n7.1-latest-linuxarm64-gpl-7.1.tar.xz" ;; \
    *)               echo ""        ;; esac) && \
    curl -LJ "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/${FFMPEG_FILE}" -o /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz --strip-components=2 --no-anchored -C /usr/local/bin/ "ffmpeg" "ffprobe"

RUN \
    echo "*** install yt-dlp ***" && \
    curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp

FROM base AS collector

ARG DEBIAN_FRONTEND="noninteractive"

# add s6 overlay
COPY --from=prebuilt /s6/ /bar/
ADD https://raw.githubusercontent.com/by275/docker-base/main/_/etc/cont-init.d/adduser /bar/etc/cont-init.d/10-adduser

# add ffmpeg ffprobe yt-dlp
COPY --from=ytdlp --chown=0:0 /usr/local/bin/ffmpeg /bar/usr/local/bin/
COPY --from=ytdlp --chown=0:0 /usr/local/bin/ffprobe /bar/usr/local/bin/
COPY --from=ytdlp /usr/local/bin/yt-dlp /bar/app/bin/

# Only copy the final release from the build stage
COPY --from=builder /app/_build/prod/rel/pinchflat /bar/app/

RUN \
    echo "**** directories ****" && \
    mkdir -p \
        /bar/config \
        /bar/downloads \
        /bar/etc/yt-dlp/plugins \
        /bar/etc/elixir_tzdata_data

# add local files
COPY root/ /bar/

RUN \
    echo "**** permissions ****" && \
    chmod a+x \
        /bar/app/bin/* \
        /bar/usr/local/bin/* \
        /bar/etc/cont-init.d/* \
        /bar/etc/s6-overlay/s6-rc.d/*/run

RUN \
    echo "**** s6: resolve dependencies ****" && \
    for dir in /bar/etc/s6-overlay/s6-rc.d/*; do mkdir -p "$dir/dependencies.d"; done && \
    for dir in /bar/etc/s6-overlay/s6-rc.d/*; do touch "$dir/dependencies.d/legacy-cont-init"; done && \
    echo "**** s6: create a new bundled service ****" && \
    mkdir -p /tmp/app/contents.d && \
    for dir in /bar/etc/s6-overlay/s6-rc.d/*; do touch "/tmp/app/contents.d/$(basename "$dir")"; done && \
    echo "bundle" > /tmp/app/type && \
    mv /tmp/app /bar/etc/s6-overlay/s6-rc.d/app && \
    echo "**** s6: deploy services ****" && \
    rm /bar/package/admin/s6-overlay/etc/s6-rc/sources/top/contents.d/legacy-services && \
    touch /bar/package/admin/s6-overlay/etc/s6-rc/sources/top/contents.d/app

FROM base
LABEL maintainer="by275"
LABEL org.opencontainers.image.source=https://github.com/by275/docker-pinchflat

ARG DEBIAN_FRONTEND="noninteractive"

# install packages
RUN \
    echo "**** install runtime packages ****" && \
    apt-get update && \
    apt-get install -yq --no-install-recommends \
        jq \
        libncurses6 \
        libstdc++6 \
        pipx \
        python3 \
        python3-mutagen \
        zip \
        && \
    # Apprise
    export PIPX_HOME=/opt/pipx && \
    export PIPX_BIN_DIR=/usr/local/bin && \
    pipx install apprise && \
    echo "**** cleanup ****" && \
    apt-get clean autoclean && \
    apt-get autoremove -y && \
    rm -rf \
        /root/.cache \
        /tmp/* \
        /var/tmp/* \
        /var/cache/* \
        /var/lib/apt/lists/*

# add build artifacts
COPY --from=collector /bar/ /

# environment settings
ENV \
    PATH="/app/bin:$PATH" \
    MIX_ENV=prod \
    PORT=8945 \
    TZ=Asia/Seoul \
    RUN_CONTEXT=selfhosted

EXPOSE ${PORT}

WORKDIR /app
VOLUME /app

HEALTHCHECK --interval=30s --start-period=15s \
    CMD curl --fail http://localhost:${PORT}/healthcheck || exit 1

ENTRYPOINT ["/init"]
