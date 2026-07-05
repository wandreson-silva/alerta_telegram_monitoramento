# alerta_telegram_monitoramento
```text
alerta_telegram.sh, um script híbrido. Quando o PSAD chamar o script, ele envia o alerta de port scan; quando o sistema de autenticação do Linux (PAM) chamar o script, ele identifica se foi uma tentativa ou um acesso SSH bem-sucedido de um IP externo.

O script de instalação. Ele já configura o PSAD, as regras do iptables e injeta os gatilhos de monitoramento diretamente no ecossistema do SSH (/etc/pam.d/sshd).

```
```text
Este script em Bash é uma solução leve e automatizada para Monitoramento e Resposta a Incidentes em servidores Linux (como o Kali Linux or Ubuntu). Ele atua como um "dedo-duro" em tempo real, integrando o detector de varredura de portas PSAD (Port Scan Attack Detector) e o sistema de autenticação nativo do Linux PAM (Pluggable Authentication Modules) para enviar alertas instantâneos diretamente para um bot do Telegram.
```
```ruby
#!/bin/bash

# CONFIGURAÇÕES DO TELEGRAM
BOT_TOKEN="COLE_SEU_TOKEN_AQUI"
CHAT_ID="COLE_SEU_CHAT_ID_AQUI"

# Garantir que o script rode como root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Por favor, execute este script como root (sudo)."
  exit 1
fi

# Atualiza pacotes e instala dependências
echo "[+] Instalando dependências..."
apt update && apt install -y psad iptables-persistent curl rsyslog

# Adiciona regras de log do iptables no TOPO
echo "[+] Configurando iptables para o PSAD..."
iptables -I INPUT 1 -p tcp --syn -j LOG --log-prefix "psad: "
iptables -I FORWARD 1 -p tcp --syn -j LOG --log-prefix "psad: "
iptables-save > /etc/iptables/rules.v4

# Cria o script de alerta híbrido (PSAD + SSH)
echo "[+] Criando script de alerta híbrido para Telegram..."
cat << 'EOF' > /usr/local/bin/alerta_telegram.sh
#!/bin/bash

# Caminhos absolutos indispensáveis para execução via daemons
CURL_BIN="/usr/bin/curl"
HOSTNAME_BIN="/usr/bin/hostname"
DATE_BIN="/usr/bin/date"

HOST=$($HOSTNAME_BIN)
DATA=$($DATE_BIN "+%Y-%m-%d %H:%M:%S")
TOKEN="TOKEN_REPLACE"
CHAT="CHAT_REPLACE"

# --- MÓDULO 1: SE FOR CHAMADO PELO SSH (PAM) ---
if [ -n "$PAM_TYPE" ]; then
    # Ignora conexões locais (localhost) e encerramento de sessões (logout)
    if [ "$PAM_TYPE" = "close_session" ] || [ "$PAM_RHOST" = "127.0.0.1" ] || [ "$PAM_RHOST" = "::1" ] || [ -z "$PAM_RHOST" ]; then
        exit 0
    fi

    # Cenário A: Tentativa de login (Autenticação em andamento)
    if [ "$PAM_TYPE" = "auth" ]; then
        MENSAGEM="🔑 *Tentativa de Conexão SSH* 🔑
- *Host:* $HOST
- *Data:* $DATA
- *Usuário Usado:* \`$PAM_USER\`
- *IP de Origem:* \`$PAM_RHOST\`
- *Status:* Credenciais enviadas (Aguardando validação)"

    # Cenário B: Login bem-sucedido (Sessão aberta)
    elif [ "$PAM_TYPE" = "open_session" ]; then
        MENSAGEM="🟢 *Acesso SSH Bem-Sucedido!* 🟢
- *Host:* $HOST
- *Data:* $DATA
- *Usuário Autenticado:* \`$PAM_USER\`
- *IP de Origem:* \`$PAM_RHOST\`
- *Status:* Usuário logado no sistema!"
    else
        exit 0
    fi

# --- MÓDULO 2: SE FOR CHAMADO PELO PSAD (PORT SCAN) ---
else
    MENSAGEM="⚠️ *Alerta de Segurança (PSAD)* ⚠️
- *Host:* $HOST
- *Data:* $DATA
- *Evento:* Possível varredura de portas (Port Scan) detectada!"
fi

# --- ENVIO COMPARTILHADO ---
$CURL_BIN -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d chat_id="$CHAT" \
    -d parse_mode="Markdown" \
    -d text="$MENSAGEM"
EOF

# Injeta os tokens reais dentro do script gerado
sed -i "s/TOKEN_REPLACE/$BOT_TOKEN/g" /usr/local/bin/alerta_telegram.sh
sed -i "s/CHAT_REPLACE/$CHAT_ID/g" /usr/local/bin/alerta_telegram.sh
chmod +x /usr/local/bin/alerta_telegram.sh

# Configura psad (.conf)
echo "[+] Configurando psad.conf..."
sed -i "s/^EMAIL_ADDRESSES.*/EMAIL_ADDRESSES root@localhost;/g" /etc/psad/psad.conf
sed -i "s/^HOSTNAME.*/HOSTNAME $(hostname);/g" /etc/psad/psad.conf
sed -i "s|^ENABLE_EXT_SCRIPT_EXEC.*|ENABLE_EXT_SCRIPT_EXEC      Y;|g" /etc/psad/psad.conf
sed -i "s|^EXTERNAL_SCRIPT.*|EXTERNAL_SCRIPT             /usr/local/bin/alerta_telegram.sh;|g" /etc/psad/psad.conf

# Configura gatilhos no PAM do SSH (Evita duplicidade se rodar o script de novo)
echo "[+] Configurando gatilhos de segurança no PAM do SSH..."
if ! grep -q "alerta_telegram.sh" /etc/pam.d/sshd; then
    # Ativa o alerta no momento da tentativa de digitação da senha
    echo "auth optional pam_exec.so /usr/local/bin/alerta_telegram.sh" >> /etc/pam.d/sshd
    # Ativa o alerta no momento em que o login é aceito
    echo "session optional pam_exec.so /usr/local/bin/alerta_telegram.sh" >> /etc/pam.d/sshd
fi

# Reinicia os serviços e atualiza assinaturas
echo "[+] Reiniciando serviços e atualizando assinaturas..."
psad --sig-update
systemctl restart rsyslog psad ssh

echo "[✔] Instalação e configuração concluídas com sucesso!"
echo "[🛡️] Sistema protegido contra Port Scans e monitorando acessos SSH externos!"
```

