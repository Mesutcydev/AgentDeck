FROM swift:6.0-jammy AS build
WORKDIR /src
COPY Packages/Shared Packages/Shared
COPY Relay Relay
RUN cd Relay && swift build -c release --product agentdeck-relay

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/Relay/.build/release/agentdeck-relay /usr/local/bin/agentdeck-relay
ENV PORT=8787
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/agentdeck-relay"]
