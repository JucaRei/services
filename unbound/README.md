# Unbound DNS with Redis Cache Backend

This is a production-ready DNS server setup using Unbound with Redis as a persistent cache backend, specifically optimized for low-power devices like the Nanopi R3S.

## Architecture Overview

The setup consists of three Docker containers working together:

### 1. unbound-db-socket Container
- **Purpose**: Creates shared volumes and manages socket permissions
- **Image**: `busybox:latest` (lightweight utility container)
- **Key Functions**:
  - Creates `/run/redis` directory with proper permissions (770, user 1000:1000)
  - Shares volumes with other containers via `volumes_from`
  - Mounts `cachedb.d` for persistent Redis cache storage

### 2. unbound-db (Redis) Container
- **Purpose**: Redis cache backend for Unbound
- **Image**: `redis:alpine` (lightweight Redis)
- **Key Features**:
  - Health check with ping every 5 seconds
  - Persistent storage via `redis-data` volume
  - Custom Redis configuration from `./data/redis/redis.conf`
  - Optimized for low memory usage (64MB max)

### 3. unbound (Main DNS Server) Container
- **Purpose**: Primary Unbound DNS server
- **Image**: `madnuttah/unbound:latest`
- **Key Features**:
  - Depends on Redis being healthy before starting
  - Binds to port 53 (both TCP and UDP)
  - Uses NET_BIND_SERVICE capability for port binding
  - Comprehensive health checking every 60 seconds
  - Extended statistics enabled

## Configuration Details

### Unbound Main Configuration (unbound.conf)

**Core Server Settings**:
- **Module Configuration**: `validator cachedb iterator` - DNSSEC validation with Redis cache
- **Root Hints**: Uses IANA root hints for authoritative DNS resolution
- **PID File**: Set to `/dev/null` to avoid permission issues
- **Chroot**: Disabled for container compatibility

**Redis Cache Integration**:
```conf
cachedb:
    backend: "redis"
    redis-server-host: "unbound-db"
    redis-server-port: 6379
    redis-timeout: 100
    redis-expire-records: yes
```

### Security Configuration

**Access Control**:
- Allows DNS queries from private networks:
  - 127.0.0.0/8 (localhost)
  - 10.0.0.0/8 (private class A)
  - 10.10.10.0/24 (specific subnet)
  - 172.16.0.0/12 (private class B)
  - 192.168.0.0/16 (private class C)

**DNSSEC & Security Features**:
- DNSSEC validation enabled with strict settings
- Aggressive NSEC for privacy
- Query name minimization for privacy
- Rate limiting (200 queries/second)
- Identity and version hiding
- Unwanted reply threshold protection

### Performance Optimization

**Memory Management**:
- **RAM Cache Disabled**: All cache stored in Redis (msg-cache-size: 0, rrset-cache-size: 0)
- **Single Thread**: Optimized for low-power device (num-threads: 1)
- **Reduced Connection Limits**: Outgoing range set to 128

**Caching Strategy**:
- TTL settings: 10 minutes minimum, 2 hours maximum
- Prefetch enabled for popular queries
- Serve expired records to reduce upstream queries

### Redis Optimization

**Memory Management**:
- **64MB Maximum Memory**: Optimized for low-memory device
- **LRU Eviction**: Least Recently Used policy for cache management
- **AOF Persistence**: Append-only file for data durability

**Performance Tweaks**:
- Disabled heavy features (lazyfree, snapshots)
- Optimized data structure limits for memory efficiency
- TCP keepalive and timeout settings for stability

## Directory Structure

```
unbound/
├── docker-compose.yaml          # Main Docker Compose configuration
├── data/
│   ├── unbound/
│   │   ├── conf.d/              # Modular Unbound configurations
│   │   │   ├── access-control.conf
│   │   │   ├── interfaces.conf
│   │   │   ├── logging.conf
│   │   │   ├── performance.conf
│   │   │   ├── remote-control.conf
│   │   │   ├── security.conf
│   │   │   └── statistics.conf
│   │   ├── zones.d/             # DNS zone configurations
│   │   │   ├── auth-zone.conf
│   │   │   └── local-zone.conf
│   │   ├── log.d/               # Log files
│   │   ├── unbound.conf         # Main Unbound configuration
│   │   ├── root.hints           # Root DNS servers
│   │   ├── root.key             # DNSSEC root key
│   │   └── healthcheck.sh       # Health check script
│   └── redis/
│       └── redis.conf           # Redis configuration
└── README.md                    # This file
```

