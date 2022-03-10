## Zig + git + codecov + kcov
FROM ubuntu:20.04
ARG ZIG_VERSION=0.9.1
ARG ZIG_URL=https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz
ARG ZIG_SHA256=be8da632c1d3273f766b69244d80669fe4f5e27798654681d77c992f17c237d7
ARG CODECOV=https://uploader.codecov.io/latest/linux/codecov
ARG TARGET_DIR=/usr/local/bin/zig

WORKDIR /usr/src

RUN apt-get update && \
	apt-get install -y \
		curl \
		tar \
		xz-utils \
		git \
		kcov \
	&& \
	curl -o zig.tar.xz "$ZIG_URL" && \
	mkdir -p "$TARGET_DIR"  && \
	tar -Jxf zig.tar.xz -C "$TARGET_DIR" --strip-components=1 && \
	rm zig.tar.xz && \
	chmod +x "$TARGET_DIR"/zig \
	&& \
    cd /usr/local/bin && \
    curl -Os "$CODECOV" && \
    chmod +x /usr/local/bin/codecov \
	&& \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*	

ENV PATH "/usr/local/bin/zig:${PATH}"
ENV REPO=https://github.com/batiati/mustache-zig.git
ENV CODECOV_TOKEN=''

CMD git clone "$REPO" repo && \
    cd repo && \
    zig build test -Dtest-coverage && \
    codecov