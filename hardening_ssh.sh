#!/bin/bash

SSH_CONFIG="/etc/ssh/sshd_config"
DEFAULT_USER="adminuser"
PASSWORD_LENGTH=12
BACKUP_FILE="${SSH_CONFIG}.bak"

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

# Al menos un usuario debe pertenecer al grupo sudo o se puede perder el acceso por medio de SSH
check_sudo_user() {
    getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | head -n1
}

# Crea un usuario con sudo si en dado caso no existe ninguno (aqui ya deberia estar la cuenta de soporte)
ensure_sudo_user() {
    local sudo_user
    sudo_user=$(check_sudo_user)

    if [ -z "$sudo_user" ]; then
        echo "[!] No se encontraron usuarios con acceso sudo. Se creará uno nuevo: $DEFAULT_USER"

        # Generar contraseña aleatoria para el usario nuevo de sudo (esto solo aplica si no hay usuarios con sudo) 
        PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c $PASSWORD_LENGTH)

        # Crear el usuario y asignar contraseña (por si no existiera)
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

# Valida sintaxis de configuración SSH antes de reiniciar (esto para evitar caídas del servicio)
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

# Reinicia el servicio SSH, manejando diferentes nombres de unidad
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

### INICIO DEL SCRIPT

echo "[+] Iniciando verificación de usuarios con sudo..."
ensure_sudo_user

# Backup seguro antes de modificar sshd_config
if [ -f "$SSH_CONFIG" ]; then
    echo "[+] Creando respaldo de configuración SSH en $BACKUP_FILE"
    cp "$SSH_CONFIG" "$BACKUP_FILE"
else
    echo "[!] No se encontró el archivo de configuración SSH en $SSH_CONFIG. Abortando."
    exit 1
fi

echo "[+] Aplicando configuración segura de SSH..."

# SSH Hardening
set_sshd_option "PermitRootLogin" "no"
set_sshd_option "PasswordAuthentication" "yes"
set_sshd_option "ClientAliveInterval" "300"
set_sshd_option "ClientAliveCountMax" "0"
set_sshd_option "MaxAuthTries" "3"
set_sshd_option "LogLevel" "VERBOSE"

# Validar y aplicar cambios
validate_sshd
restart_ssh_service

echo "[+] Configuración de SSH completada exitosamente."
echo "[+] Logs de autenticación SSH disponibles en /var/log/auth.log o mediante journalctl -u ssh"

