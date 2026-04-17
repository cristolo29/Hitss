# Guía de Implementación — Oracle Update Daemon

Paso a paso para desplegar el daemon en cualquier servidor Linux (RHEL, CentOS, Ubuntu, Debian) o macOS.

---

## Índice

1. [Requisitos del servidor](#1-requisitos-del-servidor)
2. [Instalar Oracle Instant Client y sqlplus](#2-instalar-oracle-instant-client-y-sqlplus)
3. [Crear el usuario del sistema](#3-crear-el-usuario-del-sistema)
4. [Clonar el repositorio](#4-clonar-el-repositorio)
5. [Crear la estructura de directorios](#5-crear-la-estructura-de-directorios)
6. [Configurar las credenciales](#6-configurar-las-credenciales)
7. [Personalizar el UPDATE](#7-personalizar-el-update)
8. [Verificar la conexión a Oracle](#8-verificar-la-conexión-a-oracle)
9. [Ejecutar el daemon manualmente](#9-ejecutar-el-daemon-manualmente)
10. [Configurar como servicio systemd (producción)](#10-configurar-como-servicio-systemd-producción)
11. [Verificar que el servicio funciona](#11-verificar-que-el-servicio-funciona)
12. [Rotar logs automáticamente](#12-rotar-logs-automáticamente)
13. [Detener y desinstalar](#13-detener-y-desinstalar)
14. [Solución de problemas comunes](#14-solución-de-problemas-comunes)

---

## 1. Requisitos del servidor

| Requisito | Mínimo | Notas |
|-----------|--------|-------|
| SO | Linux 64-bit o macOS | RHEL 7+, Ubuntu 18.04+, Debian 10+ |
| Bash | 4.0+ | `bash --version` |
| Oracle Instant Client | 12.1+ | Ver paso 2 |
| Acceso a la BD | Red / VPN | Puerto TCP hacia Oracle (por defecto 1521) |
| Usuario del sistema | Cualquiera con permisos de lectura | Ver paso 3 |

Verificar versión de Bash:

```bash
bash --version
# GNU bash, version 4.x o superior
```

---

## 2. Instalar Oracle Instant Client y sqlplus

### En RHEL / CentOS

```bash
# Descargar desde Oracle (requiere cuenta gratuita en oracle.com)
# https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html
# Descargar los paquetes RPM:
#   oracle-instantclient-basic-XX.X.X.X.X-X.x86_64.rpm
#   oracle-instantclient-sqlplus-XX.X.X.X.X-X.x86_64.rpm

sudo rpm -ivh oracle-instantclient-basic-*.rpm
sudo rpm -ivh oracle-instantclient-sqlplus-*.rpm

# Configurar las librerías
echo /usr/lib/oracle/XX.X/client64/lib | sudo tee /etc/ld.so.conf.d/oracle.conf
sudo ldconfig
```

### En Ubuntu / Debian

```bash
# Descargar desde Oracle los paquetes .deb:
#   oracle-instantclient-basic_XX.X.X.X.X-X_amd64.deb
#   oracle-instantclient-sqlplus_XX.X.X.X.X-X_amd64.deb

sudo dpkg -i oracle-instantclient-basic_*.deb
sudo dpkg -i oracle-instantclient-sqlplus_*.deb

sudo sh -c "echo /usr/lib/oracle/XX.X/client64/lib > /etc/ld.so.conf.d/oracle.conf"
sudo ldconfig
```

### Agregar sqlplus al PATH (ambas distros)

```bash
# Reemplaza XX.X con tu versión, ej: 21.1
echo 'export PATH=$PATH:/usr/lib/oracle/XX.X/client64/bin' >> ~/.bashrc
source ~/.bashrc
```

### En macOS

```bash
# Instalar via Homebrew
brew tap InstantClientTap/instantclient
brew install instantclient-basic instantclient-sqlplus
```

Verificar instalación:

```bash
sqlplus -V
# SQL*Plus: Release XX.X.X.X.X Production
```

---

## 3. Crear el usuario del sistema

> **Recomendado en producción:** correr el daemon con un usuario dedicado y sin privilegios de root.

```bash
# Crear usuario sin directorio home interactivo ni shell de login
sudo useradd --system --no-create-home --shell /sbin/nologin oracle_daemon

# Verificar
id oracle_daemon
```

Si ya tienes un usuario existente (por ejemplo `appadmin`), puedes usarlo directamente y omitir este paso.

---

## 4. Clonar el repositorio

```bash
# Elegir el directorio de instalación
sudo mkdir -p /opt/oracle_daemon
sudo chown oracle_daemon:oracle_daemon /opt/oracle_daemon

# Clonar como el usuario del sistema
sudo -u oracle_daemon git clone https://github.com/cristolo29/Hitss.git /opt/oracle_daemon
```

Si el servidor no tiene acceso a GitHub, copiar los archivos manualmente con `scp` o `rsync`:

```bash
# Desde tu máquina local
scp -r /ruta/local/Hitss usuario@servidor:/opt/oracle_daemon
```

---

## 5. Crear la estructura de directorios

```bash
cd /opt/oracle_daemon

sudo -u oracle_daemon mkdir -p conf logs run

# Verificar la estructura final
tree /opt/oracle_daemon
# /opt/oracle_daemon
# ├── bin/
# │   └── oracle_update_daemon.sh
# ├── conf/               ← credenciales aquí
# ├── logs/               ← logs aquí
# ├── run/                ← PID aquí
# └── README.md
```

---

## 6. Configurar las credenciales

```bash
# Crear el archivo .env con las credenciales reales
sudo -u oracle_daemon bash -c "cat > /opt/oracle_daemon/conf/.env" <<'EOF'
ORACLE_USER=tu_usuario_oracle
ORACLE_PASS=tu_contraseña_oracle
ORACLE_DSN=hostname_o_ip:1521/nombre_servicio
EOF

# CRÍTICO: permisos restrictivos, el script los valida al arrancar
sudo chmod 600 /opt/oracle_daemon/conf/.env
sudo chown oracle_daemon:oracle_daemon /opt/oracle_daemon/conf/.env
```

**Formato del DSN:**

| Tipo de conexión | Ejemplo |
|-----------------|---------|
| Por hostname y servicio | `miservidor.empresa.com:1521/ORCL` |
| Por IP | `192.168.1.100:1521/ORCL` |
| Por SID (legacy) | `192.168.1.100:1521/ORCL` |
| TNS alias | `MI_TNS_ALIAS` (requiere `tnsnames.ora`) |

---

## 7. Personalizar el UPDATE

Editar el script y reemplazar la sentencia de ejemplo con tu SQL real:

```bash
sudo -u oracle_daemon nano /opt/oracle_daemon/bin/oracle_update_daemon.sh
```

Buscar el bloque heredoc (líneas ~70–83) y reemplazar:

```sql
-- ► ANTES (ejemplo) ◄
UPDATE mi_esquema.mi_tabla
   SET estado = 'PROCESADO',
       fecha_actualizacion = SYSDATE
 WHERE estado = 'PENDIENTE';

-- ► DESPUÉS (tu SQL real) ◄
UPDATE produccion.pedidos
   SET estado = 'ENVIADO',
       fecha_envio = SYSDATE
 WHERE estado = 'LISTO'
   AND fecha_creacion < SYSDATE - 1;
```

También puedes cambiar el intervalo de ejecución modificando la línea:

```bash
INTERVAL=300   # segundos entre cada ejecución (300 = 5 minutos)
```

---

## 8. Verificar la conexión a Oracle

Antes de arrancar el daemon, confirmar que el servidor puede conectarse a Oracle:

```bash
sudo -u oracle_daemon sqlplus -s "tu_usuario/tu_contraseña@hostname:1521/servicio" <<'EOF'
SELECT 1 FROM DUAL;
EXIT;
EOF
```

Salida esperada:

```
         1
----------
         1
```

Si falla, verificar:
- Que el puerto 1521 esté abierto: `telnet hostname 1521`
- Que las credenciales sean correctas
- Que el nombre de servicio/SID sea correcto: contactar al DBA

---

## 9. Ejecutar el daemon manualmente

Antes de configurarlo como servicio, probarlo en primer plano para ver los logs en tiempo real:

```bash
sudo -u oracle_daemon bash /opt/oracle_daemon/bin/oracle_update_daemon.sh
```

Salida esperada en consola:

```
[2026-04-17 10:00:00] INFO:  Daemon iniciado (PID 12345). Intervalo: 300s. Log: /opt/oracle_daemon/logs/oracle_update_daemon.log
[2026-04-17 10:00:00] INFO:  ── Iteración #1 ──────────────────────
[2026-04-17 10:00:00] INFO:  Ejecutando UPDATE en Oracle...
[2026-04-17 10:00:01] INFO:  UPDATE completado exitosamente.
[2026-04-17 10:00:01] INFO:  Esperando 300s hasta la próxima ejecución...
```

Detenerlo con `Ctrl+C`. Si todo funcionó correctamente, pasar al siguiente paso.

---

## 10. Configurar como servicio systemd (producción)

> Este paso aplica a Linux con systemd (RHEL 7+, Ubuntu 16.04+, Debian 9+).

### Crear el archivo de servicio

```bash
sudo nano /etc/systemd/system/oracle-update-daemon.service
```

Pegar el siguiente contenido:

```ini
[Unit]
Description=Oracle Update Daemon
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=oracle_daemon
Group=oracle_daemon

WorkingDirectory=/opt/oracle_daemon
ExecStart=/bin/bash /opt/oracle_daemon/bin/oracle_update_daemon.sh
ExecStop=/bin/kill -SIGTERM $MAINPID

# Reiniciar automáticamente si el proceso muere de forma inesperada
Restart=on-failure
RestartSec=10s

# Límites de seguridad
NoNewPrivileges=yes
PrivateTmp=yes

# Redirigir logs al journal (también se guardan en logs/)
StandardOutput=journal
StandardError=journal
SyslogIdentifier=oracle-update-daemon

[Install]
WantedBy=multi-user.target
```

### Activar y arrancar el servicio

```bash
# Recargar la configuración de systemd
sudo systemctl daemon-reload

# Habilitar el servicio para que arranque automáticamente con el servidor
sudo systemctl enable oracle-update-daemon.service

# Arrancar el servicio ahora
sudo systemctl start oracle-update-daemon.service
```

---

## 11. Verificar que el servicio funciona

```bash
# Ver el estado del servicio
sudo systemctl status oracle-update-daemon.service

# Ver los logs en tiempo real (Ctrl+C para salir)
sudo journalctl -u oracle-update-daemon.service -f

# Ver el archivo de log del script
sudo tail -f /opt/oracle_daemon/logs/oracle_update_daemon.log

# Verificar que el PID file se creó
cat /opt/oracle_daemon/run/oracle_update_daemon.pid
```

Estado esperado:

```
● oracle-update-daemon.service - Oracle Update Daemon
     Loaded: loaded (/etc/systemd/system/oracle-update-daemon.service; enabled)
     Active: active (running) since Thu 2026-04-17 10:00:00 UTC; 5s ago
   Main PID: 12345 (bash)
```

---

## 12. Rotar logs automáticamente

Evitar que el archivo de log crezca indefinidamente configurando `logrotate`:

```bash
sudo nano /etc/logrotate.d/oracle-update-daemon
```

```
/opt/oracle_daemon/logs/oracle_update_daemon.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

Esto rota el log diariamente, conserva 30 días de historial y comprime los archivos viejos. `copytruncate` permite rotar sin necesidad de reiniciar el daemon.

Probar la rotación manualmente:

```bash
sudo logrotate --force /etc/logrotate.d/oracle-update-daemon
ls -lh /opt/oracle_daemon/logs/
```

---

## 13. Detener y desinstalar

### Solo detener

```bash
sudo systemctl stop oracle-update-daemon.service
```

### Deshabilitar el arranque automático

```bash
sudo systemctl disable oracle-update-daemon.service
```

### Desinstalar completamente

```bash
sudo systemctl stop oracle-update-daemon.service
sudo systemctl disable oracle-update-daemon.service
sudo rm /etc/systemd/system/oracle-update-daemon.service
sudo systemctl daemon-reload

# Eliminar archivos del daemon (¡cuidado con los logs si los necesitas!)
sudo rm -rf /opt/oracle_daemon

# Eliminar el usuario del sistema (opcional)
sudo userdel oracle_daemon
```

---

## 14. Solución de problemas comunes

### Error: `archivo de credenciales no encontrado`

```
ERROR: archivo de credenciales no encontrado: /opt/oracle_daemon/conf/.env
```

**Causa:** El archivo `conf/.env` no existe.
**Solución:** Revisar el paso 6. Verificar con `ls -la /opt/oracle_daemon/conf/`.

---

### Error: `permisos inseguros`

```
ERROR: permisos inseguros en conf/.env (644). Ejecuta: chmod 600 conf/.env
```

**Causa:** El archivo `.env` tiene permisos demasiado abiertos.
**Solución:**

```bash
chmod 600 /opt/oracle_daemon/conf/.env
```

---

### Error: `Comandos requeridos no encontrados: sqlplus`

**Causa:** `sqlplus` no está en el PATH del usuario del sistema.
**Solución:** Agregar el PATH dentro del archivo de servicio systemd:

```ini
[Service]
Environment="PATH=/usr/lib/oracle/21.1/client64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
```

Luego recargar:

```bash
sudo systemctl daemon-reload && sudo systemctl restart oracle-update-daemon.service
```

---

### Error: `El daemon ya está corriendo con PID XXXX`

**Causa:** Ya hay una instancia activa, o quedó un PID file de una ejecución anterior.
**Solución:**

```bash
# Verificar si realmente está corriendo
ps aux | grep oracle_update_daemon

# Si no está corriendo, limpiar el PID file manualmente
rm /opt/oracle_daemon/run/oracle_update_daemon.pid
```

---

### Error de conexión Oracle: `ORA-12541` o `TNS: no listener`

**Causa:** No hay conectividad al servidor Oracle.
**Solución:**

```bash
# Verificar conectividad de red al puerto Oracle
telnet HOSTNAME_ORACLE 1521

# Si no conecta, revisar firewall del servidor
sudo firewall-cmd --list-all           # RHEL/CentOS
sudo ufw status                        # Ubuntu
```

---

### El servicio se reinicia constantemente

```bash
# Ver los últimos errores
sudo journalctl -u oracle-update-daemon.service -n 50 --no-pager
```

Buscar la línea `ERROR:` en la salida para identificar la causa raíz.
