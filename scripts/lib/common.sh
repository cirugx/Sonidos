#!/usr/bin/env bash
# =============================================================================
# common.sh — Utilidades compartidas: logging, cleanup, dependencias, paths
# =============================================================================
# Este archivo es sourced por render.sh. No ejecutar directamente.
# NO usar `set -e` aquí: lo establece el script principal.

# ─── PATHS Y CONFIGURACIÓN GLOBAL ────────────────────────────────────────────
readonly SCRIPT_VERSION="3.3.0"

# BASH_SOURCE[0] aquí es common.sh (dentro de scripts/lib/)
# Resolvemos: LIB_DIR=scripts/lib, SCRIPTS_DIR=scripts, PROJECT_ROOT=repo root
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${LIB_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/default.env}"
DIR="${DIR:-${PROJECT_ROOT}/output}"

# Cargar configuración si existe
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi

# Defaults (las variables ya seteadas en config/default.env o entorno no se sobreescriben)
: "${DURACION:=10}"
: "${SAMPLE_RATE:=48000}"
: "${BITS:=24}"
: "${THREADS:=$(nproc 2>/dev/null || echo 4)}"
: "${FORMATO:=wav}"

# Diseño sónico
: "${INFRA_FREQ:=19}"
: "${INFRA_VOL:=-22}"
: "${INFRA_HARM2_VOL:=-30}"
: "${INFRA_HARM3_VOL:=-36}"
: "${ATMOS_FREQ:=55}"
: "${ATMOS_VOL:=-12}"
: "${WIND_LP_FREQ:=800}"
: "${WIND_TREMOLO_FREQ:=0.15}"
: "${AGAVE_BP_FREQ:=800}"
: "${AGAVE_BP_WIDTH:=3}"
: "${SILICE_HP_FREQ:=8000}"
: "${SILICE_LP_FREQ:=16000}"
: "${SILICE_TREBLE_FREQ:=12000}"
: "${SILICE_TREBLE_GAIN:=4}"
: "${CANON_DELAY_MS:=240}"
: "${SIDECHAIN_THRESH:=-28}"
: "${SIDECHAIN_RATIO:=3}"
: "${TARGET_LUFS:=-16}"
: "${TARGET_TP:=-1.5}"
: "${TARGET_LRA:=11}"

# Estado interno
declare -a TEMP_FILES=()
declare -A JOBS=()
declare LOCK_FILE=""
declare VERBOSE=0
declare QUIET=0
declare FASE="all"
declare LOG_FILE=""

# Variables globales para disponibilidad de filtros
declare -A FILTRO_DISPONIBLE

# ─── PALETA CROMÁTICA ────────────────────────────────────────────────────────
# ANSI-C quoting ($'...') interpreta los escapes al asignar, no en runtime.
# Esto permite usar ${C_BOLD} en cat <<EOF y en printf -v correctamente.
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
C_CYAN=$'\033[0;36m'

# ─── LOGGING ─────────────────────────────────────────────────────────────────
# Escribe a stderr con color y opcionalmente a un archivo de log.
_log() {
    local nivel="${1:-INFO}" mensaje="${2:-}" color="$C_RESET" ts=""
    ts=$(date '+%H:%M:%S' 2>/dev/null || echo "")
    case "$nivel" in
        DEBUG) [[ $VERBOSE -eq 0 ]] && return 0; color="$C_DIM" ;;
        INFO)  color="$C_CYAN" ;;
        OK)    color="$C_GREEN" ;;
        WARN)  color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
        CRIT)  color="${C_BOLD}${C_RED}" ;;
    esac
    [[ $QUIET -eq 1 && "$nivel" != "ERROR" && "$nivel" != "CRIT" ]] && return 0
    local linea
    # shellcheck disable=SC2059
    printf -v linea "${color}[%-5s]${C_RESET} %s %s" "$nivel" "[$ts]" "$mensaje"
    printf '%s\n' "$linea" >&2
    # Log a archivo (sin colores) si está activado
    if [[ -n "$LOG_FILE" ]]; then
        # Eliminar códigos ANSI para el log
        local plain
        plain=$(printf '%s' "$linea" | sed 's/\x1b\[[0-9;]*m//g')
        printf '%s\n' "$plain" >> "$LOG_FILE"
    fi
}

die() { _log "CRIT" "$*"; exit 1; }

progreso() {
    local num="$1" msg="$2"
    # shellcheck disable=SC2059
    printf "${C_BOLD}${C_CYAN}[FASE %s/6]${C_RESET} %s\n" "$num" "$msg" >&2
    if [[ -n "$LOG_FILE" ]]; then
        printf '[FASE %s/6] %s\n' "$num" "$msg" >> "$LOG_FILE"
    fi
}

