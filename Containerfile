# Stage 1: Build
FROM swift:6.2 AS builder
WORKDIR /app
COPY Package.swift ./
RUN swift package resolve
COPY Sources/ ./Sources/
COPY Tests/ ./Tests/
RUN swift build -c release

# Stage 2: Runtime (swift base includes all required shared libraries)
FROM swift:6.2-slim
COPY --from=builder /app/.build/release/App /usr/local/bin/anthopric-proxy
ENTRYPOINT ["anthopric-proxy"]
