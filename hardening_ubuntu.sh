#!/bin/bash

# =========================================
# ============ PRIMER SCRIPT =============
# =========================================

SSH_CONFIG="/etc/ssh/sshd_config"
DEFAULT_USER="adminuser"
PASSWORD_LENGTH=12
BACKUP_FILE="${SSH_CONFIG}.bak"

#Actualización de sistema e Instalación de servicios SSH
apt update && apt upgrade -y
apt install -y openssh-server
systemctl enable ssh
systemctl start ssh

# Establecer los parámetros en sshd_config
set_sshd_option() {
    local option="$1"
    local value="$2"
    if grep -q "^${option}" "$SSH_CONFIG"; then
        sed -i "s/^${option}.*/${option} ${value}/" "$SSH_CONFIG"
    elif grep -q "^#${option}" "$SSH_CONFIG"; then
        sed -i "s/^#${option}.*/${option} ${value}/" "$SSH_CONFIG"
    else
        echo "${option} ${value}" >> "$SSH_CONFIG"
    fi
}

# Verifica si hay al menos un usuario con sudo
check_sudo_user() {
    getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | head -n1
}

# Crea un usuario con sudo si no existe ninguno
ensure_sudo_user() {
    local sudo_user
    sudo_user=$(check_sudo_user)

    if [ -z "$sudo_user" ]; then
        echo "[!] No se encontraron usuarios con acceso sudo. Se creará uno nuevo: $DEFAULT_USER"

        PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c $PASSWORD_LENGTH)
        useradd -m -s /bin/bash "$DEFAULT_USER"
        echo "${DEFAULT_USER}:${PASSWORD}" | chpasswd
        usermod -aG sudo "$DEFAULT_USER"

        echo "[+] Usuario '${DEFAULT_USER}' creado con contraseña: ${PASSWORD}"
        echo "[+] Asegúrate de guardar esta contraseña en un lugar seguro."
        sudo_user="$DEFAULT_USER"
    else
        echo "[+] Se encontró usuario con privilegios sudo: $sudo_user"
    fi
}

# Validación de sintaxis SSH
validate_sshd() {
    if ! sshd -t 2>/dev/null; then
        echo "[!] Error en la configuración de SSH. Revirtiendo cambios..."
        if [ -f "$BACKUP_FILE" ]; then
            cp "$BACKUP_FILE" "$SSH_CONFIG"
            echo "[+] Se restauró el archivo sshd_config original."
        else
            echo "[!] No se encontró el archivo de respaldo. Reversión no posible."
        fi
        restart_ssh_service
        exit 1
    fi
}

# Reinicia servicio SSH
restart_ssh_service() {
    if systemctl list-units --type=service | grep -q 'sshd.service'; then
        systemctl restart sshd
    elif systemctl list-units --type=service | grep -q 'ssh.service'; then
        systemctl restart ssh
    else
        echo "[!] No se encontró el servicio SSH. Revisa manualmente si es un contenedor o sistema minimalista."
        exit 1
    fi
}

# INICIO PRIMER SCRIPT
echo "[+] Iniciando verificación de usuarios con sudo..."
ensure_sudo_user

if [ -f "$SSH_CONFIG" ]; then
    echo "[+] Creando respaldo de configuración SSH en $BACKUP_FILE"
    cp "$SSH_CONFIG" "$BACKUP_FILE"
else
    echo "[!] No se encontró el archivo de configuración SSH en $SSH_CONFIG. Abortando."
    exit 1
fi

echo "[+] Aplicando configuración segura de SSH..."
set_sshd_option "PermitRootLogin" "no"
set_sshd_option "PasswordAuthentication" "yes"
set_sshd_option "ClientAliveInterval" "300"
set_sshd_option "ClientAliveCountMax" "0"
set_sshd_option "MaxAuthTries" "3"
set_sshd_option "LogLevel" "VERBOSE"

validate_sshd
restart_ssh_service

echo "[+] Configuración de SSH completada exitosamente."
echo "[+] Logs de autenticación SSH disponibles en /var/log/auth.log o mediante journalctl -u ssh"