# ─── VALIDACIÓN ──────────────────────────────────────────────────────────────
# Valida que un valor sea numérico (entero o decimal, con signo opcional).
es_numero() {
    [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

validar_parametros() {
    es_numero "$DURACION"      || die "DURACION no numérico: '$DURACION'"
    es_numero "$SAMPLE_RATE"   || die "SAMPLE_RATE no numérico: '$SAMPLE_RATE'"
    [[ "$BITS" =~ ^(16|24|32)$ ]] || die "BITS inválido: '$BITS' (debe ser 16|24|32)"
    [[ "$FORMATO" =~ ^(wav|flac)$ ]] || die "FORMATO inválido: '$FORMATO' (debe ser wav|flac)"
    es_numero "$TARGET_LUFS"   || die "TARGET_LUFS no numérico: '$TARGET_LUFS'"
    es_numero "$INFRA_FREQ"    || die "INFRA_FREQ no numérico: '$INFRA_FREQ'"
    es_numero "$THREADS"       || die "THREADS no numérico: '$THREADS'"
    (( THREADS >= 1 ))         || die "THREADS debe ser >= 1"
    (( DURACION > 0 ))         || die "DURACION debe ser > 0"
}

# ─── TRAP Y LIMPIEZA ─────────────────────────────────────────────────────────
cleanup() {
    local code=$?
    # Solo en el proceso principal (no en subshells)
    if [[ -n "${BASHPID:-}" && "${BASHPID:-}" == "$$" ]]; then
        [[ $code -ne 0 ]] && _log "WARN" "Abortando (código $code). Limpiando..."
        for f in "${TEMP_FILES[@]:-}"; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done
        [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    fi
    return 0
}

# Trap que exit explícitamente para que la señal se respete
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup' EXIT

# ─── VERIFICACIÓN DE DEPENDENCIAS Y FILTROS ──────────────────────────────────
verificar_dependencias() {
    local -a faltan=()
    for dep in ffmpeg ffprobe; do
        command -v "$dep" >/dev/null 2>&1 || faltan+=("$dep")
    done
    if [[ ${#faltan[@]} -gt 0 ]]; then
        local lista
        lista=$(IFS=' '; echo "${faltan[*]}")
        die "Dependencias faltantes: ${lista}. Instala FFmpeg (ffmpeg + ffprobe)."
    fi
    local ver
    ver=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')
    _log "INFO" "FFmpeg ${ver} | ${THREADS} hilos | ${SAMPLE_RATE}Hz/${BITS}-bit | ${FORMATO}"

    # Filtros disponibles
    # Formato de `ffmpeg -filters`:
    #   " TSC name           TYPE   Desc"
    # Donde TSC son flags (T.., .S., ..C). Extraemos el segundo campo.
    local filtros_lista
    filtros_lista=$(ffmpeg -hide_banner -filters 2>/dev/null \
        | awk '/^ [T.][S.][C.] / {print $2}' | sort -u || echo "")

    local -a filtros_requeridos=(
        "anoisesrc" "sine" "amix" "volume" "lowpass" "highpass" "aformat" "pan"
        "adelay" "equalizer" "acompressor" "compand" "stereotools" "treble"
        "tremolo" "vibrato" "bandpass" "aecho" "freeverb" "loudnorm" "alimiter"
        "asidechaincompress" "extrastereo" "firequalizer" "adither"
    )

    for f in "${filtros_requeridos[@]}"; do
        FILTRO_DISPONIBLE["$f"]=0
    done

    while IFS= read -r line; do
        local fname
        fname=$(echo "$line" | awk '{print $1}')
        if [[ -n "$fname" && -v "FILTRO_DISPONIBLE[$fname]" ]]; then
            FILTRO_DISPONIBLE["$fname"]=1
        fi
    done <<< "$filtros_lista"

    local -a faltantes=()
    for f in "${filtros_requeridos[@]}"; do
        if [[ ${FILTRO_DISPONIBLE["$f"]} -ne 1 ]]; then
            faltantes+=("$f")
        fi
    done

    if [[ ${#faltantes[@]} -gt 0 ]]; then
        local lista
        lista=$(IFS=', '; echo "${faltantes[*]}")
        _log "WARN" "Filtros no disponibles: $lista (se usarán fallbacks u omitirán)."
        _log "WARN" "Esto puede afectar significativamente la calidad del resultado final."
    else
        _log "OK" "Todos los filtros requeridos están disponibles."
    fi
}

# ─── DIRECTORIO Y LOCK FILE ──────────────────────────────────────────────────
crear_directorio() {
    [[ -d "$DIR" ]] || { mkdir -p "$DIR" || die "No se pudo crear $DIR"; }
    [[ -w "$DIR" ]] || die "Sin permisos de escritura en $DIR"
    LOCK_FILE="$DIR/.paisaje.lock"
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Otra instancia activa (PID $pid). Elimina $LOCK_FILE si está stale."
        fi
        rm -f "$LOCK_FILE"
    fi
    # BASHPID == $$ en el shell principal; escribimos el PID del proceso principal
    echo "$$" > "$LOCK_FILE"
}

# ─── WRAPPER FFmpeg ──────────────────────────────────────────────────────────
ff() {
    local salida="$1"; shift
    local errlog
    errlog=$(mktemp -p "$DIR" .fferr.XXXXXX) || die "mktemp falló"
    TEMP_FILES+=("$errlog")
    _log "DEBUG" "ffmpeg → $(basename "$salida")"
    if ! ffmpeg -y -hide_banner -loglevel error -threads "$THREADS" \
        "$@" "$salida" 2>"$errlog"; then
        _log "ERROR" "FFmpeg falló generando: $salida"
        sed 's/^/    /' "$errlog" >&2
        rm -f "$errlog"
        return 1
    fi
    rm -f "$errlog"
    return 0
}

ffprobe_val() {
    ffprobe -v error -show_entries "$2" -of csv=p=0 "$1" 2>/dev/null
}

requiere_archivos() {
    for f in "$@"; do
        [[ -f "$f" ]] || die "Archivo requerido no encontrado: $f. Ejecuta fases anteriores."
    done
}

# ─── PARALELIZACIÓN ──────────────────────────────────────────────────────────
lanzar_job() {
    local nombre="$1"; shift
    "$@" &
    JOBS[$!]="$nombre"
    _log "DEBUG" "Job lanzado: $nombre (PID $!)"
}

esperar_jobs() {
    local fail=0
    for pid in "${!JOBS[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
            _log "ERROR" "Job fallido: ${JOBS[$pid]}"
            fail=1
        fi
    done
    JOBS=()
    if [[ $fail -eq 1 ]]; then
        die "Uno o más jobs paralelos fallaron"
    fi
    return 0
}
