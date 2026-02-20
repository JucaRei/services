# Unbound DNS with Redis Cache Backend

This is a production-ready DNS server setup using Unbound with Redis as a persistent cache backend, specifically optimized for low-power devices like the NanoPi R3S. The configuration emphasizes security, performance, and persistence, with DNSSEC validation enabled and caching offloaded to Redis for efficiency across restarts.

## Prerequisites

Before setting up, ensure the following:

- **Hardware**: NanoPi R3S or similar ARM-based device with at least 1GB RAM and sufficient storage (SD card or eMMC).
- **OS**: Debian Trixie (or similar Linux distribution) installed on the host.
- **Docker**: Installed and running. Install if needed:
  ```
  sudo apt update
  sudo apt install docker.io docker-compose
  sudo usermod -aG docker $USER  # Log out and back in after this
  ```
- **Directories**: Create the project structure:
  ```
  mkdir -p ~/workspace/services/unbound/{cache/redis,cache/cachedb.d,data/unbound/{conf.d,iana.d,zones.d,log.d},data/redis}
  ```
- **Permissions**: Set initial ownership for volumes (run from project dir):
  ```
  sudo chown -R 999:999 ./cache/redis ./data/unbound ./cache/cachedb.d
  sudo chmod -R 770 ./cache/redis ./data/unbound/log.d
  ```
- **Root Hints File**: Download the latest root hints to `./data/unbound/iana.d/root.hints`:
  ```
  curl -o ./data/unbound/iana.d/root.hints https://www.internic.net/domain/named.root
  ```
- **Root Key**: Initialize the DNSSEC trust anchor (will be auto-updated later):
  ```
  touch ./data/unbound/iana.d/root.key
  chmod 644 ./data/unbound/iana.d/root.key
  chown 999:999 ./data/unbound/iana.d/root.key
  ```
- **Custom Config Files**: Create all necessary config files as detailed in the Configuration Details section below.

## Architecture Overview

The setup consists of three Docker containers working together:

### 1. unbound-db-socket Container
- **Purpose**: Creates shared volumes and manages socket permissions for Redis.
- **Image**: `busybox:latest` (lightweight utility container).
- **Key Functions**:
  - Creates `/run/redis` directory with proper permissions (770, owned by 999:999).
  - Shares volumes with other containers via `volumes_from`.
  - Mounts `./cache/cachedb.d` for persistent Redis cache storage.

### 2. unbound-db (Redis) Container
- **Purpose**: Redis cache backend for Unbound's persistent caching.
- **Image**: `redis:alpine` (lightweight Redis).
- **Key Features**:
  - Health check using UNIX socket ping every 5 seconds.
  - Persistent storage via `./cache/redis` volume.
  - Custom Redis configuration from `./data/redis/redis.conf`.
  - Optimized for low memory usage (64MB max) with LRU eviction.

### 3. unbound (Main DNS Server) Container
- **Purpose**: Primary Unbound DNS server with recursive resolution and caching.
- **Image**: `madnuttah/unbound:latest` (hardened Unbound build).
- **Key Features**:
  - Depends on Redis being healthy before starting.
  - Binds to port 53 (both TCP and UDP) on the host.
  - Uses `NET_BIND_SERVICE` capability for privileged port binding.
  - Comprehensive health checking every 60 seconds with extended checks.
  - Extended statistics enabled for monitoring.
  - Runs as UID/GID 999:999 to match Redis for socket access.

## Docker Compose Setup

Save this as `docker-compose.yaml` in your project directory (e.g., `~/workspace/services/unbound/`):

