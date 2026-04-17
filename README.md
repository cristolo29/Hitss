# Oracle Update Daemon

Script Bash que corre como daemon y ejecuta periódicamente un `UPDATE` en una base de datos Oracle, con logging, control de instancia única y manejo seguro de credenciales.

---

## Estructura del proyecto

```
Hitss/
├── bin/
│   └── oracle_update_daemon.sh   # Script principal
├── conf/
│   └── .env                      # Credenciales (NO versionar)
├── logs/
│   └── oracle_update_daemon.log  # Generado en tiempo de ejecución
└── run/
    └── oracle_update_daemon.pid  # PID del proceso activo
```

---

## Requisitos previos

- **Bash 4+**
- **Oracle Instant Client** con `sqlplus` disponible en el `PATH`
- Sistema Linux o macOS

---

## Configuración

### 1. Crear el archivo de credenciales

```bash
mkdir -p conf
cat > conf/.env <<'EOF'
ORACLE_USER=mi_usuario
ORACLE_PASS=mi_contraseña
ORACLE_DSN=host:1521/servicio
EOF
```

### 2. Asegurar permisos del archivo `.env`

El script valida que el archivo tenga permisos `600` o `400`. Si no los tiene, el script se detiene con error.

```bash
chmod 600 conf/.env
```

### 3. Crear los directorios de soporte

```bash
mkdir -p logs run
```

### 4. (Opcional) Personalizar variables de entorno

Se pueden sobreescribir antes de ejecutar:

| Variable   | Default                              | Descripción                     |
|------------|--------------------------------------|---------------------------------|
| `LOG_FILE` | `logs/oracle_update_daemon.log`      | Ruta del archivo de log         |
| `PID_FILE` | `run/oracle_update_daemon.pid`       | Ruta del archivo PID            |
| `INTERVAL` | `300` (hardcoded)                    | Segundos entre cada ejecución   |

---

## Cómo ejecutar

```bash
# Ejecución directa (foreground)
bash bin/oracle_update_daemon.sh

# Ejecución en segundo plano
nohup bash bin/oracle_update_daemon.sh &

# Con log file personalizado
LOG_FILE=/var/log/oracle_daemon.log bash bin/oracle_update_daemon.sh
```

---

## Paso a paso interno del script

### Paso 1 — Carga de credenciales (`conf/.env`)

El script localiza su directorio raíz de forma portátil usando `BASH_SOURCE[0]`, luego:

1. Verifica que `conf/.env` exista; si no, termina con error.
2. Valida que los permisos sean `600` o `400` (solo lectura del propietario).
3. Parsea línea a línea, ignorando comentarios (`#`) y líneas vacías.
4. Exporta solo variables con formato `CLAVE=VALOR`.

> Las contraseñas nunca aparecen en el log ni en argumentos del proceso.

### Paso 2 — Validación de configuración

Usando la sintaxis `:` de Bash, verifica que `ORACLE_USER`, `ORACLE_PASS` y `ORACLE_DSN` estén definidas. Si alguna falta, el script aborta con un mensaje claro.

### Paso 3 — Inicialización del logging

Define tres funciones (`log_info`, `log_warn`, `log_error`) que escriben en `stdout`/`stderr` y también agregan (`tee -a`) al archivo de log con timestamp `YYYY-MM-DD HH:MM:SS`.

### Paso 4 — Trampa de señales (`trap`)

Registra un handler `cleanup` para `SIGTERM`, `SIGINT` (Ctrl+C) y `SIGHUP`. Al recibir cualquiera de esas señales:

1. Registra el evento en el log.
2. Elimina el archivo PID.
3. Sale limpiamente con código `0`.

### Paso 5 — Verificación de dependencias

La función `check_dependencies` itera sobre los comandos requeridos (actualmente solo `sqlplus`) y acumula los faltantes. Si hay alguno, los lista y sale con error en lugar de fallar de forma críptica más adelante.

### Paso 6 — Control de instancia única

`guard_single_instance` evita que dos daemons corran al mismo tiempo:

1. Si existe un `PID_FILE`, lee el PID guardado.
2. Usa `kill -0 <pid>` para verificar si el proceso sigue vivo (no envía ninguna señal real).
3. Si está vivo → aborta. Si está muerto → limpia el PID file obsoleto.
4. Escribe el PID actual (`$$`) en el archivo.

### Paso 7 — Ejecución del UPDATE (`run_update`)

Se conecta a Oracle con `sqlplus -s` (modo silencioso) usando un heredoc. El bloque SQL:

- Desactiva feedback y serveroutput para evitar ruido en la salida.
- Usa `WHENEVER SQLERROR EXIT SQL.SQLCODE` para propagar errores como exit codes.
- Ejecuta el `UPDATE` sobre la tabla objetivo.
- Hace `COMMIT` explícito.

Si `sqlplus` retorna un exit code distinto de `0`, se loguea el error y la función retorna `1` (pero el daemon **no se detiene**, continúa en la próxima iteración).

### Paso 8 — Bucle principal (`main`)

```
check_dependencies
guard_single_instance
loop infinito:
    run_update   → si falla, loguea advertencia y continúa
    sleep 300s
```

El daemon nunca sale por un error de SQL; solo sale si recibe una señal o si las dependencias/credenciales fallan al inicio.

---

## Personalizar el UPDATE

Editar el heredoc dentro de `run_update` (líneas 70–83) y reemplazar la sentencia de ejemplo:

```sql
UPDATE mi_esquema.mi_tabla
   SET estado = 'PROCESADO',
       fecha_actualizacion = SYSDATE
 WHERE estado = 'PENDIENTE';
```

---

## Detener el daemon

```bash
# Forma limpia (respeta el handler cleanup)
kill "$(cat run/oracle_update_daemon.pid)"

# Si se ejecutó con nohup
pkill -f oracle_update_daemon.sh
```

---

## Seguridad

- El archivo `.env` está en `.gitignore`; **nunca** debe ser commiteado.
- Los permisos `600` se validan en cada arranque.
- Las credenciales se pasan a `sqlplus` como argumento de línea de comando; en sistemas con `/proc`, este argumento puede ser visible. Para mayor seguridad, considerar usar Oracle Wallet o variables de entorno de `sqlplus`.
