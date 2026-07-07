#!/usr/bin/env bash
# =============================================================================
# PAISAJE SONORO DESÉRTICO — SÍNTESIS PROCEDURAL v3.3.0
# -----------------------------------------------------------------------------
# Punto de entrada principal. Carga la librería modular en scripts/lib/ y
# delega la ejecución a las funciones de fase.
#
# La lógica está dividida en:
#   scripts/lib/common.sh  — logging, cleanup, dependencias, paths, helpers
#   scripts/lib/filters.sh — constructores de cadenas de filtros con fallbacks
#   scripts/lib/phases.sh  — fases 0 a 6 del pipeline
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ─── CARGA DE LIBRERÍA ───────────────────────────────────────────────────────
# Resolver paths absolutos antes de sourcear common.sh (que redefine LIB_DIR)
_RENDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RENDER_LIB="${_RENDER_DIR}/lib"

# Validar que la librería existe antes de continuar
for _lib in common.sh filters.sh phases.sh; do
    [[ -f "${_RENDER_LIB}/${_lib}" ]] || {
        echo "ERROR: Falta librería: ${_RENDER_LIB}/${_lib}" >&2
        exit 1
    }
done

# shellcheck source=lib/common.sh
source "${_RENDER_LIB}/common.sh"
# shellcheck source=lib/filters.sh
source "${_RENDER_LIB}/filters.sh"
# shellcheck source=lib/phases.sh
source "${_RENDER_LIB}/phases.sh"
unset _RENDER_DIR _RENDER_LIB _lib

# =============================================================================
# CLI
# =============================================================================
uso() {
    cat >&2 <<EOF
${C_BOLD}PAISAJE SONORO DESÉRTICO v${SCRIPT_VERSION}${C_RESET}
Síntesis procedural de audio con FFmpeg.

Uso: $(basename "$0") [OPCIONES] [FASE]

OPCIONES:
  -d, --dir DIR        Directorio de salida (default: ${PROJECT_ROOT}/output)
  -t, --duration SEC   Duración en segundos (default: ${DURACION})
  -r, --rate HZ        Sample rate (default: ${SAMPLE_RATE})
  -b, --bits N         Bit depth 16|24|32 (default: ${BITS})
  -f, --format FMT     wav|flac (default: ${FORMATO})
  -l, --lufs LUFS      Target loudness (default: ${TARGET_LUFS})
  -j, --threads N      Hilos paralelos (default: \$(nproc) = ${THREADS})
  -L, --log FILE       Escribir log a FILE (además de stderr)
  -v, --verbose        Logging detallado (DEBUG)
  -q, --quiet          Solo errores
  -h, --help           Esta ayuda

FASES:
  all (default) | 0 (raw) | 1 (infra) | 2 (foley) | 3 (espac)
                | 4 (side)  | 5 (master) | 6 (clean)

EJEMPLOS:
  $(basename "$0") -t 30 -l -14               # 30s, target -14 LUFS
  $(basename "$0") -v 5                        # Solo fase master, verbose
  $(basename "$0") -f flac -t 60 -b 24        # 60s, FLAC 24-bit
  $(basename "$0") --log render.log -t 120    # 120s con log a archivo
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)       DIR="${2:?Falta valor para --dir}"; shift 2 ;;
            -t|--duration)  DURACION="${2:?Falta valor para --duration}"; shift 2 ;;
            -r|--rate)      SAMPLE_RATE="${2:?Falta valor para --rate}"; shift 2 ;;
            -b|--bits)      BITS="${2:?Falta valor para --bits}"; shift 2 ;;
            -f|--format)    FORMATO="${2:?Falta valor para --format}"; shift 2 ;;
            -l|--lufs)      TARGET_LUFS="${2:?Falta valor para --lufs}"; shift 2 ;;
            -j|--threads)   THREADS="${2:?Falta valor para --threads}"; shift 2 ;;
            -L|--log)       LOG_FILE="${2:?Falta valor para --log}"; shift 2 ;;
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
    # shellcheck disable=SC2059
    printf "${C_BOLD}${C_CYAN}"
    cat <<'BANNER'
╔═══════════════════════════════════════════════════════════════╗
║  PAISAJE SONORO DESÉRTICO — SÍNTESIS PROCEDURAL v3.3.0        ║
║   FFmpeg | Binaural | Sidechain | 2-Pass Loudnorm EBU R128    ║
║         + FALLBACKS PARA COMPATIBILIDAD MINIMAL              ║
╚═══════════════════════════════════════════════════════════════╝
BANNER
    # shellcheck disable=SC2059
    printf "${C_RESET}"

    # Inicializar log a archivo si se pidió
    if [[ -n "$LOG_FILE" ]]; then
        : > "$LOG_FILE" || die "No se pudo escribir en log: $LOG_FILE"
        _log "INFO" "Logfile: $LOG_FILE"
    fi

    validar_parametros
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
        # shellcheck disable=SC2059
        printf "${C_BOLD}${C_GREEN}"
        cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║                     ¡PROCESO COMPLETADO!                      ║
║                                                               ║
║  Archivo:  ${DIR}/paisaje_sonoro_final.${FORMATO}
║  Formato:  ${BITS}-bit | ${SAMPLE_RATE}Hz | Estéreo
║  Loudness: ${TARGET_LUFS} LUFS (target)
║  Threads:  ${THREADS} paralelos
║  Versión:  v${SCRIPT_VERSION}
╚═══════════════════════════════════════════════════════════════╝
EOF
        # shellcheck disable=SC2059
        printf "${C_RESET}"
    fi
}

main "$@"