```yaml
# Docker Compose file for Unbound DNS with Redis cache backend - NanoPi R3S

services:
  unbound-db-socket:
    container_name: unbound-db-socket
    image: busybox:latest
    volumes:
      - unbound-db-sock:/run/redis
      - ./cache/cachedb.d:/usr/local/unbound/cachedb.d/
    command: /bin/sh -c "mkdir -p /run/redis && chown 999:999 /run/redis && chmod 770 /run/redis && tail -f /dev/null"
    restart: unless-stopped

  unbound-db:
    container_name: unbound-db
    image: redis:alpine
    hostname: unbound-db
    depends_on:
      - unbound-db-socket
    volumes_from:
      - unbound-db-socket
    volumes:
      - ./cache/redis:/data
      - ./data/redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
    command: redis-server /usr/local/etc/redis/redis.conf
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -s /run/redis/redis.sock ping | grep -q PONG || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 5

  unbound:
    container_name: unbound
    image: madnuttah/unbound:latest
    depends_on:
      unbound-db:
        condition: service_healthy
    volumes_from:
      - unbound-db-socket
    volumes:
      - ./data/unbound/unbound.conf:/usr/local/unbound/unbound.conf:rw
      - ./data/unbound/conf.d:/usr/local/unbound/conf.d/:rw
      - ./data/unbound/log.d:/usr/local/unbound/log.d/:rw
      - ./data/unbound/zones.d:/usr/local/unbound/zones.d/:rw
      - ./data/unbound/healthcheck.sh:/usr/local/unbound/sbin/healthcheck.sh:ro
      - ./data/unbound/iana.d/root.hints:/usr/local/unbound/iana.d/root.hints:ro
      - ./data/unbound/iana.d/root.key:/usr/local/unbound/iana.d/root.key:rw
      - ./cache/cachedb.d:/usr/local/unbound/cachedb.d/
      - unbound-pid:/var/run  # Volume for PID file
      - ./data/unbound/control-keys:/usr/local/unbound/control-keys:ro  # For remote control (optional)
    ports:
      - "53:53/tcp"
      - "53:53/udp"
    cap_add:
      - NET_BIND_SERVICE
    environment:
      TZ: America/Sao_Paulo
      DISABLE_SET_PERMS: "true"
      UNBOUND_UID: 999
      UNBOUND_GID: 999
      HEALTHCHECK_PORT: 53
      EXTENDED_HEALTHCHECK: true
      ENABLE_STATS: true
    healthcheck:
      test: ["CMD-SHELL", "/usr/local/unbound/sbin/healthcheck.sh"]
      interval: 60s
      timeout: 30s
      retries: 5
      start_period: 15s
    restart: unless-stopped

volumes:
  unbound-db-sock:
  unbound-pid:
```

Start the stack:
```
docker compose up -d
```

Verify all containers are running:
```
docker compose ps
```

## Configuration Details

Create the following files in `./data/unbound/` and subdirectories as specified.

### Unbound Main Configuration (`data/unbound/unbound.conf`)

```
server:
    module-config: "validator cachedb iterator"  # DNSSEC + Redis cache + iterator
    directory: "/usr/local/unbound"
    chroot: ""
    do-daemonize: no
    pidfile: "/dev/null"
    root-hints: "/usr/local/unbound/iana.d/root.hints"

include-toplevel: "/usr/local/unbound/conf.d/*.conf"
include-toplevel: "/usr/local/unbound/zones.d/*.conf"

cachedb:
    backend: "redis"
    redis-server-path: "/run/redis/redis.sock"
    redis-timeout: 50
    redis-expire-records: yes
```

### Security Configuration (`data/unbound/conf.d/security.conf`)

```
server:	
    do-not-query-localhost: no
	
    unblock-lan-zones: no
    insecure-lan-zones: yes
	
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 10.10.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10
    private-address: ::ffff:0:0/96
	
    serve-expired-ttl: 86400
    serve-expired-reply-ttl: 30
    ratelimit: 200
    infra-cache-numhosts: 1000
    ip-ratelimit-size: 4m
    hide-identity: yes
    tls-upstream: no
    identity: "server"
    hide-version: yes
    version: ""    
    aggressive-nsec: yes
    qname-minimisation: yes
    qname-minimisation-strict: no	
    disable-dnssec-lame-check: no
    hide-trustanchor: yes
    harden-algo-downgrade: yes
    harden-below-nxdomain: yes
    harden-dnssec-stripped: yes
    harden-glue: yes
    harden-large-queries: yes
    harden-referral-path: yes
    harden-short-bufsize: yes
    minimal-responses: yes
    deny-any: yes
    use-caps-for-id: yes
    val-clean-additional: yes
    unwanted-reply-threshold: 10000
    val-max-restart: 5
    root-key-sentinel: yes
    zonemd-permissive-mode: no
    val-permissive-mode: no
```

