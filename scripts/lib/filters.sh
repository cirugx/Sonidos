#!/usr/bin/env bash
# =============================================================================
# filters.sh — Constructores de cadenas de filtros FFmpeg con fallbacks
# =============================================================================
# Cada función devuelve un fragmento de filtergraph (con coma final si encadena)
# o cadena vacía si el filtro no está disponible.
# Sourceado por render.sh a través de phases.sh.

# ─── AECO ────────────────────────────────────────────────────────────────────
# Sintaxis FFmpeg: aecho=gin:gout:delays:decays
# delays y decays son listas separadas por '|' con el mismo número de elementos.
# Esta función recibe: gain_in gain_out delay1 [delay2 ...] y asigna un decay
# fijo (0.4) por cada delay, ya que los callers originales no lo especificaban.
construir_cadena_aecho() {
    local gain_in="$1"; local gain_out="$2"; shift 2
    local delays=("$@")
    [[ ${#delays[@]} -eq 0 ]] && { echo ""; return; }
    if [[ ${FILTRO_DISPONIBLE["aecho"]} -eq 1 ]]; then
        local chain="aecho=${gain_in}:${gain_out}:"
        local decays=""
        local i=0
        for delay in "${delays[@]}"; do
            (( i > 0 )) && { chain+="|"; decays+="|"; }
            chain+="$delay"
            decays+="0.4"
            ((i++))
        done
        echo "${chain}:${decays},"
    else
        echo ""
    fi
}

# ─── TREMOLO ─────────────────────────────────────────────────────────────────
construir_cadena_tremolo() {
    local freq="$1"; local depth="$2"
    if [[ ${FILTRO_DISPONIBLE["tremolo"]} -eq 1 ]]; then
        echo "tremolo=f=${freq}:d=${depth},"
    else
        echo ""
    fi
}

# ─── VIBRATO ─────────────────────────────────────────────────────────────────
construir_cadena_vibrato() {
    local freq="$1"; local depth="$2"
    if [[ ${FILTRO_DISPONIBLE["vibrato"]} -eq 1 ]]; then
        echo "vibrato=f=${freq}:d=${depth},"
    else
        echo ""
    fi
}

# ─── BANDPASS ────────────────────────────────────────────────────────────────
construir_cadena_bandpass() {
    local freq="$1"; local width="$2"; local width_type="$3"
    if [[ ${FILTRO_DISPONIBLE["bandpass"]} -eq 1 ]]; then
        echo "bandpass=f=${freq}:width_type=${width_type}:width=${width},"
    else
        # Fallback: equalizer con ganancia positiva (aproximación burda)
        echo ""
    fi
}

# ─── FREEVERB ────────────────────────────────────────────────────────────────
construir_cadena_freeverb() {
    local roomsize="$1"; local damp="$2"; local wet="$3"; local dry="$4"
    if [[ ${FILTRO_DISPONIBLE["freeverb"]} -eq 1 ]]; then
        echo "freeverb=roomsize=${roomsize}:damp=${damp}:wet=${wet}:dry=${dry},"
    else
        echo ""
    fi
}

# ─── EXTRASTEREO ─────────────────────────────────────────────────────────────
construir_cadena_extrastereo() {
    local m="$1"
    if [[ ${FILTRO_DISPONIBLE["extrastereo"]} -eq 1 ]]; then
        echo "extrastereo=m=${m},"
    elif [[ ${FILTRO_DISPONIBLE["stereotools"]} -eq 1 ]]; then
        echo "stereotools=balance_out=${m},"
    else
        echo ""
    fi
}

# ─── ALIMITER ────────────────────────────────────────────────────────────────
construir_cadena_alimiter() {
    local limit="$1"; local attack="$2"; local release="$3"
    if [[ ${FILTRO_DISPONIBLE["alimiter"]} -eq 1 ]]; then
        echo "alimiter=limit=${limit}:attack=${attack}:release=${release},"
    elif [[ ${FILTRO_DISPONIBLE["compand"]} -eq 1 ]]; then
        echo "compand=attacks=${attack}ms:decays=${release}ms:points=-70/-70|-60/-20|0/-3|20/5:soft-knee=6:gain=0,"
    else
        echo ""
    fi
}

# ─── FIREQUALIZER ────────────────────────────────────────────────────────────
# El gain_entry debe pasarse ya formateado, ej: "entry(200,-4);entry(800,2)"
construir_cadena_firequalizer() {
    local gain_entry="$1"
    if [[ ${FILTRO_DISPONIBLE["firequalizer"]} -eq 1 ]]; then
        echo "firequalizer=gain_entry='${gain_entry}',"
    else
        # Fallback: omite (la fase que lo use debe proporcionar su propio fallback EQ)
        echo ""
    fi
}

# ─── TREBLE (con fallback a equalizer) ───────────────────────────────────────
construir_cadena_treble() {
    local gain="$1"; local freq="$2"; local width="$3"
    if [[ ${FILTRO_DISPONIBLE["treble"]} -eq 1 ]]; then
        echo "treble=g=${gain}:f=${freq}:width_type=q:width=${width},"
    elif [[ ${FILTRO_DISPONIBLE["equalizer"]} -eq 1 ]]; then
        echo "equalizer=f=${freq}:width_type=q:width=${width}:g=${gain},"
    else
        echo ""
    fi
}

# ─── ADITHER ─────────────────────────────────────────────────────────────────
construir_cadena_adither() {
    if [[ ${FILTRO_DISPONIBLE["adither"]} -eq 1 ]]; then
        echo "adither=triangular:noise_shaping=3,"
    else
        echo ""
    fi
}