# =========================================
# ============ SEGUNDO SCRIPT ============
# =========================================

set -e
echo "== Configuración de Hardening iniciada =="

read -p "Ingrese el nombre del nuevo usuario: " FULL_NAME
USERNAME=$(echo "$FULL_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

while true; do
    read -s -p "Ingrese una contraseña temporal para $USERNAME: " TEMP_PASS
    echo
    read -s -p "Confirme la contraseña temporal: " TEMP_CONFIRM
    echo
    [ "$TEMP_PASS" == "$TEMP_CONFIRM" ] && break
    echo "Las contraseñas no coinciden. Intente de nuevo."
done

SUDOERS_FILE="customsudoers_$USERNAME"

id "$USERNAME" &>/dev/null || useradd -m -s /bin/bash -c "$FULL_NAME" "$USERNAME"
echo "$USERNAME:$TEMP_PASS" | chpasswd
chage -d 0 "$USERNAME"
echo "[+] Usuario creado: $USERNAME ($FULL_NAME)"

apt autoremove --purge -y
apt remove thunderbird rhythmbox libreoffice* -y

apt install -y ufw fail2ban wget curl gnupg2 software-properties-common apt-transport-https ca-certificates lsb-release wine gnome-screensaver

ufw enable
systemctl enable ufw
systemctl enable fail2ban --now

echo "$USERNAME ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$SUDOERS_FILE"
echo "$USERNAME ALL=NOPASSWD: /usr/bin/apt install, /usr/bin/apt-get install, /usr/bin/wget, /usr/bin/curl" >> "/etc/sudoers.d/$SUDOERS_FILE"
chmod 440 "/etc/sudoers.d/$SUDOERS_FILE"

if ! grep -q "/var/log/sudo.log" /etc/sudoers; then
    echo "Defaults log_input,log_output" >> /etc/sudoers
    echo "Defaults logfile=\"/var/log/sudo.log\"" >> /etc/sudoers
fi

PROTEGIDOS=("ufw" "fail2ban" "gnome-screensaver" "wget" "curl" "gnupg2" "wine" "software-properties-common" "apt-transport-https" "ca-certificates" "lsb-release" "docker")

proteger_comando() {
    local cmd="$1"
    local bin="/usr/bin/$cmd"
    local original="/usr/local/bin/${cmd}.original"

    if [ ! -f "$original" ]; then
        mv "$bin" "$original"
    fi

    cat <<EOF > "$bin"
#!/bin/bash
PROTEGIDOS=(${PROTEGIDOS[@]})
if [[ "\$1" =~ ^(remove|purge|disable|stop)$ ]]; then
  for pkg in "\${PROTEGIDOS[@]}"; do
    if [[ "\$@" =~ \$pkg ]]; then
      echo "ERROR: No tienes permitido ejecutar esta acción sobre \$pkg."
      exit 1
    fi
  done
fi
exec "$original" "\$@"
EOF

    chmod +x "$bin"
    chattr +i "$bin"
    echo "  → Comando protegido: $cmd"
}

proteger_comando apt
proteger_comando apt-get
proteger_comando systemctl

USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.config/autostart"
cat <<EOL > "$USER_HOME/.config/autostart/lock.desktop"
[Desktop Entry]
Type=Application
Exec=gnome-screensaver-command --lock
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=AutoLock
Comment=Bloqueo automático de pantalla
EOL

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
gsettings set org.gnome.desktop.session idle-delay 300 2>/dev/null || true

wget -q -O chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
dpkg -i chrome.deb || apt -f install -y
rm chrome.deb

curl -fsSL https://get.docker.com | bash
usermod -aG docker "$USERNAME"
DOCKER_COMPOSE_VERSION="2.24.0"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v$DOCKER_COMPOSE_VERSION/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo -e "\nInstalación y protección de hardening completado."
echo "  Usuario: $USERNAME ($FULL_NAME)"
echo "  Contraseña temporal: [OCULTA]"
echo "  Protección aplicada a: ${PROTEGIDOS[*]}"

