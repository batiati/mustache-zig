## Kcov built for alpine
FROM ko1nksm/kcov-alpine AS Kcov

## Zig stable 0.9.1
FROM Kcov AS Zig
ARG ZIG_VERSION=0.9.1
ARG ZIG_URL=https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz
ARG ZIG_SHA256=be8da632c1d3273f766b69244d80669fe4f5e27798654681d77c992f17c237d7
ARG TARGET_DIR=/usr/local/bin/zig

WORKDIR /usr/src

RUN set -xe \
	&& apk add --no-cache --virtual .fetch-deps curl \
	    && curl -o zig.tar.xz "$ZIG_URL" ; \
	    if [ -n "$ZIG_SHA256" ]; then \
	    echo "$ZIG_SHA256 *zig.tar.xz" | sha256sum -c - ; \
	    fi ; \
	    apk del .fetch-deps \
	&& apk add --no-cache --virtual .extract-deps tar xz \
		&& mkdir -p "$TARGET_DIR" ; \
		if [[ ! -f "$TARGET_DIR/.extracted" ]]; then \
			tar -Jxf /usr/src/zig.tar.xz -C "$TARGET_DIR" --strip-components=1 ; \
			touch "$TARGET_DIR/.extracted" ; \
		fi \
		&& rm /usr/src/zig.tar.xz \
	    && apk del .extract-deps

ENV PATH "/usr/local/bin/zig:${PATH}"
WORKDIR /app

## Build dependencies
FROM Zig AS Build
ARG CODECOV=https://uploader.codecov.io/latest/linux/codecov

RUN set -xe \
	&& apk add git curl \
    && cd /usr/local/bin \
    && curl -Os "$CODECOV" \
    && chmod +x /usr/local/bin/codecov

## Build image
FROM Build
ARG REPO=https://github.com/batiati/mustache-zig.git
ARG CODECOV_TOKEN=''

USER root
RUN set -xe \
	&& git clone "$REPO" repo \
    && cd repo \
    && zig build test -Dtest-coverage \
    && codecov