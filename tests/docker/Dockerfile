# Debian on arm64 matches the field target closely enough to run the tools that
# macOS cannot: ip, ethtool, iw, arp-scan, tcpdump, iperf3, nft, lldpcli.
#
# de_DE.UTF-8 is generated on purpose: it is the locale that turned 1.5% loss
# into "1,5" and had classify_loss_set report a lossy path as clean.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-scapy iproute2 iputils-ping dnsutils \
      ethtool iw mtr-tiny tcpdump arp-scan lldpd iperf3 nftables \
      iputils-tracepath curl \
      bash coreutils make procps \
      shellcheck bats python3-pytest locales \
  && sed -i 's/^# de_DE.UTF-8/de_DE.UTF-8/' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /netpack