### Interfaces Configuration (`data/unbound/conf.d/interfaces.conf`)

```
server:
    interface: 0.0.0.0@53
    outgoing-interface: 0.0.0.0
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: no
    udp-connect: yes
    prefer-ip4: yes
    prefer-ip6: no
```

### Access Control Configuration (`data/unbound/conf.d/access-control.conf`)

```
server:
    access-control: 127.0.0.0/8 allow
    access-control: 10.0.0.0/8 allow
    access-control: 10.10.10.0/24 allow
    access-control: 172.16.0.0/12 allow
    access-control: 192.168.0.0/16 allow
```

### Logging Configuration (`data/unbound/conf.d/logging.conf`)

```
server:	
  use-syslog: no
  log-time-ascii: yes
  logfile: "/usr/local/unbound/log.d/unbound.log"
  log-local-actions: yes
  log-queries: yes
  log-replies: yes
  log-servfail: yes
  val-log-level: 1
  verbosity: 2
```

### Remote Control Configuration (`data/unbound/conf.d/remote-control.conf`)

```
remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-port: 8953
    server-key-file: "/usr/local/unbound/control-keys/unbound_server.key"
    server-cert-file: "/usr/local/unbound/control-keys/unbound_server.pem"
    control-key-file: "/usr/local/unbound/control-keys/unbound_control.key"
    control-cert-file: "/usr/local/unbound/control-keys/unbound_control.pem"
```

### Statistics Configuration (`data/unbound/conf.d/statistics.conf`)

```
server:
    extended-statistics: yes
    statistics-interval: 60
    statistics-cumulative: no
```

### Trust Anchor Configuration (`data/unbound/conf.d/trust-anchor.conf`)

```
server:	
  auto-trust-anchor-file: "/usr/local/unbound/iana.d/root.key"
  root-hints: "/usr/local/unbound/iana.d/root.hints"
  trust-anchor-signaling: yes
```

### Performance Configuration (`data/unbound/conf.d/performance.conf`)

```
server:
    num-threads: 1
    so-reuseport: yes
    outgoing-range: 128
    num-queries-per-thread: 256

    msg-cache-size: 0
    rrset-cache-size: 0
    neg-cache-size: 0

    msg-cache-slabs: 1
    rrset-cache-slabs: 1
    infra-cache-slabs: 1
    key-cache-slabs: 1

    cache-min-ttl: 600
    cache-max-ttl: 7200
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes

    edns-buffer-size: 1232
    max-udp-size: 4096
    msg-buffer-size: 8192
```

### Redis Configuration (`data/redis/redis.conf`)

```
# Redis configuration for Unbound cachedb
# UNIX socket only, no persistence, low memory - NanoPi R3S

# Network / Listening
# Disable TCP listening completely
port 0

# Fallback bind (ignored when port=0)
bind 127.0.0.1 -::1

# UNIX Socket - required for Unbound cachedb
unixsocket /run/redis/redis.sock
unixsocketperm 770

# Security
protected-mode yes
user default on nopass ~* &* +@all

# Persistence: completely disabled
# No RDB snapshots (no save directives)
# No AOF logging
appendonly no

# Paths
dir /data
dbfilename dump.rdb
appendfilename "appendonly.aof"
pidfile /data/redis.pid
logfile ""
loglevel notice

# Runtime
daemonize no
supervised no
databases 1

# Memory limits
maxmemory 64mb
maxmemory-policy allkeys-lru

# Timeouts
tcp-keepalive 60
timeout 300

# Low-memory optimizations for data structures
hash-max-ziplist-entries 256
hash-max-ziplist-value 32
list-max-ziplist-size -2
set-max-intset-entries 256
zset-max-ziplist-entries 64
zset-max-ziplist-value 32

# Disable lazyfree operations (saves CPU on low-power hardware)
lazyfree-lazy-eviction no
lazyfree-lazy-expire no
lazyfree-lazy-server-del no
```

