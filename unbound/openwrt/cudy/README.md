# 📡 Cudy - Ponto de Acesso & Nó Mesh Secundário (OpenWrt)

Documentação e backup das configurações do roteador **Cudy** (`10.10.10.45`), atuando como Ponto de Acesso / Extensor Mesh integrado ao roteador principal **NanoPi R3S** (`10.10.10.1`).

---

## 📐 Papel na Rede

* **Modo de Operação**: Ponto de Acesso Puro (*Dumb AP / Mesh Satellite*).
* **IP de Gerência**: `10.10.10.45` (estático na bridge `br-lan`).
* **Gateway**: `10.10.10.1` (NanoPi R3S).
* **Servidores DNS**: `10.10.10.25` e `10.10.10.26` (Technitium DNS).
* **Switch Gigabit**: As 3 portas LAN e a porta WAN física estão unificadas na mesma bridge (`br-lan`), fornecendo 4 portas cabeadas locais.

---

## 📶 Estratégia de Wi-Fi e Roaming

| Rádio | Frequência | Canal | Largura | Papel / Configuração |
| :--- | :--- | :---: | :---: | :--- |
| **`radio0`** | 2.4 GHz | **1** | HE20 | **Canal 1** não colide com o **Canal 11** do NanoPi, garantindo dobro de capacidade sem interferência mútua. |
| **`radio1`** | 5 GHz | **153** | HE80 | Pareado no **Canal 153** para fechar o enlace de *backhaul* Mesh 802.11s (`mesh-juca`) com o NanoPi. |

### Fast Roaming (802.11r / 802.11k / 802.11v)
* Ambos os roteadores compartilham o mesmo `mobility_domain 'e1a1'`, mesmas senhas WPA2/WPA3 e `disassoc_low_ack '1'`.
* Celulares e notebooks transitam de um roteador para o outro instantaneamente ao andar pela casa.

---

## 🚫 Serviços Desativados (Prevenção de Conflitos)

1. **DHCPv4 e DHCPv6/RA Desativados**: Apenas o NanoPi distribui IPs e rotas na rede.
2. **Firewall Desativado**: Elimina duplo processamento de pacotes na rede local e poupa ciclos de CPU/RAM do Cudy.
3. **Interfaces WAN/WAN6 Removidas**: A porta WAN física agora é uma porta LAN comum.
