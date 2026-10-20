# 🛡️ CrowdSec Security Engine (Docker)

Mecanismo colaborativo de detecção e defesa contra ameaças para o Homelab, executado em container Docker dentro do LXC **`harden`** (`10.10.10.27`), ao lado do **Caddy**.

---

## 📐 Como Funciona

```mermaid
graph LR
    User[Tráfego Externo / LAN] --> Caddy[Caddy Reverse Proxy]
    Caddy -->|Escreve logs JSON| LogFile[/var/log/caddy/access.log]
    LogFile -->|Lê e analisa em tempo real| CrowdSec[CrowdSec Engine]
    CrowdSec -->|Detecta Força Bruta / Scans / CVEs| Decisions[Decisões de Bloqueio]
    CrowdSec <-->|Troca reputação de IPs| Community[CrowdSec Community Consensus]
```

O CrowdSec lê os logs de acesso gerados pelo Caddy e os logs de autenticação do sistema (`auth.log`), detectando:
* Tentativas de força bruta no SSH.
* Varreduras de portas e caminhos web conhecidos (`.env`, `wp-login.php`, `phpmyadmin`, etc.).
* Ataques de injeção e exploração de CVEs em serviços web (Jellyfin, Proxmox, etc.).

---

## 🚀 Como Iniciar no `harden`

### 1. Copiar a pasta para o container
A partir do seu PC (diretório `services`):
```bash
scp -r /home/juca/Documents/workspace/lab/services/crowdsec juca@10.10.10.27:~/workspace/services/
```

### 2. Iniciar o container
Conectado via SSH no `harden` (`ssh juca@10.10.10.27`):
```bash
cd ~/workspace/services/crowdsec
docker compose up -d
```

---

## 🔍 Comandos Úteis do CrowdSec (`cscli`)

Para inspecionar o status e as decisões de segurança diretamente no container:

* **Ver métricas de leitura e processamento de logs:**
  ```bash
  docker compose exec crowdsec cscli metrics
  ```

* **Listar alertas de ataques detectados:**
  ```bash
  docker compose exec crowdsec cscli alerts list
  ```

* **Listar IPs atualmente bloqueados/banidos:**
  ```bash
  docker compose exec crowdsec cscli decisions list
  ```

* **Banir manualmente um IP suspeito por 24 horas:**
  ```bash
  docker compose exec crowdsec cscli decisions add --ip 192.168.1.50 --duration 24h --reason "Tentativa de invasao"
  ```

* **Desbanir um IP:**
  ```bash
  docker compose exec crowdsec cscli decisions delete --ip 192.168.1.50
  ```
