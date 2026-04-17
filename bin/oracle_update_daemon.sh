#!/bin/bash
set -Eeuo pipefail

# ─── Cargar variables desde archivo oculto ────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
ENV_FILE="${ROOT_DIR}/conf/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    printf 'ERROR: archivo de credenciales no encontrado: %s\n' "$ENV_FILE" >&2
    exit 1
fi

# Verificar permisos: solo el propietario debe poder leerlo
env_perms=$(stat -c "%a" "$ENV_FILE" 2>/dev/null || stat -f "%Op" "$ENV_FILE" | grep -oE '[0-7]{3}$')
if [[ "$env_perms" != "600" && "$env_perms" != "400" ]]; then
    printf 'ERROR: permisos inseguros en %s (%s). Ejecuta: chmod 600 %s\n' \
        "$ENV_FILE" "$env_perms" "$ENV_FILE" >&2
    exit 1
fi

# Cargar solo líneas KEY=VALUE, ignorando comentarios y líneas vacías
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]]           && continue
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
        export "${BASH_REMATCH[1]}"="${BASH_REMATCH[2]//\"/}"
    fi
done < "$ENV_FILE"

# ─── Configuración ────────────────────────────────────────────────────────────
: "${ORACLE_USER:?Variable ORACLE_USER no definida en .env}"
: "${ORACLE_PASS:?Variable ORACLE_PASS no definida en .env}"
: "${ORACLE_DSN:?Variable ORACLE_DSN no definida en .env}"
INTERVAL=300
LOG_FILE="${LOG_FILE:-${ROOT_DIR}/logs/oracle_update_daemon.log}"
PID_FILE="${PID_FILE:-${ROOT_DIR}/run/oracle_update_daemon.pid}"
NOHUP_OUT="${NOHUP_OUT:-${ROOT_DIR}/nohup.out}"

# ─── Logging ──────────────────────────────────────────────────────────────────
log_info()  { printf '[%s] INFO:  %s\n'  "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
log_warn()  { printf '[%s] WARN:  %s\n'  "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
log_error() { printf '[%s] ERROR: %s\n'  "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

# ─── Limpieza al salir ─────────────────────────────────────────────────────────
cleanup() {
    log_info "Señal recibida. Deteniendo daemon..."
    rm -f "$PID_FILE"
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ─── Verificar dependencias ───────────────────────────────────────────────────
check_dependencies() {
    local -a missing=()
    for cmd in sqlplus; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Comandos requeridos no encontrados: ${missing[*]}"
        exit 1
    fi
}

# ─── Lógica del UPDATE ────────────────────────────────────────────────────────
run_update() {
    log_info "Ejecutando UPDATE en Oracle..."

    local exit_code
    local output
    output=$(sqlplus -s "${ORACLE_USER}/${ORACLE_PASS}@${ORACLE_DSN}" <<'EOF'
SET SERVEROUTPUT OFF
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE

-- ► Reemplaza esta sentencia con tu UPDATE real ◄
UPDATE mi_esquema.mi_tabla
   SET estado = 'PROCESADO',
       fecha_actualizacion = SYSDATE
 WHERE estado = 'PENDIENTE';

COMMIT;
EXIT 0;
EOF
    ) || exit_code=$?

    if [[ "${exit_code:-0}" -ne 0 ]]; then
        log_error "UPDATE falló (código: ${exit_code:-?}). Salida: $output"
        return 1
    fi

    log_info "UPDATE completado exitosamente. Salida: ${output:-sin salida}"
}

# ─── Limpieza diaria de logs ──────────────────────────────────────────────────
rotate_daily_logs() {
    local yesterday="$1"
    printf '[%s] INFO:  Rotación diaria. Limpiando logs del día %s...\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" "$yesterday" >> "$LOG_FILE"
    # Truncar en sitio para no romper el descriptor abierto por tee
    > "$LOG_FILE"
    [[ -f "$NOHUP_OUT" ]] && > "$NOHUP_OUT"
    log_info "Logs limpiados. Nuevo día iniciado."
}

# ─── Evitar instancias duplicadas ─────────────────────────────────────────────
guard_single_instance() {
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(<"$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            log_error "El daemon ya está corriendo con PID $old_pid. Abortando."
            exit 1
        fi
        log_warn "PID file obsoleto encontrado. Limpiando..."
        rm -f "$PID_FILE"
    fi
    echo $$ > "$PID_FILE"
}

# ─── Daemon principal ─────────────────────────────────────────────────────────
main() {
    check_dependencies
    guard_single_instance

    log_info "Daemon iniciado (PID $$). Intervalo: ${INTERVAL}s. Log: $LOG_FILE"

    local iteration=0
    local current_hour
    current_hour=$(date +'%Y-%m-%d %H')

    while true; do
        iteration=$(( iteration + 1 ))

        local this_hour
        this_hour=$(date +'%Y-%m-%d %H')
        if [[ "$this_hour" != "$current_hour" ]]; then
            rotate_daily_logs "$current_hour"
            current_hour="$this_hour"
            iteration=1
        fi

        log_info "── Iteración #${iteration} ──────────────────────"

        run_update || log_warn "Iteración #${iteration} con errores. Continuando..."

        log_info "Esperando ${INTERVAL}s hasta la próxima ejecución..."
        sleep "$INTERVAL"
    done
}

main "$@"
