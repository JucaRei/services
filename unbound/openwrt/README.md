# 🛡️ OpenWRT / FriendlyWrt 24.10 - Guia de Configuração e Backup

Repositório de backup comentado e documentado de todas as configurações do roteador **NanoPi R3S** (FriendlyWrt / OpenWrt 24.10) integrado aos containers **LXC** (`dns01`, `dns02`, `unbound`).

---

## 📁 Índice dos Arquivos de Configuração (`/etc/config/`)

| Arquivo | Descrição | O que foi Otimizado / Melhorado |
|---|---|---|
| [**`wireless`**](wireless) | Wi-Fi 5GHz (Comfast), 2.4GHz Wi-Fi 6 (Edup) e Mesh 802.11s | 802.11r/k/v (Fast Roaming), canal 153 limpo, WPA2/WPA3 misto, DTIM 3 |
| [**`dhcp`**](dhcp) | Servidor DHCP, Dnsmasq e odhcpd | Sem vazamento IPv6 (`dns_service '0'`), `strict_order '1'`, comentários UCI válidos |
| [**`network`**](network) | Interfaces de rede (`lan`, `wan` PPPoE, `wan6`, bridge `br-lan`) | DNS fallback `1.1.1.1` para o roteador, `peerdns '0'`, MTU 1492 |
| [**`firewall`**](firewall) | Regras de firewall (`fw4` / nftables) | Bloqueio de DNS externo na WAN (Chromecast/FireTV forçados no Technitium) |
| [**`system`**](system) | Sistema, fuso horário e NTP | IPs numéricos diretos (NTP.br e Cloudflare) para eliminar deadlocks pós-queda de energia |
| [**`lxc-auto`**](lxc-auto) | Inicialização automática dos containers no boot | `autostart '1'` nos containers `dns01`, `dns02` e `unbound` |
| [**`dropbear`**](dropbear) | Servidor de acesso remoto SSH | Porta 22, autenticação segura com chave ou senha |
| [**`uhttpd`**](uhttpd) | Servidor Web da interface gráfica LuCI | Portas 80/443, certificado TLS em Curva Elíptica (P-256), proteção RFC1918 |

---

## 📡 Detalhes e Dicas do Wi-Fi ([`wireless`](wireless))

Sua configuração sem fio está muito bem estruturada utilizando adaptadores USB dedicados:
* **Rede 5GHz (`radio0` - Comfast)**: 
  * Canal **153** (faixa UNII-3: 149 a 165), que opera com potência total sem restrição de DFS (radares de aeroportos/meteorologia).
  * Largura de **80MHz (VHT80)** entregando até 867 Mbps teóricos.
* **Rede 2.4GHz (`radio1` - Edup)**:
  * Canal **11** no padrão moderno **Wi-Fi 6 (HE20)**, ideal para estabilidade de dispositivos móveis e IoT.
* **Fast Roaming (802.11r / 802.11k / 802.11v)**:
  * Ambas as redes compartilham o mesmo `mobility_domain 'e1a1'`. Celulares e notebooks transitam de 5GHz para 2.4GHz instantaneamente ao andar pela casa, sem queda de sinal ou buffering em chamadas.
* **Rede Mesh (`mesh5g`)**:
  * Padrão 802.11s com criptografia SAE (WPA3) para interligar outros pontos da malha sem fio.

---

## 🔄 Como Restaurar as Configurações no Roteador

Se você reinstalar ou resetar o NanoPi R3S, basta enviar os arquivos desta pasta para o roteador via `scp`:

```bash
# Executado a partir do seu PC (na pasta services/unbound/openwrt):
scp wireless dhcp network firewall system lxc-auto dropbear uhttpd root@10.10.10.1:/etc/config/

# Em seguida, no terminal do OpenWrt, reinicie os serviços essenciais:
ssh root@10.10.10.1
/etc/init.d/sysntpd restart
/etc/init.d/dnsmasq restart
/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/uhttpd restart
/etc/init.d/lxc-auto restart
wifi reload
```

---

## 💡 Próximas Recomendações de Melhoria

1. **Restringir SSH apenas por Chave Pública (`authorized_keys`)**:
   Depois de copiar sua chave SSH para `/etc/dropbear/authorized_keys`, altere no [`dropbear`](dropbear) a opção `RootPasswordAuth` para `'off'` para blindar contra tentativas de invasão por senha.
2. **Forçar HTTPS no LuCI ([`uhttpd`](uhttpd))**:
   Se quiser que o navegador sempre abra o painel web de forma criptografada, altere `option redirect_https '1'`.
3. **Limite de Memória no LXC (Cgroups v2)**:
   Adicione tetos de memória (`lxc.cgroup2.memory.max`) em `/opt/lxc/*/config` para proteger a RAM de 2GB do NanoPi R3S contra possíveis vazamentos de memória de containers de mídia (como Jellyfin e Transmission).
