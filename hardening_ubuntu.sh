#!/bin/bash

set -e

# === CONFIGURACIÓN INICIAL ===
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

# === 1: Crear usuario ===
id "$USERNAME" &>/dev/null || useradd -m -s /bin/bash -c "$FULL_NAME" "$USERNAME"
echo "$USERNAME:$TEMP_PASS" | chpasswd
chage -d 0 "$USERNAME"
echo "[+] Usuario creado: $USERNAME ($FULL_NAME)"

# === 2: Actualizar sistema ===
apt update && apt upgrade -y

# === 3: Limpieza ===
apt autoremove --purge -y
apt remove thunderbird rhythmbox libreoffice* -y

# === 4: Seguridad y herramientas ===
apt install -y ufw fail2ban wget curl gnupg2 software-properties-common apt-transport-https ca-certificates lsb-release wine gnome-screensaver

# === 5: Activar servicios ===
ufw enable
systemctl enable ufw
systemctl enable fail2ban --now

# === Paso 6: Configurar sudoers y auditoría ===
echo "$USERNAME ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$SUDOERS_FILE"
echo "$USERNAME ALL=NOPASSWD: /usr/bin/apt install, /usr/bin/apt-get install, /usr/bin/wget, /usr/bin/curl" >> "/etc/sudoers.d/$SUDOERS_FILE"
chmod 440 "/etc/sudoers.d/$SUDOERS_FILE"

# 6: Activar logging de sudo
if ! grep -q "/var/log/sudo.log" /etc/sudoers; then
    echo "Defaults log_input,log_output" >> /etc/sudoers
    echo "Defaults logfile=\"/var/log/sudo.log\"" >> /etc/sudoers
fi

# === 7: Protección de paquetes críticos ===
PROTEGIDOS=("ufw" "fail2ban" "gnome-screensaver" "wget" "curl" "gnupg2" "wine" "software-properties-common" "apt-transport-https" "ca-certificates" "lsb-release" "docker")

# Crear wrappers protegidos
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

# === 8: Bloqueo automático de pantalla ===
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

# === 9: Instalar Google Chrome ===
wget -q -O chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
dpkg -i chrome.deb || apt -f install -y
rm chrome.deb

# === 10: Instalar Docker y Docker Compose ===
curl -fsSL https://get.docker.com | bash
usermod -aG docker "$USERNAME"
DOCKER_COMPOSE_VERSION="2.24.0"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v$DOCKER_COMPOSE_VERSION/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose


# === Final ===
echo -e "\nInstalación y protección de hardening completado."
echo "  Usuario: $USERNAME ($FULL_NAME)"
echo "  Contraseña temporal: [OCULTA]"
echo "  Protección aplicada a: ${PROTEGIDOS[*]}"

