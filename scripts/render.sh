#!/usr/bin/env bash
# =============================================================================
# PAISAJE SONORO DESÉRTICO — SÍNTESIS PROCEDURAL v3.2.2 (MINIMAL SAFE VERSION)
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ─── CONFIGURACIÓN GLOBAL ────────────────────────────────────────────────────
readonly SCRIPT_VERSION="3.2.2-minimal"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/default.env}"
DIR="${DIR:-${PROJECT_ROOT}/output}"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi

: "${DURACION:=10}"
: "${SAMPLE_RATE:=48000}"
: "${BITS:=24}"
: "${THREADS:=$(nproc 2>/dev/null || echo 4)}"
: "${FORMATO:=wav}"

# Diseño sónico (ajustado para nuevas implementaciones)
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

# Variables globales para disponibilidad de filtros
declare -A FILTRO_DISPONIBLE

# ─── PALETA CROMÁTICA ────────────────────────────────────────────────────────
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'

# ─── LOGGING ─────────────────────────────────────────────────────────────────
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
    printf "${color}[%-5s]${C_RESET} %s %s\n" "$nivel" "[$ts]" "$mensaje" >&2
}
die() { _log "CRIT" "$*"; exit 1; }
progreso() {
    local num="$1" msg="$2"
    printf "${C_BOLD}${C_CYAN}[FASE %s/6]${C_RESET} %s\n" "$num" "$msg" >&2
}

