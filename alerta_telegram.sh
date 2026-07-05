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