## Key Benefits

1. **Persistent Caching**: Redis provides persistent cache across container restarts
2. **Low Memory Footprint**: Optimized for embedded devices like Nanopi R3S
3. **DNSSEC Support**: Full DNS security with validation
4. **Privacy Features**: Query minimization and identity hiding
5. **High Availability**: Health checks and restart policies
6. **Performance**: Redis cache reduces upstream DNS queries significantly

## Deployment

To deploy this setup:

1. Ensure Docker and Docker Compose are installed
2. Navigate to the unbound directory
3. Run: `docker-compose up -d`
4. The DNS server will be available on port 53

## Monitoring

The setup includes comprehensive health checks:
- Redis health check: ping every 5 seconds
- Unbound health check: custom script every 60 seconds
- Container restart policies for high availability

## Security Notes

- DNSSEC validation is enabled by default
- Query name minimization protects privacy
- Rate limiting prevents abuse
- Only private networks are allowed to query the server
- Identity and version information is hidden

## Performance Notes

- RAM cache is disabled in favor of Redis persistence
- Single-threaded operation for low-power devices
- Optimized Redis configuration for 64MB memory limit
- Aggressive caching with TTL optimization

## OpenWRT Configuration for Technitium DNS

This section documents the UCI commands used to configure OpenWRT to use Technitium DNS servers (10.10.10.25 and 10.10.10.26) instead of ISP DNS.

### 1. DHCP/DNS Configuration

**Enable DNSSEC and Rebind Protection:**
```bash
uci set dhcp.@dnsmasq[0].rebind_protection='1'
uci set dhcp.@dnsmasq[0].dnssec='1'
uci commit dhcp
```

**Verify DNS servers are configured:**
```bash
uci get dhcp.@dnsmasq[0].server  # Should show 10.10.10.25 and 10.10.10.26
```

### 2. Firewall Configuration

**Add rules to allow DNS traffic to Technitium servers:**
```bash
# Allow DNS to Technitium server 1 (10.10.10.25)
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-DNS-Technitium-25'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_ip='10.10.10.25'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow DNS to Technitium server 2 (10.10.10.26)
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-DNS-Technitium-26'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_ip='10.10.10.26'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='ACCEPT'

# Apply firewall changes
uci commit firewall
/etc/init.d/firewall restart
```

### 3. Network Configuration

**Verify WAN interface is configured correctly:**
```bash
uci get network.wan.peerdns  # Should be '0' (don't use ISP DNS)
uci get network.wan.dns      # Should show 10.10.10.25 and 10.10.10.26
```

### 4. Service Restart

**Restart services to apply changes:**
```bash
/etc/init.d/dnsmasq restart
/etc/init.d/network restart
```

### 5. Verification Commands

**Test DNS resolution:**
```bash
# Test connectivity to DNS servers
ping 10.10.10.25
ping 10.10.10.26

# Test DNS resolution
nslookup google.com 10.10.10.25
nslookup google.com 10.10.10.26

# Test DNSSEC validation
nslookup dnssec-failed.org 10.10.10.25  # Should fail if DNSSEC is working
```

**Check current DNS configuration:**
```bash
cat /tmp/resolv.conf.auto
uci get dhcp.@dnsmasq[0].dnssec  # Should return '1'
```

### 6. Troubleshooting

**If Nix package manager fails with DNS resolution:**
The cache.nixos.org domain may have DNSSEC issues. Add fallback DNS servers:
```bash
uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

**Common Issues:**
- **SERVFAIL errors**: May indicate DNSSEC validation blocking invalid responses
- **Slow resolution**: Check firewall rules and network connectivity

**Fix Path**
```bash
sudo chown -R 999:999 ./cache/redis ./data/unbound ./cache/cachedb.d
sudo chmod -R 770 ./cache/redis ./data/unbound/log.d
```