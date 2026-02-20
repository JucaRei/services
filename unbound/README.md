```markdown
# Unbound + Redis Persistent DNS Resolver

Lightweight recursive DNS server with DNSSEC validation and persistent Redis caching. Optimized for low-power devices (e.g. NanoPi R3S).

## Prerequisites

- Debian Trixie on NanoPi R3S
- Docker & Docker Compose installed

```bash
mkdir -p ~/workspace/services/unbound/{cache/redis,cache/cachedb.d,data/unbound/{conf.d,iana.d,zones.d,log.d,control-keys},data/redis}
cd ~/workspace/services/unbound

# Set permissions (UID/GID 999)
sudo chown -R 999:999 cache/redis data/unbound cache/cachedb.d
sudo chmod -R 770 cache/redis data/unbound/log.d

# Root hints
curl -o data/unbound/iana.d/root.hints https://www.internic.net/domain/named.root
touch data/unbound/iana.d/root.key
sudo chown 999:999 data/unbound/iana.d/root.key
sudo chmod 644 data/unbound/iana.d/root.key
```

## docker-compose.yaml

```yaml
version: '3.8'
services:
  unbound-db-socket:
    image: busybox:latest
    volumes:
      - unbound-db-sock:/run/redis
      - ./cache/cachedb.d:/usr/local/unbound/cachedb.d/
    command: /bin/sh -c "mkdir -p /run/redis && chown 999:999 /run/redis && chmod 770 /run/redis && tail -f /dev/null"
    restart: unless-stopped

  unbound-db:
    image: redis:alpine
    depends_on: [unbound-db-socket]
    volumes_from: [unbound-db-socket]
    volumes:
      - ./cache/redis:/data
      - ./data/redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
    command: redis-server /usr/local/etc/redis/redis.conf
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -s /run/redis/redis.sock ping | grep -q PONG || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped

  unbound:
    image: madnuttah/unbound:latest
    depends_on:
      unbound-db:
        condition: service_healthy
    volumes_from: [unbound-db-socket]
    volumes:
      - ./data/unbound/unbound.conf:/usr/local/unbound/unbound.conf:rw
      - ./data/unbound/conf.d:/usr/local/unbound/conf.d/:rw
      - ./data/unbound/log.d:/usr/local/unbound/log.d/:rw
      - ./data/unbound/zones.d:/usr/local/unbound/zones.d/:rw
      - ./data/unbound/healthcheck.sh:/usr/local/unbound/sbin/healthcheck.sh:ro
      - ./data/unbound/iana.d/root.hints:/usr/local/unbound/iana.d/root.hints:ro
      - ./data/unbound/iana.d/root.key:/usr/local/unbound/iana.d/root.key:rw
      - ./cache/cachedb.d:/usr/local/unbound/cachedb.d/
      - unbound-pid:/var/run
      - ./data/unbound/control-keys:/usr/local/unbound/control-keys:ro
    ports:
      - "53:53/tcp"
      - "53:53/udp"
    cap_add: [NET_BIND_SERVICE]
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

Start:
```bash
docker compose up -d
```

## Important Config Files

### `data/unbound/unbound.conf`
```conf
server:
    module-config: "validator cachedb iterator"
    directory: "/usr/local/unbound"
    chroot: ""
    do-daemonize: no
    pidfile: "/dev/null"
    root-hints: "/usr/local/unbound/iana.d/root.hints"
    auto-trust-anchor-file: "/usr/local/unbound/iana.d/root.key"
    verbosity: 1
    logfile: "/usr/local/unbound/log.d/unbound.log"
    log-queries: yes
    log-replies: yes

include-toplevel: "/usr/local/unbound/conf.d/*.conf"
include-toplevel: "/usr/local/unbound/zones.d/*.conf"

cachedb:
    backend: "redis"
    redis-server-path: "/run/redis/redis.sock"
    redis-timeout: 50
    redis-expire-records: yes
```

### `data/unbound/conf.d/99-remote-control.conf`
```conf
remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-port: 8953
    server-key-file: "/usr/local/unbound/control-keys/unbound_server.key"
    server-cert-file: "/usr/local/unbound/control-keys/unbound_server.pem"
    control-key-file: "/usr/local/unbound/control-keys/unbound_control.key"
    control-cert-file: "/usr/local/unbound/control-keys/unbound_control.pem"
```

Generate keys:
```bash
sudo apt install unbound
sudo unbound-control-setup
sudo mkdir -p data/unbound/control-keys
sudo mv unbound_* data/unbound/control-keys/
sudo chown -R 999:999 data/unbound/control-keys/
sudo chmod 600 data/unbound/control-keys/*.key
sudo chmod 644 data/unbound/control-keys/*.pem
```

### `data/redis/redis.conf`
```conf
port 0
unixsocket /run/redis/redis.sock
unixsocketperm 770
protected-mode yes
appendonly no
dir /data
logfile ""
loglevel notice
maxmemory 64mb
maxmemory-policy allkeys-lru
```

### `data/unbound/healthcheck.sh`
```bash
#!/bin/sh
pgrep unbound >/dev/null || exit 1
drill @127.0.0.1 google.com >/dev/null || exit 1
[ "$EXTENDED_HEALTHCHECK" = "true" ] && drill @127.0.0.1 dnssec-failed.org +dnssec | grep "SERVFAIL" >/dev/null || exit 1
exit 0
```
```bash
chmod +x data/unbound/healthcheck.sh
```

## OpenWRT Integration

Replace ISP DNS with your Unbound IP (e.g. 10.10.10.25):
```bash
uci set network.wan.peerdns='0'
uci delete network.wan.dns
uci add_list network.wan.dns='10.10.10.25'
uci commit network
/etc/init.d/network restart

# DNSSEC & rebind protection
uci set dhcp.@dnsmasq[0].rebind_protection='1'
uci set dhcp.@dnsmasq[0].dnssec='1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Firewall rule:
```bash
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-DNS-Unbound'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_ip='10.10.10.25'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
```

Verify:
```bash
nslookup google.com 10.10.10.25
nslookup dnssec-failed.org 10.10.10.25   # Should fail (SERVFAIL)
```

## Monitoring & Control

```bash
# Status
docker exec unbound unbound-control status

# Statistics
docker exec unbound unbound-control stats_noreset

# Flush cache
docker exec unbound unbound-control flush .

# Redis cache size
docker exec unbound-db redis-cli -s /run/redis/redis.sock DBSIZE

# Logs
tail -n 100 data/unbound/log.d/unbound.log
```

## Editing Configs

Files owned by 999:999 — use sudo:
```bash
sudo nano data/unbound/unbound.conf
# After editing:
sudo chown -R 999:999 data/unbound
```

Restart after changes:
```bash
docker compose down && docker compose up -d
```

Done. Fast, private, persistent DNS with runtime control.
```
