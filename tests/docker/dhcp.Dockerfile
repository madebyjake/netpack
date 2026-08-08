# A real DHCP server, so dhcpprobe can be checked against one rather than
# against a fixture. Two of these on one network reproduce the rogue-server
# case the tool exists to find.
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends dnsmasq \
  && rm -rf /var/lib/apt/lists/*
