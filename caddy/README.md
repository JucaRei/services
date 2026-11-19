# 🔒 Gateway Reverso & WAF: Caddy + CrowdSec Bouncer (Docker)

Stack unificada de Proxy Reverso HTTPS e Sistema de Proteção Ativa (WAF em tempo real) para o Homelab, executada dentro do LXC **`harden`** (`10.10.10.27`).

---

## 📐 Fluxo de Tráfego e Proteção em Tempo Real

```mermaid
graph LR
    User[Cliente Web / Jellyfin App] -->|Requisição HTTP/S| Caddy[Caddy Reverse Proxy]
    Caddy <-->|Consulta em memória 0ms| Bouncer[CrowdSec Bouncer Plugin]
    Bouncer <-->|Sincroniza decisões / LAPI| CrowdSec[CrowdSec Engine]
    Caddy -->|Se seguro: Reverse Proxy| Jellyfin[Jellyfin 10.10.10.139:3545]
    Caddy -.->|Se malicioso: 403 Forbidden| Drop[Bloqueio Instantâneo]
    Caddy -.->|Gera Logs JSON| LogFile[/logs/access.log]
    LogFile -.->|Leitura contínua| CrowdSec
```

---

## 📁 Estrutura de Arquivos

```text
caddy/
├── Dockerfile              # Build do Caddy com o plugin caddy-crowdsec-bouncer
├── docker-compose.yaml     # Orquestração do Caddy + CrowdSec (LAPI :8080 + Syslog UDP :514)
├── .env                    # Chave de API de comunicação interna (CROWDSEC_API_KEY)
├── Caddyfile               # Configuração do proxy e diretivas do bouncer
├── acquis.yaml             # Mapeamento de logs para o CrowdSec (Caddy, host e Syslog OpenWrt)
├── data/                   # Certificados SSL / TLS do Caddy
├── config/                 # Estado interno do Caddy
└── crowdsec/
    ├── config/             # Parsers e cenários baixados pelo CrowdSec (inclui dropbear-logs)
    └── data/               # Banco SQLite com reputação e decisões
```

> [!TIP]
> **Proteção do eMMC (NanoPi R3S):** Os logs de acesso do Caddy são gerados dentro de um volume `tmpfs` (RAM Disk) de 16 MB. Além disso, o CrowdSec recebe os logs do OpenWrt via **Syslog UDP (:514)** diretamente em memória RAM. Isso significa **zero gravações na memória flash eMMC**, máxima performance e monitoramento unificado do gateway e do roteador.

---

## 🚀 Passo a Passo de Implantação no `harden` (10.10.10.27)

### 1. Sincronizar os arquivos para o container:
A partir do seu PC:
```bash
rsync -avz --delete /media/juca/SharedData1/workspace/services/caddy/ juca@10.10.10.27:~/workspace/services/caddy/
```

### 2. Construir e Iniciar os Containers:
No SSH do `harden` (`ssh juca@10.10.10.27`):
```bash
cd ~/workspace/services/caddy

# Constrói o Caddy com o plugin do bouncer e sobe a stack:
docker compose build
docker compose up -d
```

### 3. Registrar o Bouncer no CrowdSec (Passo Único):
Como o arquivo `.env` já contém uma chave gerada, registre o bouncer no CrowdSec com essa mesma chave:
```bash
docker compose exec crowdsec cscli bouncers add caddy-bouncer -k 36d1f5e8e1554fcd0451859d66bc95d0
```

> **Verificação:** Para confirmar que o bouncer está conectado e ativo:
> ```bash
> docker compose exec crowdsec cscli bouncers list
> ```
> O `caddy-bouncer` aparecerá listado como conectado e validado!

### 4. Reiniciar o Caddy para carregar o bouncer:
```bash
docker compose restart caddy
docker compose logs -f caddy
```
Deverá exibir `crowdsec: successfully connected to LAPI`.

---

## 🔍 Comandos Úteis do CrowdSec (`cscli`)

* **Listar bouncers ativos:**
  ```bash
  docker compose exec crowdsec cscli bouncers list
  ```

* **Testar um bloqueio em tempo real (banir um IP de teste):**
  ```bash
  docker compose exec crowdsec cscli decisions add --ip 192.168.1.100 --duration 10m --reason "Teste WAF"
  ```

* **Ver lista de decisões ativas:**
  ```bash
  docker compose exec crowdsec cscli decisions list
  ```

* **Desbanir um IP:**
  ```bash
  docker compose exec crowdsec cscli decisions delete --ip 192.168.1.100
  ```

* **Métricas de requisições e bloqueios:**
  ```bash
  docker compose exec crowdsec cscli metrics
  ```

* **Liberar espaço em disco após o build (Limpeza de Cache do BuildKit):**
  ```bash
  # Remove o cache de compilação do Go e imagens intermediárias (~800MB a 1.2GB liberados):
  docker builder prune -a -f
  docker image prune -f
  docker rmi caddy:builder-alpine 2>/dev/null || true
  docker system df
  ```