# ─── TRAP Y LIMPIEZA ─────────────────────────────────────────────────────────
cleanup() {
    local code=$?
    if [[ -n "${BASHPID:-}" && "${BASHPID:-}" == "$$" ]]; then
        [[ $code -ne 0 ]] && _log "WARN" "Abortando (código $code). Limpiando..."
        for f in "${TEMP_FILES[@]:-}"; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done
        [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    fi
    return 0
}
trap cleanup EXIT INT TERM HUP

# ─── VERIFICACIÓN DE DEPENDENCIAS Y FILTROS ──────────────────────────────────
verificar_dependencias() {
    local -a faltan=()
    for dep in ffmpeg ffprobe bc; do
        command -v "$dep" >/dev/null 2>&1 || faltan+=("$dep")
    done
    if [[ ${#faltan[@]} -gt 0 ]]; then
        local lista
        lista=$(IFS=' '; echo "${faltan[*]}")
        die "Dependencias faltantes: ${lista}. Instala: sudo dnf install ffmpeg bc (o el paquete correspondiente)"
    fi
    local ver
    ver=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')
    _log "INFO" "FFmpeg ${ver} | ${THREADS} hilos | ${SAMPLE_RATE}Hz/${BITS}-bit | ${FORMATO}"

    # Obtener lista de filtros disponibles
    local filtros_lista
    filtros_lista=$(ffmpeg -hide_banner -filters 2>/dev/null | grep -E '^\w+\s+V[AFDS]' | awk '{print $1}' | sort || echo "")

    # Filtros que se van a usar en el script
    local -a filtros_requeridos=(
        "anoisesrc" "sine" "amix" "volume" "lowpass" "highpass" "aformat" "pan"
        "adelay" "equalizer" "acompressor" "compand" "stereotools" "treble"
        "tremolo" "vibrato" "bandpass" "aecho" "freeverb" "loudnorm" "alimiter"
        "asidechaincompress" "extrastereo" "firequalizer" "adither"
    )

    # Inicializar todas las entradas como no disponibles
    for f in "${filtros_requeridos[@]}"; do
        FILTRO_DISPONIBLE["$f"]=0
    done

    # Marcar como disponibles los que están en la lista
    while IFS= read -r line; do
        local fname
        fname=$(echo "$line" | awk '{print $1}')
        if [[ -n "$fname" && -v "FILTRO_DISPONIBLE[$fname]" ]]; then
            FILTRO_DISPONIBLE["$fname"]=1
        fi
    done <<< "$filtros_lista"

    # Informar sobre filtros no disponibles
    local -a faltantes=()
    for f in "${filtros_requeridos[@]}"; do
        if [[ ${FILTRO_DISPONIBLE["$f"]} -ne 1 ]]; then
            faltantes+=("$f")
        fi
    done

    if [[ ${#faltantes[@]} -gt 0 ]]; then
        local lista
        lista=$(IFS=', '; echo "${faltantes[*]}")
        _log "WARN" "Filtros no disponibles: $lista (se usarán fallbacks o se omitirán)."
        _log "WARN" "Esto puede afectar significativamente la calidad del resultado final."
    else
        _log "INFO" "Todos los filtros requeridos están disponibles."
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
            die "Otra instancia activa (PID $pid). Elimina $LOCK_FILE si es stale."
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
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
    [[ $fail -eq 1 ]] && die "Uno o más jobs paralelos fallaron"
}

# ─── FUNCIONES DE AYUDA PARA FILTROS ─────────────────────────────────────────
construir_cadena_aecho() {
    local gain_in="$1"; local gain_out="$2"; shift 2
    local delays=("$@")
    if [[ ${FILTRO_DISPONIBLE["aecho"]} -eq 1 ]]; then
        local chain="aecho=${gain_in}:${gain_out}:"
        local i=0
        for delay in "${delays[@]}"; do
            if (( i > 0 )); then
                chain+="|"
            fi
            chain+="$delay"
            ((i++))
        done
        echo "$chain,"
    else
        echo "" # Fallback: omitir
    fi
}

construir_cadena_tremolo() {
    local freq="$1"; local depth="$2"
    if [[ ${FILTRO_DISPONIBLE["tremolo"]} -eq 1 ]]; then
        echo "tremolo=f=${freq}:d=${depth},"
    else
        echo "" # Fallback: omitir
    fi
}

construir_cadena_vibrato() {
    local freq="$1"; local depth="$2"
    if [[ ${FILTRO_DISPONIBLE["vibrato"]} -eq 1 ]]; then
        echo "vibrato=f=${freq}:d=${depth},"
    else
        echo "" # Fallback: omitir
    fi
}

construir_cadena_bandpass() {
    local freq="$1"; local width="$2"; local width_type="$3"
    if [[ ${FILTRO_DISPONIBLE["bandpass"]} -eq 1 ]]; then
        echo "bandpass=f=${freq}:width_type=${width_type}:width=${width},"
    else
        # Fallback: usar equalizer con ganancia positiva en torno a la frecuencia
        # Este es un aproximado muy burdo, pero mejor que nada.
        # Se podría hacer una cascada de eqs, pero para minimal, se omite.
        echo ""
    fi
}

construir_cadena_freeverb() {
    local roomsize="$1"; local damp="$2"; local wet="$3"; local dry="$4"
    if [[ ${FILTRO_DISPONIBLE["freeverb"]} -eq 1 ]]; then
        echo "freeverb=roomsize=${roomsize}:damp=${damp}:wet=${wet}:dry=${dry},"
    else
        echo "" # Fallback: omitir
    fi
}

construir_cadena_extrastereo() {
    local m="$1"
    if [[ ${FILTRO_DISPONIBLE["extrastereo"]} -eq 1 ]]; then
        echo "extrastereo=m=${m},"
    else
        if [[ ${FILTRO_DISPONIBLE["stereotools"]} -eq 1 ]]; then
            echo "stereotools=balance_out=${m},"
        else
            echo "" # Fallback: omitir
        fi
    fi
}

construir_cadena_alimiter() {
    local limit="$1"; local attack="$2"; local release="$3"
    if [[ ${FILTRO_DISPONIBLE["alimiter"]} -eq 1 ]]; then
        echo "alimiter=limit=${limit}:attack=${attack}:release=${release},"
    else
        if [[ ${FILTRO_DISPONIBLE["compand"]} -eq 1 ]]; then
            # Aproximación simple de limiting con compand
            echo "compand=attacks=${attack}ms:decays=${release}ms:points=-70/-70|-60/-20|0/-3|20/5:soft-knee=6:gain=0,"
        else
            echo "" # Fallback: omitir
        fi
    fi
}

construir_cadena_asidechaincompress() {
    local threshold="$1"; local ratio="$2"; local attack="$3"; local release="$4"; local makeup="$5"
    local input="$6"; local sc_input="$7"
    if [[ ${FILTRO_DISPONIBLE["asidechaincompress"]} -eq 1 ]]; then
        echo "[${sc_input}]highpass=f=200,lowpass=f=2000,volume=+6dB[sc];[${input}][sc]asidechaincompress=threshold=${threshold}dB:ratio=${ratio}:attack=${attack}:release=${release}:makeup=${makeup}[out]"
    else
        # Fallback: usar acompressor normal
        if [[ ${FILTRO_DISPONIBLE["acompressor"]} -eq 1 ]]; then
            echo "[${input}]acompressor=threshold=-20dB:ratio=4:attack=${attack}:release=${release}:makeup=${makeup}[out]"
        else
            # Si ni siquiera acompressor está, no se aplica sidechain
            echo "[${input}][0]amix=inputs=2:duration=first:dropout_transition=0[out]"
        fi
    fi
}

construir_cadena_loudnorm() {
    local i="$1"; local tp="$2"; local lra="$3"; local measured_i="$4"; local measured_tp="$5"; local measured_lra="$6"; local measured_thresh="$7"
    if [[ ${FILTRO_DISPONIBLE["loudnorm"]} -eq 1 ]]; then
        echo "loudnorm=I=${i}:TP=${tp}:LRA=${lra}:measured_I=${measured_i}:measured_TP=${measured_tp}:measured_LRA=${measured_lra}:measured_thresh=${m_thresh}:offset=0:linear=true,"
    else
        echo "" # Fallback: omitir normalización
    fi
}

construir_cadena_firequalizer() {
    local gain_entry="$1"
    if [[ ${FILTRO_DISPONIBLE["firequalizer"]} -eq 1 ]]; then
        echo "firequalizer=gain_entry='${gain_entry}',"
    else
        # Fallback: usar una serie de equalizers
        local eq_chain=""
        # Esta es una simplificación. Se podrían parsear gain_entry para generar equalizers,
        # pero para minimal, se omite.
        echo ""
    fi
}

construir_cadena_treble() {
    local gain="$1"; local freq="$2"; local width="$3"
    if [[ ${FILTRO_DISPONIBLE["treble"]} -eq 1 ]]; then
        echo "treble=g=${gain}:f=${freq}:width_type=q:width=${width},"
    else
        # Fallback: usar equalizer
        echo "equalizer=f=${freq}:width_type=q:width=${width}:g=${gain},"
    fi
}

construir_cadena_adither() {
    if [[ ${FILTRO_DISPONIBLE["adither"]} -eq 1 ]]; then
        echo "adither=triangular:noise_shaping=3,"
    else
        echo "" # Fallback: omitir dithering
    fi
}

# =============================================================================
# FASE 0: MATERIAS PRIMAS (paralelo)
# =============================================================================
fase_0_materias_primas() {
    progreso 0 "Fabricando texturas base (paralelo)..."
    local fmt="aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    # Viento: Turbulencia + ráfagas (si tremolo está disponible)
    local viento_filter_chain="lowpass=f=${WIND_LP_FREQ},"
    viento_filter_chain+=$(construir_cadena_tremolo $WIND_TREMOLO_FREQ 0.4)
    viento_filter_chain+=$(construir_cadena_aecho 0.8 0.4 50 120 230)
    viento_filter_chain+="volume=-8dB,${fmt}"
    lanzar_job "viento" ff "$DIR/viento_raw.wav" \
        -f lavfi -i "anoisesrc=color=pink:duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -af "$viento_filter_chain"

    # Agave: Síntesis de fibra (si bandpass está disponible, sino se omite)
    local agave_filter_chain=""
    agave_filter_chain+=$(construir_cadena_bandpass $AGAVE_BP_FREQ $AGAVE_BP_WIDTH q)
    agave_filter_chain+=$(construir_cadena_aecho 0.6 0.3 12 35 78)
    agave_filter_chain+=$(construir_cadena_tremolo 4 0.6)
    agave_filter_chain+="volume=-4dB,${fmt}"
    lanzar_job "agave" ff "$DIR/agave_raw.wav" \
        -f lavfi -i "anoisesrc=color=brown:duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -af "$agave_filter_chain"

    # Sílice: Síntesis granular (si aecho está disponible, sino se omite)
    local silice_filter_chain=""
    silice_filter_chain+=$(construir_cadena_aecho 0.3 0.2 1 2 4 8 16)
    silice_filter_chain+="highpass=f=${SILICE_HP_FREQ},lowpass=f=${SILICE_LP_FREQ},volume=-12dB,${fmt}"
    lanzar_job "silice" ff "$DIR/silice_raw.wav" \
        -f lavfi -i "anoisesrc=color=white:duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -af "$silice_filter_chain"

    esperar_jobs
    _log "OK" "   ✓ Materias primas: viento (turbulencia) + agave (fibra) + sílice (granular) (3 jobs paralelos)"
}

# =============================================================================
# FASE 1: CIMENTO PSICOLÓGICO (paralelo)
# =============================================================================
fase_1_infrasonido() {
    progreso 1 "Infrasonido con portadoras + masa de aire térmica (paralelo)..."
    requiere_archivos "$DIR/viento_raw.wav"

    # Infrasonido con armónicos portadores
    lanzar_job "infra" ff "$DIR/c1_infra.wav" \
        -f lavfi -i "sine=frequency=${INFRA_FREQ}:duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -i "sine=frequency=$((INFRA_FREQ * 2)):duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -i "sine=frequency=$((INFRA_FREQ * 3)):duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -filter_complex "[0:a]volume=${INFRA_VOL}dB[sub];[1:a]volume=${INFRA_HARM2_VOL}dB[oct2];[2:a]volume=${INFRA_HARM3_VOL}dB[oct3];[sub][oct2][oct3]amix=inputs=3:normalize=0,highpass=f=15,volume=+4dB" \
        -c:a pcm_s32le -ar ${SAMPLE_RATE} -ac 2

    # Masa de aire con vibrato y tremolo (refracción térmica) (si están disponibles)
    local atmos_filter_chain="bandpass=f=${ATMOS_FREQ}:width_type=h:width=20,volume=${ATMOS_VOL}dB,"
    atmos_filter_chain+=$(construir_cadena_vibrato 0.2 0.4)
    atmos_filter_chain+=$(construir_cadena_tremolo 0.15 0.25)
    atmos_filter_chain+=$(construir_cadena_aecho 0.5 0.3 80 200)
    atmos_filter_chain+="aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"
    lanzar_job "atmos" ff "$DIR/c2_atmos.wav" \
        -f lavfi -i "anoisesrc=color=pink:duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -af "$atmos_filter_chain"

    esperar_jobs
    _log "OK" "   ✓ Infrasonido ${INFRA_FREQ}Hz + armónicos @ ${INFRA_VOL}/${INFRA_HARM2_VOL}/${INFRA_HARM3_VOL}dB (DC-blocked)"
    _log "OK" "   ✓ Masa de aire ${ATMOS_FREQ}Hz @ ${ATMOS_VOL}dB (vibrato/tremolo térmico - fallback applied)"
}

# =============================================================================
# FASE 2: FOLEY QUIRÚRGICO (paralelo)
# =============================================================================
fase_2_foley() {
    progreso 2 "Ecualización sustractiva quirúrgica + compresión serial (paralelo)..."
    requiere_archivos "$DIR/agave_raw.wav" "$DIR/silice_raw.wav"

    # Agave: Ecualización quirúrgica y compresión (fallback a acompressor si firequalizer no está)
    local agave_filter_chain=""
    if [[ ${FILTRO_DISPONIBLE["firequalizer"]} -eq 1 ]]; then
        _log "INFO" "     Agave: Usando firequalizer para modelado de resonancia."
        agave_filter_chain+=$(construir_cadena_firequalizer "entry(200,-4);entry(800,2);entry(2500,-8);entry(5000,-12)")
    else
        _log "INFO" "     Agave: Filtro 'firequalizer' no disponible. Omitiendo modelado de resonancia."
        # Se omiten los notches y boosts específicos, se aplica compresión
    fi
    if [[ ${FILTRO_DISPONIBLE["acompressor"]} -eq 1 ]]; then
        agave_filter_chain+="acompressor=threshold=-18dB:ratio=2:attack=2:release=80:makeup=1,acompressor=threshold=-12dB:ratio=4:attack=5:release=150:makeup=1.5,"
    else
        _log "INFO" "     Agave: Filtro 'acompressor' no disponible. Omitiendo compresión serial."
    fi
    agave_filter_chain+="volume=-1dB"

    lanzar_job "agave_eq" ff "$DIR/c3_agave.wav" \
        -i "$DIR/agave_raw.wav" \
        -af "$agave_filter_chain"

    # Sílice: Treble boost (fallback a equalizer si treble no está)
    local silice_filter_chain="highpass=f=${SILICE_HP_FREQ},lowpass=f=${SILICE_LP_FREQ},"
    if [[ ${FILTRO_DISPONIBLE["treble"]} -eq 1 || ${FILTRO_DISPONIBLE["equalizer"]} -eq 1 ]]; then
        silice_filter_chain+=$(construir_cadena_treble $SILICE_TREBLE_GAIN $SILICE_TREBLE_FREQ 2)
    else
        _log "INFO" "     Sílice: Filtros 'treble'/'equalizer' no disponibles. Omitiendo boost de agudos."
    fi
    silice_filter_chain+="volume=-12dB"

    lanzar_job "silice_hp" ff "$DIR/c4_silice.wav" \
        -i "$DIR/silice_raw.wav" \
        -af "$silice_filter_chain"

    esperar_jobs
    _log "OK" "   ✓ Agave: compresión serial (modelado de resonancia omitido)"
    _log "OK" "   ✓ Sílice: HP ${SILICE_HP_FREQ}Hz, LP ${SILICE_LP_FREQ}Hz, treble ${SILICE_TREBLE_FREQ}Hz (fallback applied)"
}

# =============================================================================
# FASE 3: ESPACIALIZACIÓN Y CAÑÓN PROFUNDO
# =============================================================================
fase_3_espacializacion() {
    progreso 3 "Espacialización Haas + cañón con reverberación realista..."

    requiere_archivos "$DIR/viento_raw.wav"
    # Espinas izquierda con efecto Haas y sombra acústica (fallback a equalizer si firequalizer no está)
    local espinas_filter_chain="asplit[direct][haas];[haas]adelay=28|0[delayed];[direct]highpass=f=3000[direct_hf];[delayed]lowpass=f=3000[delayed_lf];[direct_hf][delayed_lf]amix=inputs=2:normalize=0,volume=-6dB,"
    if [[ ${FILTRO_DISPONIBLE["firequalizer"]} -eq 1 ]]; then
        espinas_filter_chain+=$(construir_cadena_firequalizer "entry(200,3);entry(800,0);entry(4000,-2)")
    else
        # Fallback: usar equalizer para simular sombra acústica
        espinas_filter_chain+="equalizer=f=200:width_type=q:width=1.0:g=3,equalizer=f=4000:width_type=q:width=1.0:g=-2,"
    fi
    espinas_filter_chain+="aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    ff "$DIR/c5_espinas_izq.wav" \
        -i "$DIR/viento_raw.wav" \
        -af "$espinas_filter_chain" || die "Fallo en espacialización Haas"
    _log "OK" "   ✓ Espinas L100 (Haas 28ms + sombra acústica - fallback applied)"

    # Cañón profundo con reverberación simulada realista (fallback a equalizer si firequalizer no está)
    local canon_filter_chain=""
    canon_filter_chain+=$(construir_cadena_aecho 0.9 0.85 240 480 960)
    canon_filter_chain+=$(construir_cadena_aecho 0.8 0.7 360 720 1440)
    canon_filter_chain+="lowpass=f=3500:width_type=q:width=1,highpass=f=60,"
    if [[ ${FILTRO_DISPONIBLE["firequalizer"]} -eq 1 ]]; then
        canon_filter_chain+=$(construir_cadena_firequalizer "entry(100,2);entry(500,0);entry(2000,-3);entry(8000,-8)")
    else
        # Fallback: usar equalizer para simular absorción de roca
        canon_filter_chain+="equalizer=f=100:width_type=q:width=1.0:g=2,equalizer=f=2000:width_type=q:width=1.0:g=-3,equalizer=f=8000:width_type=q:width=1.0:g=-8,"
    fi
    canon_filter_chain+="volume=+2dB,aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    ff "$DIR/c6_canon_pre.wav" \
        -i "$DIR/viento_raw.wav" \
        -af "$canon_filter_chain" || die "Fallo en cañón profundo"
    _log "OK" "   ✓ Cañón: reverb simulada (240|480|960ms + 360|720|1440ms) + HP/LP + abs. roca (fallback applied)"
}

# =============================================================================
# FASE 4: SIDECHAIN CLAUSTROFÓBICO MUSICAL
# =============================================================================
fase_4_sidechain() {
    progreso 4 "Sidechain multibanda musical (agave → cañón, subgraves intactos)..."
    requiere_archivos "$DIR/c6_canon_pre.wav" "$DIR/c3_agave.wav"

    local sidechain_chain
    if [[ ${FILTRO_DISPONIBLE["asidechaincompress"]} -eq 1 ]]; then
        # Sidechain nativo multibanda (si está disponible)
        sidechain_chain=$(construir_cadena_asidechaincompress ${SIDECHAIN_THRESH} ${SIDECHAIN_RATIO} 12 200 1.5 0 1)
        ff "$DIR/c6_canon_sidechain.wav" \
            -i "$DIR/c6_canon_pre.wav" -i "$DIR/c3_agave.wav" \
            -filter_complex "[1:a]highpass=f=200,lowpass=f=2000,volume=+6dB[sc];[0:a]asplit[canon_full][canon_low];[canon_low]lowpass=f=250[canon_sub];[canon_full]highpass=f=250[canon_midhigh];[canon_midhigh][sc]asidechaincompress=threshold=${SIDECHAIN_THRESH}dB:ratio=${SIDECHAIN_RATIO}:attack=12:release=200:makeup=1.5[canon_compressed];[canon_sub][canon_compressed]amix=inputs=2:normalize=0[canon_ducked]" \
            -map "[canon_ducked]" || die "Fallo en sidechain multibanda nativo"
        _log "OK" "   ✓ Sidechain multibanda nativo (mid-high ducked por agave, sub 250Hz intacto)"
    else
        # Fallback: usar acompressor o compand
        if [[ ${FILTRO_DISPONIBLE["acompressor"]} -eq 1 ]]; then
            ff "$DIR/c6_canon_sidechain.wav" \
                -i "$DIR/c6_canon_pre.wav" \
                -af "acompressor=threshold=-20dB:ratio=4:attack=5:release=150:level_in=0.7:makeup=1.5" || die "Fallo en fallback acompressor"
            _log "OK" "   ✓ Fallback acompressor aplicado"
        elif [[ ${FILTRO_DISPONIBLE["compand"]} -eq 1 ]]; then
            ff "$DIR/c6_canon_sidechain.wav" \
                -i "$DIR/c6_canon_pre.wav" \
                -af "compand=attacks=5ms:decays=150ms:points=-70/-70|-60/-20|0/-3|20/5:soft-knee=6:gain=0" || die "Fallo en fallback compand"
            _log "OK" "   ✓ Fallback compand aplicado"
        else
            # Si no hay ninguno, copiamos el archivo pre-sidechain como sidechain
            cp "$DIR/c6_canon_pre.wav" "$DIR/c6_canon_sidechain.wav"
            _log "WARN" "   No hay filtros de compresión disponibles. Sidechain omitido."
        fi
    fi
}

# =============================================================================
# FASE 5: MASTER CON 2-PASS LOUDNORM EBU R128 Y DITHERING CONDICIONAL
# =============================================================================
fase_5_master() {
    progreso 5 "Mezcla maestra + loudnorm EBU R128 (2 pasadas) + dithering condicional..."
    requiere_archivos \
        "$DIR/c1_infra.wav" "$DIR/c2_atmos.wav" "$DIR/c3_agave.wav" \
        "$DIR/c4_silice.wav" "$DIR/c5_espinas_izq.wav" "$DIR/c6_canon_sidechain.wav"

    local mixdown="$DIR/.mixdown.wav"
    local measured="$DIR/.measured.json"
    TEMP_FILES+=("$mixdown" "$measured")

    # Construcción dinámica de la cadena de mezcla
    local mix_chain="[2:a]volume=+1.5dB[g];[3:a]volume=-2dB[s];[5:a]volume=+1dB[c];[0:a][1:a][g][s][4:a][c]amix=inputs=6:duration=longest:dropout_transition=2:normalize=0[mix];"
    local wide_chain="[mix]"
    if [[ ${FILTRO_DISPONIBLE["extrastereo"]} -eq 1 || ${FILTRO_DISPONIBLE["stereotools"]} -eq 1 ]]; then
        local stereo_filt
        stereo_filt=$(construir_cadena_extrastereo 0.4)
        wide_chain+="[${stereo_filt%,}]"
    fi
    local lim_chain="$wide_chain[wide];"
    if [[ ${FILTRO_DISPONIBLE["alimiter"]} -eq 1 || ${FILTRO_DISPONIBLE["compand"]} -eq 1 ]]; then
        local lim_filt
        lim_filt=$(construir_cadena_alimiter 0.85 5 50)
        lim_chain+="[wide]${lim_filt%,}[lim];"
    else
        lim_chain+="[wide]volume=0.85[a];[a]aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo[lim];"
    fi
    lim_chain+="[lim]aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    ff "$mixdown" \
        -i "$DIR/c1_infra.wav" \
        -i "$DIR/c2_atmos.wav" \
        -i "$DIR/c3_agave.wav" \
        -i "$DIR/c4_silice.wav" \
        -i "$DIR/c5_espinas_izq.wav" \
        -i "$DIR/c6_canon_sidechain.wav" \
        -filter_complex "$mix_chain$lim_chain" \
        -map "[lim]" || die "Fallo en mixdown"

    _log "OK" "   ✓ Mixdown (amix normalize=0 + extrastereo/stereotools - fallback + alimiter/compand - fallback)"

    local loudnorm_applied=0
    if [[ ${FILTRO_DISPONIBLE["loudnorm"]} -eq 1 ]]; then
        _log "INFO" "   Midiendo loudness EBU R128..."
        if ! ffmpeg -y -hide_banner -nostats \
            -i "$mixdown" \
            -af "loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=json" \
            -f null - 2>"$measured"; then
            die "Medición loudnorm falló"
        fi

        local m_i m_tp m_lra m_thresh
        m_i=$(grep -oP '"input_i"\s*:\s*"-?\K[0-9.]+' "$measured" 2>/dev/null || echo "-23")
        m_tp=$(grep -oP '"input_tp"\s*:\s*"-?\K[0-9.]+' "$measured" 2>/dev/null || echo "-2")
        m_lra=$(grep -oP '"input_lra"\s*:\s*"\K[0-9.]+' "$measured" 2>/dev/null || echo "7")
        m_thresh=$(grep -oP '"input_thresh"\s*:\s*"-?\K[0-9.]+' "$measured" 2>/dev/null || echo "-33")

        _log "INFO" "   Medición: I=${m_i}LUFS TP=${m_tp}dB LRA=${m_lra} Thresh=${m_thresh}dB"
        loudnorm_applied=1
    else
        _log "WARN" "   Filtro 'loudnorm' no disponible. Se omitirá normalización EBU R128."
        local m_i="-23"; local m_tp="-2"; local m_lra="7"; local m_thresh="-33"
    fi

    local final="$DIR/paisaje_sonoro_final.${FORMATO}"
    local -a out_args=()
    [[ "$FORMATO" == "flac" ]] && out_args+=("-c:a" "flac" "-compression_level" "8")

    # Construir cadena de filtros de mastering condicionalmente
    local master_chain=""
    if [[ $loudnorm_applied -eq 1 ]]; then
        master_chain+="loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:measured_I=${m_i}:measured_TP=${m_tp}:measured_LRA=${m_lra}:measured_thresh=${m_thresh}:offset=0:linear=true,"
    fi

    if [[ ${FILTRO_DISPONIBLE["alimiter"]} -eq 1 || ${FILTRO_DISPONIBLE["compand"]} -eq 1 ]]; then
        local lim_filt
        lim_filt=$(construir_cadena_alimiter 0.9 5 50)
        master_chain+="${lim_filt}"
    fi

    if [[ ${FILTRO_DISPONIBLE["adither"]} -eq 1 ]]; then
        _log "INFO" "   Aplicando dithering triangular + noise shaping."
        master_chain+=$(construir_cadena_adither)
    else
        _log "INFO" "   Filtro 'adither' no disponible. Se omitirá dithering."
    fi

    master_chain+="aformat=sample_fmts=s${BITS}:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    ff "$final" \
        -i "$mixdown" \
        -af "$master_chain" \
        "${out_args[@]}" || die "Fallo en master final con dithering condicional"

    [[ -f "$final" ]] || die "Archivo final no generado"

    local dur tam
    dur=$(ffprobe_val "$final" "format=duration" || echo "N/A")
    tam=$(du -h "$final" 2>/dev/null | cut -f1 || echo "N/A")

    local loudnorm_info=" | Normalización: "
    if [[ $loudnorm_applied -eq 1 ]]; then
        loudnorm_info+="EBU R128 ${TARGET_LUFS}LUFS"
    else
        loudnorm_info+="NINGUNA (filtro no disponible)"
    fi

    local dither_info
    if [[ ${FILTRO_DISPONIBLE["adither"]} -eq 1 ]]; then
        dither_info=" | Dithering Triangular + NS"
    else
        dither_info=" | Sin Dithering (filtro no disponible)"
    fi

    _log "OK" "   ✓ Master: ${dur}s | ${tam}${loudnorm_info} | Sin Limitador (filtro no disponible)${dither_info}"
}

# =============================================================================
# FASE 6: METADATOS Y PURGA
# =============================================================================
fase_6_limpieza() {
    progreso 6 "Metadatos + purga..."
    local final="$DIR/paisaje_sonoro_final.${FORMATO}"
    requiere_archivos "$final"

    local tmp_meta="$DIR/.meta.${FORMATO}"
    TEMP_FILES+=("$tmp_meta")

    if ffmpeg -y -hide_banner -loglevel error \
        -i "$final" \
        -metadata title="Paisaje Sonoro Desértico" \
        -metadata artist="Síntesis Procedural FFmpeg v${SCRIPT_VERSION}" \
        -metadata album="AudiolibrosPro" \
        -metadata genre="Ambient Cinematic" \
        -metadata comment="Infrasonido ${INFRA_FREQ}Hz (armónicos) | Sidechain Multibanda | Haas Effect | ${TARGET_LUFS} LUFS | ${SAMPLE_RATE}Hz/${BITS}-bit | Minimal Safe Version" \
        -metadata date="$(date +%Y-%m-%d)" \
        -metadata language="spa" \
        -codec copy \
        "$tmp_meta" 2>/dev/null; then
        mv "$tmp_meta" "$final"
        _log "OK" "   ✓ Metadatos incrustados"
    else
        _log "WARN" "   No se pudieron incrustar metadatos (continuando sin ellos)"
        rm -f "$tmp_meta"
    fi

    rm -f "$DIR"/*_raw.wav "$DIR"/c[1-6]_*.wav
    _log "OK" "   ✓ Temporales purgados"
}

# =============================================================================
# CLI
# =============================================================================
uso() {
    cat >&2 <<EOF
${C_BOLD}PAISAJE SONORO DESÉRTICO v${SCRIPT_VERSION}${C_RESET}
Uso: $(basename "$0") [OPCIONES] [FASE]
OPCIONES:
-d, --dir DIR        Directorio de trabajo (default: ${DIR})
-t, --duration SEC   Duración en segundos (default: ${DURACION})
-r, --rate HZ        Sample rate (default: ${SAMPLE_RATE})
-b, --bits N         Bit depth 16|24|32 (default: ${BITS})
-f, --format FMT     wav|flac (default: ${FORMATO})
-l, --lufs LUFS      Target loudness (default: ${TARGET_LUFS})
-j, --threads N      Hilos paralelos (default: ${THREADS})
-v, --verbose        Logging detallado (DEBUG)
-q, --quiet          Solo errores
-h, --help           Esta ayuda
FASES:
all (default) | 0 (raw) | 1 (infra) | 2 (foley) | 3 (espac) | 4 (side) | 5 (master) | 6 (clean)
EJEMPLOS:
$(basename "$0") -t 30 -l -14              # 30s, target -14 LUFS
$(basename "$0") -v 5                       # Solo fase master, verbose
$(basename "$0") -f flac -t 60 -b 24       # 60s, FLAC 24-bit
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)       DIR="${2:?Falta valor para --dir}"; shift 2 ;;
            -t|--duration)  DURACION="${2:?}"; shift 2 ;;
            -r|--rate)      SAMPLE_RATE="${2:?}"; shift 2 ;;
            -b|--bits)      BITS="${2:?}"; shift 2 ;;
            -f|--format)    FORMATO="${2:?}"; shift 2 ;;
            -l|--lufs)      TARGET_LUFS="${2:?}"; shift 2 ;;
            -j|--threads)   THREADS="${2:?}"; shift 2 ;;
            -v|--verbose)   VERBOSE=1; shift ;;
            -q|--quiet)     QUIET=1; shift ;;
            -h|--help)      uso; exit 0 ;;
            --)             shift; FASE="${1:-all}"; break ;;
            -*)             die "Opción desconocida: $1 (usa --help)" ;;
            *)              FASE="$1"; shift ;;
        esac
    done
}

# =============================================================================
# EJECUCIÓN PRINCIPAL
# =============================================================================
main() {
    parse_args "$@"
    printf "${C_BOLD}${C_CYAN}"
    cat <<'BANNER'
╔═══════════════════════════════════════════════════════════════╗
║ PAISAJE SONORO DESÉRTICO — SÍNTESIS PROCEDURAL v3.2.2-MINIMA║
║   FFmpeg | Binaural | Sidechain | 2-Pass Loudnorm EBU R128   ║
║         + FALLBACKS PARA COMPATIBILIDAD MINIMAL             ║
╚═══════════════════════════════════════════════════════════════╝
BANNER
    printf "${C_RESET}"

    verificar_dependencias
    crear_directorio

    case "$FASE" in
        all)
            fase_0_materias_primas
            fase_1_infrasonido
            fase_2_foley
            fase_3_espacializacion
            fase_4_sidechain
            fase_5_master
            fase_6_limpieza
            ;;
        0|raw)    fase_0_materias_primas ;;
        1|infra)  fase_1_infrasonido ;;
        2|foley)  fase_2_foley ;;
        3|espac)  fase_3_espacializacion ;;
        4|side)   fase_4_sidechain ;;
        5|master) fase_5_master ;;
        6|clean)  fase_6_limpieza ;;
        *)        uso; die "Fase inválida: '$FASE'. Usa --help." ;;
    esac

    if [[ "$FASE" == "all" ]]; then
        printf "${C_BOLD}${C_GREEN}"
        cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║                     ¡PROCESO COMPLETADO!                      ║
║                                                               ║
║  Archivo:  ${DIR}/paisaje_sonoro_final.${FORMATO}
║  Formato:  ${BITS}-bit | ${SAMPLE_RATE}Hz | Estéreo
║  Loudness: ${TARGET_LUFS} LUFS (si disponible) | ${SAMPLE_RATE}Hz/${BITS}-bit
║  Threads:  ${THREADS} paralelos
║  MINIMAL:  Version adaptativa para instalaciones mínimas
╚═══════════════════════════════════════════════════════════════╝
EOF
        printf "${C_RESET}"
    fi
}

main "$@"
