# ── Base image ────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      jq \
      time \
      procps && \
    rm -rf /var/lib/apt/lists/*

# Default results directory (bind-mounted from the host at runtime).
ENV RESULT_DIR=/results
RUN mkdir -p /results

# ── wrk – HTTP benchmarking ───────────────────────────────────────────────────
FROM base AS wrk

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends wrk && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoints/wrk-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ── iperf3 – network throughput ───────────────────────────────────────────────
FROM base AS iperf3

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends iperf3 && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoints/iperf3-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ── stress-ng ────────────────────────────────────────────────────────────────
FROM base AS stress-ng

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends stress-ng && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoints/stress-ng-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ── sysbench ─────────────────────────────────────────────────────────────────
FROM base AS sysbench

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends sysbench && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoints/sysbench-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
