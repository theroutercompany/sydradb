FROM debian:bookworm-slim AS zig

ARG ZIG_VERSION=0.15.1
ARG TARGETARCH

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
    amd64) zig_arch='x86_64' ;; \
    arm64) zig_arch='aarch64' ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac \
  && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
  && tar -xf /tmp/zig.tar.xz -C /opt \
  && mv "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig \
  && rm /tmp/zig.tar.xz

FROM node:22-bookworm AS build

WORKDIR /src

COPY --from=zig /opt/zig /opt/zig
ENV PATH="/opt/zig:${PATH}"

COPY . .

WORKDIR /src/demos/showcase
RUN npm ci

WORKDIR /src
RUN zig build -Doptimize=ReleaseSafe

WORKDIR /src/demos/showcase
RUN npm run build
RUN npm prune --omit=dev

FROM node:22-bookworm-slim AS runtime

ENV NODE_ENV=production
ENV SHOWCASE_HOST=0.0.0.0
ENV SHOWCASE_RUNNER_PORT=4177
ENV SYDRADB_BIN=/app/bin/sydradb

WORKDIR /app

COPY --from=build /src/zig-out/bin/sydradb /app/bin/sydradb
COPY --from=build /src/demos/showcase/package.json /app/demos/showcase/package.json
COPY --from=build /src/demos/showcase/node_modules /app/demos/showcase/node_modules
COPY --from=build /src/demos/showcase/dist/runner /app/demos/showcase/dist/runner
COPY --from=build /src/demos/showcase/ui/dist /app/demos/showcase/dist/runner/ui/dist
COPY --from=build /src/demos/showcase/scenarios /app/demos/showcase/dist/runner/scenarios
COPY --from=build /src/demos/showcase/fixtures /app/demos/showcase/dist/runner/fixtures

WORKDIR /app/demos/showcase

EXPOSE 4177

CMD ["node", "dist/runner/runner/server.js"]