# Como a mágica do SSH funciona por baixo dos panos?
```text

Quando alguém tenta se conectar via SSH, o serviço consulta o arquivo /etc/pam.d/sshd.O Linux usa o módulo pam_exec.so para rodar o script,injetando variáveis nativas do sistema nele:

* $PAM_RHOST: Contém o IP de quem está tentando conectar (o script filtra e ignora se for o seu próprio 127.0.0.1).

* $PAM_USER: O nome de usuário que a pessoa digitou.

* $PAM_TYPE: Diz a fase da conexão. Se for auth, a pessoa acabou de dar Enter no usuário e está testando uma senha. Se for open_session, a senha estava certa e ela acabou de ganhar acesso ao terminal do seu Kali.

```
# Principais Recursos

```text
1.Monitoramento Híbrido: O mesmo script atende a dois daemons diferentes (PSAD e PAM-SSH) sem conflito de código.

2.Detecção de Port Scan: Integra-se ao PSAD para alertar quando um atacante executa varreduras de portas invasivas (como nmap -sS ou nmap -A).

3.Inteligência em Conexões SSH: * Identifica tentativas de login (quando o atacante digita o usuário e está testando a senha).

4.Identifica sucessos de login (quando um acesso é estabelecido).

5.Filtro Anti-Spam Inteligente: Ignora automaticamente conexões originadas de localhost (127.0.0.1 e ::1) e eventos de encerramento de sessão (logout), evitando notificações redundantes.

6.Compatibilidade com Daemons: Desenvolvido utilizando caminhos absolutos de binários (/usr/bin/curl, etc.), garantindo execução perfeita em segundo plano, onde variáveis de ambiente de terminais interativos não estão disponíveis.

```

# Como Funciona? (Arquitetura)

## 1. Fluxo do Módulo SSH (PAM)
```text
O comportamento do script é determinado dinamicamente pelas variáveis de ambiente injetadas no momento da sua execução:

Quando alguém interage com a porta 22 (SSH), o arquivo /etc/pam.d/sshd invoca o script passando variáveis nativas do sistema. O script faz a seguinte triagem:

[Variável PAM]     [Valor Capturado]    [Ação do Script]
$PAM_TYPE -         auth -    Dispara o alerta de Tentativa de Conexão

$PAM_TYPE -         open_session -      Dispara o alerta de Acesso Bem-Sucedido

$PAM_TYPE -         close_session -     Encera silenciosamente (exit 0)

$PAM_RHOST -        127.0.0.1 / ::1 -   Encera silenciosamente (Ignora conexões locais)

```

# 2. Fluxo do Módulo Port Scan (PSAD)
```text

Se o script for chamado e a variável $PAM_TYPE estiver vazia, significa que o gatilho não veio do SSH. O script assume que foi invocado pela diretiva EXTERNAL_SCRIPT do PSAD, gerando o alerta de varredura de portas do iptables.

Exemplo dos Alertas Gerados no Telegram:

⚠️ Alerta de Segurança (PSAD) ⚠️

Host: kali-server

Data: 2026-07-02 17:45:12

Evento: Possível varredura de portas (Port Scan) detectada!

🔑 Tentativa de Conexão SSH 🔑

Host: kali-server

Data: 2026-07-02 17:46:01

Usuário Usado: root

IP de Origem: 192.168.1.9

Status: Credenciais enviadas (Aguardando validação)

🟢 Acesso SSH Bem-Sucedido! 🟢

Host: kali-server

Data: 2026-07-02 17:46:05

Usuário Autenticado: kali

IP de Origem: 192.168.1.9

Status: Usuário logado no sistema!
```

# 3. Requisitos de Instalação

```text
1. Regras de LOG no iptables no topo das chains de INPUT e FORWARD contendo o prefixo "psad: ".

2. PSAD configurado com as diretivas ENABLE_EXT_SCRIPT_EXEC Y; e apontando para este script em EXTERNAL_SCRIPT.

3. Módulo pam_exec.so configurado nas linhas de auth e session dentro de /etc/pam.d/sshd.
```