### Healthcheck Script (`data/unbound/healthcheck.sh`)

```
#!/bin/sh

# Healthcheck script for Unbound

# Check if Unbound is running
pgrep unbound >/dev/null || exit 1

# Basic DNS test
drill @127.0.0.1 google.com >/dev/null || exit 1

# If extended healthcheck enabled, add more
if [ "$EXTENDED_HEALTHCHECK" = "true" ]; then
  # DNSSEC test
  drill @127.0.0.1 dnssec-failed.org +dnssec | grep "SERVFAIL" >/dev/null || exit 1
fi

exit 0
```

Make it executable:
```
chmod +x data/unbound/healthcheck.sh
```

### Remote Control Keys (Optional)

Generate keys on host:
```
sudo apt install unbound
cd ~/workspace/services/unbound
sudo unbound-control-setup
sudo mkdir -p data/unbound/control-keys
sudo mv unbound_* data/unbound/control-keys/
sudo chown -R 999:999 data/unbound/control-keys/
sudo chmod 600 data/unbound/control-keys/*.key
sudo chmod 644 data/unbound/control-keys/*.pem
```

## OpenWRT Configuration for Technitium DNS

This section documents the UCI commands used to configure OpenWRT to use Technitium DNS servers (10.10.10.25 and 10.10.10.26) instead of ISP DNS.

### 1. DNS Servers Configuration

Disable ISP DNS and set custom servers:
```
uci set network.wan.peerdns='0'
uci delete network.wan.dns
uci add_list network.wan.dns='10.10.10.25'
uci add_list network.wan.dns='10.10.10.26'
uci commit network
/etc/init.d/network restart
```

### 2. DHCP/DNS Configuration

Enable DNSSEC and rebind protection:
```
uci set dhcp.@dnsmasq[0].rebind_protection='1'
uci set dhcp.@dnsmasq[0].dnssec='1'
uci set dhcp.@dnsmasq[0].dnsseccheckunsigned='1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### 3. Firewall Configuration

Allow DNS traffic to Technitium servers:
```
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-DNS-Technitium-25'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_ip='10.10.10.25'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-DNS-Technitium-26'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_ip='10.10.10.26'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
/etc/init.d/firewall restart
```

### 4. Verification Commands

Test DNS resolution:
```
nslookup google.com 10.10.10.25
nslookup google.com 10.10.10.26
nslookup dnssec-failed.org 10.10.10.25  # Should fail with SERVFAIL if DNSSEC is working
```

Check current DNS configuration:
```
cat /tmp/resolv.conf.auto
uci get dhcp.@dnsmasq[0].dnssec  # Should return '1'
```

### 5. Troubleshooting

- **SERVFAIL errors**: Check DNSSEC validation; disable temporarily with `uci set dhcp.@dnsmasq[0].dnssec='0'` if needed.
- **Slow resolution**: Verify firewall rules and network connectivity to Technitium IPs.
- **Nix package manager issues**: Add fallback DNS if `cache.nixos.org` has DNSSEC problems:
  ```
  uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
  uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
  uci commit dhcp
  /etc/init.d/dnsmasq restart
  ```

## Monitoring and Maintenance

- **Unbound Stats** (if remote control enabled):
  ```
  docker exec unbound unbound-control stats
  ```

- **Redis Stats**:
  ```
  docker exec unbound-db redis-cli -s /run/redis/redis.sock INFO | grep -E "used_memory|keyspace"
  ```

- **Logs**:
  ```
  docker compose logs unbound | tail -n 50
  ```

- **Update**: Pull new images and restart:
  ```
  docker compose pull
  docker compose up -d
  ```

This README provides a complete, end-to-end guide. For further customizations, refer to Unbound and Redis documentation.