# Unbound + Redis Persistent DNS Resolver

DNS recursivo leve com validação DNSSEC e cache persistente em Redis. Otimizado para ambientes com recursos limitados (LXC/containers).

---

## 📋 Índice

1. [Visão Geral](#visão-geral)
2. [Pré-requisitos](#pré-requisitos)
3. [Instalação Passo a Passo](#instalação-passo-a-passo)
4. [Configuração](#configuração)
5. [Inicialização](#inicialização)
6. [Validação DNSSEC](#validação-dnssec)
7. [Integração com OpenWRT](#integração-com-openwrt)
8. [Monitoramento e Controle](#monitoramento-e-controle)
9. [Solução de Problemas](#solução-de-problemas)
10. [Otimização de Recursos](#otimização-de-recursos)

---

## Visão Geral

### Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│                      LXC 1 (Unbound)                        │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Unbound   │───▶│    Redis    │───▶│   Cache     │     │
│  │  (DNSSEC)   │    │  (Socket)   │    │  Persist.   │     │
│  └──────┬──────┘    └─────────────┘    └─────────────┘     │
│         │                                                   │
│         ▼                                                   │
│    10.10.10.53:53                                          │
└─────────┬───────────────────────────────────────────────────┘
          │
    ┌─────┴─────┐
    │           │
    ▼           ▼
┌─────────┐ ┌─────────┐
│ LXC 2   │ │ LXC 3   │
│ DNS01   │ │ DNS02   │
│ 10.10.  │ │ 10.10.  │
│ 10.25   │ │ 10.26   │
└─────────┘ └─────────┘
```

### Componentes

| Componente | Função |
|------------|--------|
| **Unbound** | DNS recursivo com validação DNSSEC |
| **Redis** | Cache persistente via socket UNIX |
| **Technitium DNS** | Forwarders para clientes (opcional) |

### Vantagens

- ✅ DNSSEC habilitado por padrão
- ✅ Cache persistente (sobrevive a reinícios)
- ✅ Baixo consumo de memória (~100MB)
- ✅ Sem logs de consultas (privacidade)
- ✅ Controle via `unbound-control`

---

## Pré-requisitos

### Sistema

- Debian Trixie (ou similar)
- Docker 20+ e Docker Compose 2+
- LXC com mínimo 1 CPU e 300MB RAM

### Diretórios

```bash
# Criar estrutura de diretórios
mkdir -p ~/workspace/services/unbound/{cache/redis,cache/cachedb.d,data/unbound/{conf.d,iana.d,zones.d,log.d,control-keys},data/redis}

cd ~/workspace/services/unbound
```

---

## Instalação Passo a Passo

### Passo 1: Configurar Permissões

```bash
# Definir dono 999:999 (usuário do container)
sudo chown -R 999:999 cache/redis data/unbound cache/cachedb.d

# Definir permissões seguras
sudo chmod -R 770 cache/redis data/unbound/log.d
sudo chmod 755 data/unbound
```

### Passo 2: Baixar Root Hints

```bash
# Baixar hints dos servidores raiz
curl -o data/unbound/iana.d/root.hints https://www.internic.net/domain/named.root

# Criar arquivo root.key (será preenchido depois)
touch data/unbound/iana.d/root.key
sudo chown 999:999 data/unbound/iana.d/root.key
sudo chmod 644 data/unbound/iana.d/root.key
```

### Passo 3: Gerar Chaves de Controle (remote-control)

```bash
# Instalar Unbound temporariamente no host
sudo apt update && sudo apt install -y unbound

# Criar diretório das chaves
sudo mkdir -p data/unbound/control-keys

# Gerar chaves no diretório correto
cd data/unbound/control-keys
sudo unbound-control-setup

# Voltar ao diretório base
cd ~/workspace/services/unbound

# Ajustar permissões
sudo chown -R 999:999 data/unbound/control-keys/
sudo chmod 600 data/unbound/control-keys/*.key
sudo chmod 644 data/unbound/control-keys/*.pem
```

### Passo 4: Gerar Chave DNSSEC (root.key)

```bash
# Método 1: Usando container (recomendado)
docker run --rm \
  -e UNBOUND_UID=999 \
  -e UNBOUND_GID=999 \
  -v $(pwd)/data/unbound/iana.d:/usr/local/unbound/iana.d \
  madnuttah/unbound:latest \
  unbound-anchor -a "/usr/local/unbound/iana.d/root.key"

# Ajustar permissões
sudo chown 999:999 data/unbound/iana.d/root.key
sudo chmod 644 data/unbound/iana.d/root.key

# Verificar se foi criado
ls -la data/unbound/iana.d/root.key
# Deve mostrar ~1250 bytes
```

### Passo 5: Configurar Redis

Criar arquivo `data/redis/redis.conf`:

```conf
# Redis configuration for Unbound cachedb
# UNIX socket only, no persistence, low memory

port 0
unixsocket /run/redis/redis.sock
unixsocketperm 770

protected-mode yes
user default on nopass ~* &* +@all

appendonly no
dir /data
logfile ""
loglevel notice

daemonize no
supervised no
databases 1

# Memory – tuned for 300MB RAM LXC
maxmemory 32mb
maxmemory-policy allkeys-lru

tcp-keepalive 60
timeout 300

# Low-memory optimizations
hash-max-ziplist-entries 256
hash-max-ziplist-value 32
list-max-ziplist-size -2
set-max-intset-entries 256
zset-max-ziplist-entries 64
zset-max-ziplist-value 32
lazyfree-lazy-eviction no
lazyfree-lazy-expire no
lazyfree-lazy-server-del no
```

### Passo 6: Configurar Unbound

#### Arquivo principal: `data/unbound/unbound.conf`

```conf
server:
    directory: "/usr/local/unbound"
    chroot: ""
    do-daemonize: no
    pidfile: "/dev/null"
    username: ""

    # Root hints & DNSSEC
    root-hints: "/usr/local/unbound/iana.d/root.hints"
    auto-trust-anchor-file: "/usr/local/unbound/iana.d/root.key"

    # Logging (minimal)
    verbosity: 0
    logfile: "/usr/local/unbound/log.d/unbound.log"
    log-servfail: yes

    # Cache & performance
    module-config: "validator cachedb iterator"
    serve-expired: yes
    serve-expired-ttl: 86400
    prefetch: yes

# Cachedb with Redis UNIX socket
cachedb:
    backend: "redis"
    redis-server-path: "/run/redis/redis.sock"
    redis-timeout: 50
    redis-expire-records: yes

# Remote control
remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-port: 8953
    server-key-file: "/usr/local/unbound/control-keys/unbound_server.key"
    server-cert-file: "/usr/local/unbound/control-keys/unbound_server.pem"
    control-key-file: "/usr/local/unbound/control-keys/unbound_control.key"
    control-cert-file: "/usr/local/unbound/control-keys/unbound_control.pem"
```

#### Arquivo: `data/unbound/conf.d/interfaces.conf`

```conf
server:
    interface: 0.0.0.0@53
    outgoing-interface: 0.0.0.0

    do-ip4: yes
    do-ip6: no
    do-tcp: yes
    do-udp: yes
    udp-connect: yes

    prefer-ip4: yes
    prefer-ip6: no
```

#### Arquivo: `data/unbound/conf.d/access-control.conf`

```conf
server:
    access-control: 127.0.0.0/8 allow
    access-control: 10.0.0.0/8 allow
    access-control: 10.10.10.0/24 allow
    access-control: 172.16.0.0/12 allow
    access-control: 172.17.0.0/16 allow
    access-control: 192.168.0.0/16 allow
```

#### Arquivo: `data/unbound/conf.d/logging.conf`

```conf
server:
  use-syslog: no
  log-time-ascii: yes
  logfile: "/usr/local/unbound/log.d/unbound.log"
  log-local-actions: no
  log-queries: no
  log-replies: no
  log-servfail: yes
  val-log-level: 0
  verbosity: 0
```

#### Arquivo: `data/unbound/conf.d/performance.conf`

```conf
server:
    # Threads
    num-threads: 1
    so-reuseport: yes
    outgoing-range: 64
    num-queries-per-thread: 128

    # Cache em RAM (mínimo - Redis faz cache principal)
    msg-cache-size: 8m
    rrset-cache-size: 16m
    neg-cache-size: 4m

    # Slabs
    msg-cache-slabs: 1
    rrset-cache-slabs: 1
    infra-cache-slabs: 1
    key-cache-slabs: 1

    # TTL
    cache-min-ttl: 180
    cache-max-ttl: 86400
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-reply-ttl: 30
    prefetch: yes
    prefetch-key: yes

    # Buffers
    edns-buffer-size: 1232
    max-udp-size: 4096
    msg-buffer-size: 8192
```

#### Arquivo: `data/unbound/conf.d/security.conf`

```conf
server:
    do-not-query-localhost: no
    unblock-lan-zones: no
    insecure-lan-zones: yes

    # Private addresses
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 10.10.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10
    private-address: ::ffff:0:0/96

    # Rate limiting
    ratelimit: 500
    infra-cache-numhosts: 500
    ip-ratelimit-size: 2m

    # Hardening
    hide-identity: yes
    hide-version: yes
    version: ""
    aggressive-nsec: yes
    qname-minimisation: yes
    qname-minimisation-strict: yes
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

### Passo 7: Healthcheck

Criar arquivo `data/unbound/healthcheck.sh`:

```bash
#!/bin/sh

## Unbound Statistics
unbound_root=/usr/local/unbound
rawfile="$unbound_root/log.d/unbound_stats"
tmpfile="$unbound_root/log.d/unbound_stats.tmp"
logfile="$unbound_root/log.d/unbound-stats.log"

# Run unbound-control and create file with statistics
$unbound_root/sbin/unbound-control stats_noreset > ${rawfile}

# Remove unnecessary lines
sed -r '/.*(histogram|thread).*/d' ${rawfile} > ${tmpfile}

# Multiline to single line, separated with commas
awk -vRS="" -vOFS=',' '$1=$1' ${tmpfile} > ${logfile}

## Healthcheck
HEALTHCHECK_PORT=${HEALTHCHECK_PORT:-53}
EXTENDED_HEALTHCHECK=${EXTENDED_HEALTHCHECK:-false}
EXTENDED_HEALTHCHECK_DOMAIN=${EXTENDED_HEALTHCHECK_DOMAIN:-nlnetlabs.nl}

# Check for opened tcp/udp port(s)
check_port="$(netstat -ln | grep -c ":$HEALTHCHECK_PORT")" &> /dev/null

if [ $check_port -eq 0 ]; then
  echo "Warning: Port $HEALTHCHECK_PORT not open"
  exit 1
else
  echo "Port $HEALTHCHECK_PORT open"
  if ! $EXTENDED_HEALTHCHECK; then
    exit 0
  fi
fi

## Extended healthcheck
ip="$(drill -Q -p $HEALTHCHECK_PORT $EXTENDED_HEALTHCHECK_DOMAIN @127.0.0.1)" &> /dev/null

if [ $? -ne 0 ]; then
  echo "Warning: Domain '$EXTENDED_HEALTHCHECK_DOMAIN' not resolved"
  exit 1
else
  echo "Domain '$EXTENDED_HEALTHCHECK_DOMAIN' resolved to '$ip'"
  exit 0
fi
```

Tornar executável:

```bash
chmod +x data/unbound/healthcheck.sh
sudo chown 999:999 data/unbound/healthcheck.sh
```

---

## Inicialização

### Iniciar Serviços

```bash
cd ~/workspace/services/unbound
docker compose up -d
```

### Verificar Status

```bash
# Verificar containers
docker compose ps

# Verificar Unbound
docker exec unbound unbound-control status

# Esperar Redis estar saudável
docker compose logs unbound-db
```

### Testar Resolução

```bash
# Teste básico
docker exec unbound drill google.com @127.0.0.1

# Deve retornar IPs do Google
```

---

## Validação DNSSEC

### Testar DNSSEC Funcionando

```bash
# Domínio válido - deve retornar IPs
docker exec unbound drill nlnetlabs.nl @127.0.0.1

# Domínio com DNSSEC quebrado - deve falhar (SERVFAIL)
docker exec unbound drill dnssec-failed.org @127.0.0.1
```

### Verificar Estatísticas DNSSEC

```bash
docker exec unbound unbound-control stats_noreset | grep -iE "(secure|bogus|val)"
```

### Verificar Logs de Validação

```bash
# Ver consultas DS (Delegation Signer)
cat data/unbound/log.d/unbound.log | grep "\. DS IN"
```

---

## Integração com OpenWRT

### Configurar DNS no OpenWRT

```bash
# Usar Unbound como DNS primário
uci set network.wan.peerdns='0'
uci delete network.wan.dns
uci add_list network.wan.dns='10.10.10.53'
uci commit network
/etc/init.d/network restart

# Habilitar DNSSEC e rebind protection no dnsmasq
uci set dhcp.@dnsmasq[0].rebind_protection='1'
uci set dhcp.@dnsmasq[0].dnssec='1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### Regra de Firewall

```bash
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-DNS-Unbound'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_ip='10.10.10.53'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
```

### Verificar no OpenWRT

```bash
nslookup google.com 10.10.10.53
nslookup dnssec-failed.org 10.10.10.53  # Deve falhar
```

---

## Monitoramento e Controle

### Comandos unbound-control

```bash
# Status do serviço
docker exec unbound unbound-control status

# Estatísticas completas
docker exec unbound unbound-control stats_noreset

# Estatísticas resumidas
docker exec unbound unbound-control stats_noreset | head -30

# Limpar cache
docker exec unbound unbound-control flush .

# Recarregar configuração
docker exec unbound unbound-control reload

# Verificar chaves DNSSEC
docker exec unbound unbound-control dump_insecure
```

### Monitorar Redis

```bash
# Tamanho do cache Redis
docker exec unbound-db redis-cli -s /run/redis/redis.sock DBSIZE

# Informações do Redis
docker exec unbound-db redis-cli -s /run/redis/redis.sock INFO memory

# Ver chaves no cache
docker exec unbound-db redis-cli -s /run/redis/redis.sock KEYS '*' | head -20
```

### Logs

```bash
# Ver últimas entradas de log
cat data/unbound/log.d/unbound.log | tail -50

# Ver apenas falhas
cat data/unbound/log.d/unbound.log | grep -i error

# Ver consultas SERVFAIL
cat data/unbound/log.d/unbound.log | grep SERVFAIL
```

### Estatísticas de Cache

```bash
# Hit rate do cache
docker exec unbound unbound-control stats_noreset | grep -E "(cachehits|cachemiss)"

# Calcular hit rate: cachehits / (cachehits + cachemiss)
```

---

## Solução de Problemas

### Unbound não inicia

```bash
# Verificar logs
docker compose logs unbound

# Verificar permissões
ls -la data/unbound/iana.d/
ls -la data/unbound/control-keys/

# Verificar se root.key não está vazio
wc -c data/unbound/iana.d/root.key
# Deve ser > 1000 bytes
```

### DNSSEC não valida

```bash
# Regenerar root.key
docker run --rm \
  -e UNBOUND_UID=999 \
  -e UNBOUND_GID=999 \
  -v $(pwd)/data/unbound/iana.d:/usr/local/unbound/iana.d \
  madnuttah/unbound:latest \
  unbound-anchor -a "/usr/local/unbound/iana.d/root.key"

sudo chown 999:999 data/unbound/iana.d/root.key

# Reiniciar
docker compose restart unbound
```

### Redis não conecta

```bash
# Verificar socket
docker exec unbound-db-socket ls -la /run/redis/

# Verificar permissões
docker exec unbound-db-socket stat /run/redis/redis.sock

# Reiniciar socket
docker compose restart unbound-db-socket unbound-db
```

### Consultas lentas

```bash
# Verificar estatísticas
docker exec unbound unbound-control stats_noreset | grep recursion.time

# Aumentar outgoing-range se necessário
# Editar performance.conf: outgoing-range: 128

# Verificar Redis
docker exec unbound-db redis-cli -s /run/redis/redis.sock INFO stats
```

### OOM (Out of Memory)

```bash
# Verificar uso de memória
docker stats --no-stream

# Reduzir caches em performance.conf:
# msg-cache-size: 4m
# rrset-cache-size: 8m
# neg-cache-size: 2m

# Reduzir Redis em redis.conf:
# maxmemory 24mb
```

---

## Otimização de Recursos

### Configuração para 300MB RAM

| Componente | Memória |
|------------|---------|
| Unbound (caches) | ~28MB |
| Redis (maxmemory) | 32MB |
| Unbound (overhead) | ~15MB |
| Buffer sistema | ~25MB |
| **Total** | **~100MB** |

### Ajustes para Mais/Menos Memória

#### Para 200MB RAM

```conf
# performance.conf
msg-cache-size: 4m
rrset-cache-size: 8m
neg-cache-size: 2m
outgoing-range: 32
infra-cache-numhosts: 250

# redis.conf
maxmemory 24mb
```

#### Para 512MB RAM

```conf
# performance.conf
msg-cache-size: 16m
rrset-cache-size: 32m
neg-cache-size: 8m
outgoing-range: 128
infra-cache-numhosts: 1000

# redis.conf
maxmemory 64mb
```

### Dicas de Performance

1. **serve-expired**: Mantém respostas válidas mesmo se upstream falhar
2. **prefetch**: Atualiza registros populares antes de expirarem
3. **cache-min-ttl**: 180s equilibra frescor e hit rate
4. **Redis via socket**: Mais rápido que rede local

---

## Atualização

### Atualizar Unbound

```bash
# Parar serviços
docker compose down

# Baixar nova imagem
docker pull madnuttah/unbound:latest

# Subir novamente
docker compose up -d

# Verificar versão
docker exec unbound unbound-control status | grep version
```

### Atualizar Root Hints

```bash
# Baixar novas hints
curl -o data/unbound/iana.d/root.hints https://www.internic.net/domain/named.root
sudo chown 999:999 data/unbound/iana.d/root.hints

# Recarregar
docker exec unbound unbound-control reload
```

---

## Segurança

### Melhores Práticas

- ✅ `val-permissive-mode: no` - validação DNSSEC estrita
- ✅ `hide-identity: yes` - não revela versão do Unbound
- ✅ `access-control` - restringe quem pode consultar
- ✅ `private-address` - não vaza consultas para RFC1918
- ✅ `ratelimit: 500` - previne abuso

### Atualizar Chaves de Controle

```bash
# Remover chaves antigas
rm data/unbound/control-keys/*

# Gerar novas chaves
cd data/unbound/control-keys
sudo unbound-control-setup

# Ajustar permissões
sudo chown -R 999:999 .
sudo chmod 600 *.key
sudo chmod 644 *.pem

# Reiniciar
docker compose restart unbound
```

---

## Referências

- [Documentação Oficial do Unbound](https://nlnetlabs.nl/documentation/unbound/)
- [Docker Unbound (madnuttah)](https://hub.docker.com/r/madnuttah/unbound)
- [Redis Documentation](https://redis.io/documentation)
- [DNSSEC Validation Guide](https://dnssec-analyzer.verisignlabs.com/)

---

**Última atualização:** Março 2026
**Versão do Unbound:** 1.24.2
**Versão do Redis:** Alpine (7.x)
