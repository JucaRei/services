# Oracle Cloud Gateway (Nginx + Certbot + Rathole Server)

Stack padronizada em Docker Compose para atuar como gateway de entrada público para o homelab através de uma VPS **Oracle Cloud Infrastructure (OCI) Always Free**.

---

## 1. Visão Geral da Arquitetura

```
[ Usuário na Internet ]
         │ (HTTPS / Porta 443)
         ▼
[ VPS Oracle Cloud ]
   ├── Nginx (nginx-proxy)
   │     └── Terminação SSL puro (Certbot / Let's Encrypt)
   │     └── Proxy reverso para http://rathole-server:8096 (rede interna docker)
   │
   └── Rathole Server (rathole-server)
         └── Escuta pública na porta TCP 2333 (túnel seguro com o homelab)
         │
         │ (Túnel L4 encriptado sobre TCP 2333)
         ▼
[ Homelab (NanoPi R3S / Dockhand no helper 10.10.10.135) ]
   └── Rathole Client (rathole-client)
         └── Entrega a conexão localmente para o Jellyfin (10.10.10.139:3545)
```

### Principais Vantagens:
* **Zero portas abertas no seu provedor de internet residencial (bypassa CGNAT)**.
* **Segurança máxima:** A porta 8096 do Rathole não é exposta na internet da VPS; apenas o Nginx conversa com ela via rede Docker interna.
* **Certificados SSL puros:** Gerenciados e renovados automaticamente pelo Certbot oficial via webroot.
* **Consumo ultraleve:** Nginx + Certbot + Rathole consomem menos de 60 MB de RAM na VPS da Oracle.

---

## 2. Estrutura de Arquivos

```text
oracle-gateway/
├── docker-compose.yaml     # Orquestração dos 3 containers (Nginx, Certbot, Rathole)
├── server.toml             # Configuração dos serviços e portas do Rathole Server
├── nginx/
│   └── default.conf        # Configuração do proxy reverso, headers e SSL
├── certbot/
│   ├── conf/               # Certificados e chaves geradas pelo Let's Encrypt
│   └── www/                # Desafio ACME HTTP-01 para renovação automática
└── README.md               # Este guia passo a passo
```

---

## 3. Passo a Passo de Implantação na VPS Oracle

### Passo 1: Liberar o Firewall (VCN da Oracle e iptables da VPS)

1. **No painel web da Oracle (OCI Console):**
   * Vá em: `Networking > Virtual Cloud Networks > sua VCN > Security Lists > Default Security List`.
   * Adicione em **Ingress Rules**:
     * **Source CIDR:** `0.0.0.0/0` | **Protocol:** `TCP` | **Ports:** `80, 443, 2333`

2. **No terminal SSH da VPS:**
   ```bash
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 2333 -j ACCEPT
   sudo netfilter-persistent save 2>/dev/null || sudo apt install iptables-persistent -y
   ```

---

### Passo 2: Copiar os arquivos para a VPS

No terminal da VPS (ou via `rsync`/`scp` a partir da sua máquina):

```bash
mkdir -p ~/services/oracle-gateway
```
Copie a pasta `oracle-gateway` para a sua VPS em `~/services/oracle-gateway`.

---

### Passo 3: Emitir o Primeiro Certificado SSL

O Nginx precisa que o arquivo de certificado já exista para iniciar. Execute este comando único para obter o certificado inicial via Certbot standalone:

*(Certifique-se de que nada esteja usando a porta 80 na VPS antes de rodar)*:

```bash
cd ~/services/oracle-gateway

docker run -it --rm \
  -p 80:80 \
  -v $(pwd)/certbot/conf:/etc/letsencrypt \
  certbot/certbot certonly --standalone \
  -d jucalab.duckdns.org \
  --register-unsafely-without-email --agree-tos
```

> **Critério de Sucesso:** A saída deve exibir:
> `Successfully received certificate.`
> Os arquivos `fullchain.pem` e `privkey.pem` serão salvos em `certbot/conf/live/jucalab.duckdns.org/`.

---

### Passo 4: Subir a Stack Completa

Com o certificado emitido, inicie todos os serviços:

```bash
docker compose up -d
```

Verifique se todos os containers subiram:

```bash
docker compose ps
```
Todos devem estar com status **Up**:
* `rathole-server` (escutando na porta 2333)
* `nginx-proxy` (escutando nas portas 80 e 443)
* `certbot-renew` (em loop de verificação para renovação a cada 12 horas)

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

