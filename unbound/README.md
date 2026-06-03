# Unbound + Redis Persistent DNS Resolver

DNS recursivo leve com validação DNSSEC e cache persistente em Redis. Otimizado para hardware de baixo consumo (ex: NanoPi R3S) rodando sob LXC unprivileged ou containers Docker comuns.

---

## 📋 Índice

1. [Visão Geral](#-visão-geral)
2. [Pré-requisitos](#-pré-requisitos)
3. [Estrutura de Diretórios](#-estrutura-de-diretórios)
4. [docker-compose.yaml](#-docker-composeyaml)
5. [Configuração Principal](#-configuração-principal)
6. [Configurações Modulares (conf.d)](#-configurações-modulares-confd)
7. [Healthcheck & Estatísticas](#-healthcheck--estatísticas)
8. [Configuração do Redis](#-configuração-do-redis)
9. [Inicialização e Controle](#-inicialização-e-controle)
10. [Integração com OpenWRT](#-integração-com-openwrt)
11. [Solução de Problemas](#-solução-de-problemas)

---

## 🔍 Visão Geral

Esta solução implementa um servidor DNS recursivo local rápido e focado em privacidade. Ele se diferencia por:
* **Validação DNSSEC**: Garante a integridade criptográfica das respostas DNS.
* **Cache Persistente (Redis)**: Evita perda de cache ao reiniciar o container, minimizando consultas externas.
* **Comunicação por Socket UNIX**: Elimina overhead de rede TCP/IP na comunicação Unbound ⇄ Redis.
* **Mínimo I/O**: Desativação de logs de queries no disco e redirecionamento de logs de inicialização/erro para o stdout para preservar cartões SD/eMMC.

---

## ⚡ Pré-requisitos

* Docker e Docker Compose instalados no host.
* Portas `53/udp` e `53/tcp` livres no IP que escutará as requisições (se for rodar direto no host).
* Caso use LXC Unprivileged, garanta o suporte ao kernel `cap_add: [NET_BIND_SERVICE]`.

---

## 📁 Estrutura de Diretórios

Antes de iniciar, crie a estrutura de pastas no host e ajuste o proprietário para o UID/GID `999` (proprietário padrão da imagem distroless do Unbound):

```bash
# Criar estrutura de diretórios
mkdir -p ~/workspace/services/unbound/{cache/redis,cache/cachedb.d,data/unbound/{conf.d,zones.d,log.d,control-keys},data/redis}

# Definir dono 999:999 (usuário interno do container)
sudo chown -R 999:999 cache/redis data/unbound cache/cachedb.d

# Definir permissões de escrita seguras
sudo chmod -R 770 cache/redis data/unbound/log.d
```

---

## 🐳 docker-compose.yaml

Este `docker-compose.yaml` gerencia o socket compartilhado e define os limites recomendados de recursos para sistemas de 512MB/1GB de RAM (como o NanoPi R3S).

```yaml
version: '3.8'

services:
  # Container de suporte para gerenciar a criação do UNIX socket do Redis.
  # Em containers distroless/non-root executados no LXC unprivileged, compartilhar
  # sockets em disco exige uma pasta intermediária com permissões UID/GID rígidas (999).
  unbound-db-socket:
    container_name: unbound-db-socket
    image: busybox:latest
    volumes:
      - unbound-db-sock:/run/redis
      - ./cache/cachedb.d:/usr/local/unbound/cachedb.d/
    command: /bin/sh -c "mkdir -p /run/redis && chown 999:999 /run/redis && chmod 770 /run/redis && tail -f /dev/null"
    restart: unless-stopped

  # Banco Redis atuando estritamente em memória com cache persistente via Unix Socket.
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

  # Serviço Unbound DNS Recursivo
  unbound:
    container_name: unbound
    image: madnuttah/unbound:1.24.2-2
    depends_on:
      unbound-db:
        condition: service_healthy
    volumes_from:
      - unbound-db-socket
    volumes:
      - ./data/unbound/unbound.conf:/usr/local/unbound/unbound.conf:rw
      - ./data/unbound/conf.d:/usr/local/unbound/conf.d/:rw
      - ./data/unbound/log.d:/usr/local/unbound/log.d/:rw
      - ./data/unbound/log.d/unbound-stats.log:/usr/local/unbound/log.d/unbound-stats.log:rw
      - ./data/unbound/zones.d:/usr/local/unbound/zones.d/:rw
      - ./data/unbound/healthcheck.sh:/usr/local/unbound/sbin/healthcheck.sh:rw
      - ./cache/cachedb.d:/usr/local/unbound/cachedb.d/
      - unbound-pid:/var/run
      - ./data/unbound/control-keys:/usr/local/unbound/control-keys:ro
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

---

## 🛠️ Configuração Principal

### `data/unbound/unbound.conf`

Mantido limpo e direto, importando as configurações modulares automaticamente e definindo o Redis como backend do módulo `cachedb`:

```conf
server:
    directory: "/usr/local/unbound"
    chroot: ""
    do-daemonize: no
    pidfile: "/dev/null"
    username: ""

    # Ordem crítica de execução dos módulos
    module-config: "validator cachedb iterator"

# Importa as configurações modulares da subpasta
include-toplevel: "/usr/local/unbound/conf.d/*.conf"
include-toplevel: "/usr/local/unbound/zones.d/*.conf"

# Módulo de Cache persistente com Redis
cachedb:
    backend: "redis"
    redis-server-path: "/run/redis/redis.sock"
    redis-timeout: 50
    redis-expire-records: yes

# Bloco de Remote Control
remote-control:
    control-enable: no # Mude para 'yes' apenas após gerar as chaves de controle remoto
    control-interface: 127.0.0.1
    control-port: 8953
    server-key-file: "/usr/local/unbound/control-keys/unbound_server.key"
    server-cert-file: "/usr/local/unbound/control-keys/unbound_server.pem"
    control-key-file: "/usr/local/unbound/control-keys/unbound_control.key"
    control-cert-file: "/usr/local/unbound/control-keys/unbound_control.pem"
```

> [!WARNING]
> Mudar `control-enable` para `yes` sem que as chaves SSL existam em `control-keys` impedirá a inicialização do Unbound. Veja a seção [Gerar Chaves de Controle](#gerar-chaves-de-controle) para habilitá-lo com segurança.

---

## 📂 Configurações Modulares (`conf.d`)

Os arquivos de configuração do Unbound no diretório `data/unbound/conf.d/` dividem as responsabilidades de forma organizada:

* **[access-control.conf](file:///e:/workspace/repos/antigravity/services/unbound/data/unbound/conf.d/access-control.conf)**: Libera consultas recursivas apenas para os intervalos de IPs locais permitidos (ex: `127.0.0.0/8`, `192.168.0.0/16`, `10.10.10.0/24`).
* **[interfaces.conf](file:///e:/workspace/repos/antigravity/services/unbound/data/unbound/conf.d/interfaces.conf)**: Configura as interfaces de rede de escuta (escuta em `0.0.0.0@53`, desativa IPv6 para economizar RAM).
* **[logging.conf](file:///e:/workspace/repos/antigravity/services/unbound/data/unbound/conf.d/logging.conf)**: Desativa os logs em disco de queries/replies (`log-queries: no`) e configura a saída para stdout/stderr (`logfile: ""`) a fim de otimizar performance.
* **[performance.conf](file:///e:/workspace/repos/antigravity/services/unbound/data/unbound/conf.d/performance.conf)**: Ajusta o consumo de RAM (caches de RRset/Message reduzidos, pois o cache principal fica no Redis) e ativa a atualização antecipada de registros (`prefetch: yes`).
* **[security.conf](file:///e:/workspace/repos/antigravity/services/unbound/data/unbound/conf.d/security.conf)**: Implementa endurecimento (hardening) de segurança (qname-minimisation, limitação de taxa por IP, ocultação de versão e bloqueio de consultas privadas do exterior).
* **[statistics.conf](file:///e:/workspace/repos/antigravity/services/unbound/data/unbound/conf.d/statistics.conf)**: Habilita a geração periódica de estatísticas para fins de monitoramento.
* **[trust-anchor.conf](file:///e:/workspace/repos/antigravity/services/unbound/data/unbound/conf.d/trust-anchor.conf)**: Configura as chaves âncora de segurança globais (DNSSEC).

---

## 📈 Healthcheck & Estatísticas

### `data/unbound/healthcheck.sh`

O script de healthcheck real executa duas funções cruciais de forma integrada:
1. **Coleta de Estatísticas**: Executa o `unbound-control` e formata as métricas excluindo histogramas e threads, salvando em um log unificado CSV (`unbound-stats.log`) pronto para ferramentas de monitoramento como o Zabbix.
2. **Checagem de Integridade**: Valida se a porta do serviço está aberta via `netstat` e faz consultas reais com `drill` localmente.

```bash
#!/bin/sh

## Unbound Statistics
unbound_root=/usr/local/unbound
rawfile="$unbound_root/log.d/unbound_stats"
tmpfile="$unbound_root/log.d/unbound_stats.tmp"
logfile="$unbound_root/log.d/unbound-stats.log"

# Executa unbound-control e cria arquivo com estatísticas
$unbound_root/sbin/unbound-control stats_noreset > ${rawfile} 2>/dev/null

# Limpa linhas desnecessárias (como histogramas e threads)
sed -r '/.*(histogram|thread).*/d' ${rawfile} > ${tmpfile} 2>/dev/null

# Converte linhas em uma linha única separada por vírgulas para facilitar o parsing
awk -vRS="" -vOFS=',' '$1=$1' ${tmpfile} > ${logfile} 2>/dev/null

## Healthcheck
HEALTHCHECK_PORT=${HEALTHCHECK_PORT:-5335}
EXTENDED_HEALTHCHECK=${EXTENDED_HEALTHCHECK:-false}
EXTENDED_HEALTHCHECK_DOMAIN=${EXTENDED_HEALTHCHECK_DOMAIN:-nlnetlabs.nl}

# Verifica se a porta correspondente está escutando localmente
check_port="$(netstat -ln | grep -c ":$HEALTHCHECK_PORT")" &> /dev/null

if [ $check_port -eq 0 ]; then
  echo "Warning: Port $HEALTHCHECK_PORT not open"
  exit 1
else
  echo "Port $HEALTHCHECK_PORT open"
  # Se o extended healthcheck estiver desligado, encerra com sucesso
  if ! $EXTENDED_HEALTHCHECK; then
    exit 0
  fi
fi

## Extended healthcheck
# Executa query utilizando drill localmente
ip="$(drill -Q -p $HEALTHCHECK_PORT $EXTENDED_HEALTHCHECK_DOMAIN @127.0.0.1)" &> /dev/null

if [ $? -ne 0 ]; then
  echo "Warning: Domain '$EXTENDED_HEALTHCHECK_DOMAIN' not resolved"
  exit 1
else
  echo "Domain '$EXTENDED_HEALTHCHECK_DOMAIN' resolved to '$ip'"
  exit 0
fi
```

Tornar o script executável no host com:
```bash
chmod +x data/unbound/healthcheck.sh
sudo chown 999:999 data/unbound/healthcheck.sh
```

---

## 💾 Configuração do Redis

### `data/redis/redis.conf`

Otimizado para rodar como banco estritamente em memória com baixo consumo de RAM (~32MB de cache máximo) e focado em sockets locais:

```conf
# Redis configuration for Unbound cachedb
# UNIX socket only, no persistence, low memory - NanoPi R3S

# Network / Listening (Disable TCP completely)
port 0
bind 127.0.0.1 -::1

# UNIX Socket - required for Unbound cachedb
unixsocket /run/redis/redis.sock
unixsocketperm 770

# Security
protected-mode yes
user default on nopass ~* &* +@all

# Persistence: completely disabled
appendonly no
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

# Memory – tuned for 300MB RAM LXC
maxmemory 32mb
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

---

## 🚀 Inicialização e Controle

### Inicialização Básica

Suba os containers com o docker compose:
```bash
docker compose up -d
```

### Gerar Chaves de Controle

Para usar o controle remoto e extrair estatísticas via `unbound-control`, você deve gerar os certificados/chaves locais no host e apontá-los para a pasta montada do container:

```bash
# Instalar utilitário no host temporariamente para gerar chaves
sudo apt update && sudo apt install -y unbound

# Gerar chaves locais temporárias no host
sudo unbound-control-setup

# Mover chaves para a pasta de volumes montada
sudo mkdir -p data/unbound/control-keys
sudo mv unbound_* data/unbound/control-keys/

# Ajustar permissões UID/GID
sudo chown -R 999:999 data/unbound/control-keys/
sudo chmod 600 data/unbound/control-keys/*.key
sudo chmod 644 data/unbound/control-keys/*.pem
```

Após fazer isso, altere no seu [unbound.conf](file:///e:/workspace/repos/antigravity/services/unbound/data/unbound/unbound.conf) a diretiva `control-enable: yes` e recrie o container:
```bash
docker compose down && docker compose up -d
```

### Monitorar o Cache do Redis

Você pode consultar em tempo real a quantidade de entradas persistidas no cache do Redis executando:
```bash
docker exec unbound-db redis-cli -s /run/redis/redis.sock DBSIZE
```

---

## 🌐 Integração com OpenWRT

Configuração recomendada para apontar o WAN do roteador OpenWRT para o seu DNS do Unbound (assumindo que o Unbound está escutando no IP `10.10.10.53`):

```bash
# Aponta a interface WAN para o Unbound e desliga peerdns da operadora
uci set network.wan.peerdns='0'
uci delete network.wan.dns
uci add_list network.wan.dns='10.10.10.53'
uci commit network
/etc/init.d/network restart

# Habilita validação DNSSEC & rebind protection no dnsmasq local do OpenWRT
uci set dhcp.@dnsmasq[0].rebind_protection='1'
uci set dhcp.@dnsmasq[0].dnssec='1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### Regra de Firewall no OpenWRT

```bash
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-DNS-Unbound'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_ip='10.10.10.53'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
```

---

## 🛠️ Solução de Problemas

### DNSSEC Falha no Boot (Problema de Relógio/NTP)

Em dispositivos sem bateria de RTC (como o NanoPi R3S), o sistema pode reiniciar com o relógio atrasado. Como a validação DNSSEC exige o relógio correto, o Unbound falhará ao resolver nomes, impedindo que o próprio NTP do host resolva os nomes dos servidores de hora para sincronizar o relógio (um problema clássico de dependência mútua).

**Resolução Temporária**:
1. No host (FriendlyWrt / NanoPi), ajuste o relógio manualmente via SSH:
   ```bash
   date -s "YYYY-MM-DD HH:MM:SS"
   ```
2. No container/LXC, navegue até a pasta correspondente e reinicie o Unbound:
   ```bash
   cd ~/workspace/services/unbound
   docker compose restart unbound
   ```

**Resolução Definitiva**:
Configure o NTP do OpenWRT/FriendlyWrt para sincronizar usando endereços IP diretos de servidores NTP públicos, contornando a necessidade de DNS no boot:
```bash
uci add_list system.ntp.server='200.160.7.186'   # a.st1.ntp.br
uci add_list system.ntp.server='200.189.40.8'    # c.st1.ntp.br
uci add_list system.ntp.server='162.159.200.1'   # time.cloudflare.com
uci commit system
/etc/init.d/sysntpd restart
```
