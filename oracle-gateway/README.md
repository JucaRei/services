# Oracle Cloud Gateway (Podman Rootless + Nginx + Certbot + Rathole Server + CrowdSec)

Stack padronizada para execução via **Podman Rootless** na VPS **Oracle Cloud Infrastructure (OCI) Always Free** (ARM64 `aarch64`), atuando como gateway de borda seguro para o homelab.

---

## 1. Visão Geral da Arquitetura

```text
[ Usuário na Internet ]
         │ (HTTPS / Porta 443 e HTTP / Porta 80)
         ▼
[ VPS Oracle Cloud - 155.181.176.184 ]
   ├── Host Kernel (Nativo)
   │     └── WireGuard (wg-quick@wg0) -> VPN ponto-a-ponto para nós internos / Gluetun
   │
   └── Podman 5.7.0 Rootless (Backend 'pasta' - Preserva IP Real)
         ├── CrowdSec IPS -> Análise e bloqueio em tempo real
         ├── Nginx (nginx-proxy) -> Terminação SSL (Let's Encrypt) e Proxy Reverso
         ├── Certbot -> Emissão e renovação automática ACME HTTP-01
         └── Rathole Server -> Escuta pública na porta TCP 2333 (Túnel seguro com Noise)
                   │
                   │ (Túnel L4 encriptado sobre TCP 2333 - Protocolo Noise)
                   ▼
[ Homelab (Soyoz Proxmox 10.10.10.5 / 10.10.10.139) ]
   └── Rathole Client (rathole-client)
         └── Entrega a conexão localmente para o Jellyfin (10.10.10.139:3545)
```

### Principais Vantagens:
* **Zero portas abertas no seu provedor de internet residencial (bypassa CGNAT)**.
* **Segurança máxima:** A porta 8096 do Rathole não é exposta na internet da VPS; apenas o Nginx conversa com ela via rede interna do gateway.
* **Podman Rootless com `pasta`:** Containers rodam sem privilégios de `root`, preservando o IP de origem dos visitantes sem SNAT artificial (essencial para o CrowdSec).
* **Protocolo Noise no Rathole:** Criptografia ponta a ponta com curvas elípticas (Curve25519) e ChaCha20-Poly1305.
* **WireGuard Nativo no Host:** VPN roda no kernel do host (`wg-quick@wg0`), evitando overhead de userspace e mantendo total compatibilidade com `iptables MASQUERADE` na interface `enp0s6`.

---

## 2. Estrutura de Arquivos

```text
oracle-gateway/
├── Containerfile.rathole   # Build multi-arch (ARM64/x86_64) oficial do Rathole
├── docker-compose.yaml     # Orquestração da stack Podman Rootless (Rathole, Nginx, Certbot, CrowdSec)
├── server.toml             # Configuração sensível do Rathole Server (ignorado no Git)
├── server.toml.example     # Modelo de configuração com protocolo Noise
├── nginx/
│   └── default.conf        # Proxy reverso, headers de segurança e SSL
├── certbot/
│   ├── conf/               # Certificados Let's Encrypt gerados
│   └── www/                # Webroot para validação de desafio ACME HTTP-01
├── crowdsec/               # Configuração e banco de dados do CrowdSec
└── README.md               # Este guia passo a passo
```

---

## 3. Passo a Passo de Implantação na VPS Oracle

### Passo 1: Liberar o Firewall (VCN da Oracle e iptables da VPS)

1. **No painel web da Oracle (OCI Console):**
   * Vá em: `Networking > Virtual Cloud Networks > sua VCN > Security Lists > Default Security List`.
   * Adicione em **Ingress Rules**:
     * **Source CIDR:** `0.0.0.0/0` | **Protocol:** `TCP` | **Ports:** `80, 443, 2333`

2. **No terminal SSH da VPS (Inserir no topo do INPUT para evitar REJECT pré-existente):**
   ```bash
   sudo iptables -I INPUT 1 -p tcp -m multiport --dports 80,443,2333 -j ACCEPT
   sudo iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT
   sudo netfilter-persistent save
   ```

---

### Passo 2: Copiar ou Atualizar os arquivos na VPS

No terminal da VPS (ou via git pull no repositório):

```bash
cd ~/services/oracle-gateway
git pull
```

---

### Passo 3: Emitir o Primeiro Certificado SSL com Podman

O Nginx precisa que o arquivo de certificado já exista para iniciar. Execute este comando único para obter o certificado inicial via Certbot standalone com Podman rootless:

*(Certifique-se de que nada esteja usando a porta 80 na VPS antes de rodar)*:

```bash
cd ~/services/oracle-gateway

podman run -it --rm \
  -p 80:80 \
  -v $(pwd)/certbot/conf:/etc/letsencrypt:Z \
  certbot/certbot certonly --standalone \
  -d jucalab.duckdns.org \
  --register-unsafely-without-email --agree-tos
```

> **Critério de Sucesso:** A saída deve exibir:
> `Successfully received certificate.`
> Os arquivos `fullchain.pem` e `privkey.pem` serão salvos em `certbot/conf/live/jucalab.duckdns.org/`.

---

### Passo 4: Subir a Stack Completa no Podman Rootless

Com o certificado emitido e o `server.toml` configurado, inicie os serviços:

```bash
podman-compose up -d
```

Verifique se todos os containers subiram:

```bash
podman ps
```
Todos devem estar com status **Up**:
* `rathole-server` (escutando na porta 2333)
* `nginx-proxy` (escutando nas portas 80 e 443)
* `certbot-renew` (em loop de verificação para renovação a cada 12 horas)
* `crowdsec` (monitorando os logs do Nginx)

---

## 4. Conectando o Homelab (NanoPi / Dockhand)

1. No seu **Dockhand** (ou no terminal do homelab em `services/rathole/client`):
   ```bash
   docker compose up -d
   ```
2. Inspecione os logs do cliente:
   ```bash
   docker compose logs -f
   ```
3. Assim que aparecer `[INFO] Connected to remote jucalab.duckdns.org:2333`, o túnel está estabelecido!

---

## 5. Como Testar

1. Pegue um celular fora da rede Wi-Fi (usando a rede móvel 4G/5G).
2. Abra o navegador e acerte a URL:
   ```
   https://jucalab.duckdns.org
   ```
3. O Jellyfin deve carregar perfeitamente com o cadeado verde HTTPS (Let's Encrypt).

---

## 6. Comandos Úteis e Manutenção

* **Ver logs do Nginx em tempo real:**
  ```bash
  docker compose logs -f nginx
  ```
* **Ver conexões ativas no Rathole:**
  ```bash
  docker compose logs -f rathole-server
  ```
* **Testar renovação de certificado a seco (dry-run):**
  ```bash
  docker compose run --rm certbot renew --dry-run
  ```
* **Recarregar Nginx após alterações de config sem parar o container:**
  ```bash
  docker compose exec nginx nginx -s reload
  ```

---

## 7. Como Adicionar Novos Serviços no Futuro

Para expor outro serviço (ex: um painel web na porta 8080 do host local):

1. **No `server.toml` (Oracle):**
   ```toml
   [server.services.meu_painel]
   type = "tcp"
   bind_addr = "0.0.0.0:8080"
   ```
2. **No `nginx/default.conf` (Oracle):** Adicione um novo `server { ... }` com outro subdomínio ou um novo bloco `location /painel { proxy_pass http://rathole-server:8080; }`.
3. **No `client.toml` (Homelab):**
   ```toml
   [client.services.meu_painel]
   type = "tcp"
   local_addr = "10.10.10.X:8080"
   ```
4. Reinicie as stacks (`docker compose restart`).

