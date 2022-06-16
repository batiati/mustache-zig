## Zig + git + codecov + kcov
FROM ubuntu:20.04
ARG ZIG_JSON=https://ziglang.org/download/index.json
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
		jq \
	&& \
	export ZIG_URL=$(curl "$ZIG_JSON" | jq '."master"."x86_64-linux"."tarball"' --raw-output) && \
	curl "$ZIG_URL" -o zig.tar.xz  && \
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
    zig build test -Dtest-coverage -Dcomptime-tests=false && \
    codecov