#!/usr/bin/env bash
# =============================================================================
# phases.sh — Fases del pipeline de síntesis (0 a 6)
# =============================================================================
# Sourceado por render.sh. Depende de common.sh y filters.sh.

# =============================================================================
# FASE 0: MATERIAS PRIMAS (paralelo)
# =============================================================================
fase_0_materias_primas() {
    progreso 0 "Fabricando texturas base (paralelo)..."
    local fmt="aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    # Viento: Turbulencia + ráfagas (si tremolo está disponible)
    local viento_filter_chain="lowpass=f=${WIND_LP_FREQ},"
    viento_filter_chain+=$(construir_cadena_tremolo "$WIND_TREMOLO_FREQ" 0.4)
    viento_filter_chain+=$(construir_cadena_aecho 0.8 0.4 50 120 230)
    viento_filter_chain+="volume=-8dB,${fmt}"
    lanzar_job "viento" ff "$DIR/viento_raw.wav" \
        -f lavfi -i "anoisesrc=color=pink:duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -af "$viento_filter_chain"

    # Agave: Síntesis de fibra (si bandpass está disponible, sino se omite)
    local agave_filter_chain=""
    agave_filter_chain+=$(construir_cadena_bandpass "$AGAVE_BP_FREQ" "$AGAVE_BP_WIDTH" q)
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
    _log "OK" "   Materias primas: viento + agave + sílice (3 jobs paralelos)"
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
        -f lavfi -i "sine=frequency=$((INFRA_FREQ * 2)):duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -f lavfi -i "sine=frequency=$((INFRA_FREQ * 3)):duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -filter_complex "[0:a]volume=${INFRA_VOL}dB[sub];[1:a]volume=${INFRA_HARM2_VOL}dB[oct2];[2:a]volume=${INFRA_HARM3_VOL}dB[oct3];[sub][oct2][oct3]amix=inputs=3:normalize=0,highpass=f=15,volume=+4dB" \
        -c:a pcm_s32le -ar "${SAMPLE_RATE}" -ac 2

    # Masa de aire con vibrato y tremolo (refracción térmica)
    local atmos_filter_chain="bandpass=f=${ATMOS_FREQ}:width_type=h:width=20,volume=${ATMOS_VOL}dB,"
    atmos_filter_chain+=$(construir_cadena_vibrato 0.2 0.4)
    atmos_filter_chain+=$(construir_cadena_tremolo 0.15 0.25)
    atmos_filter_chain+=$(construir_cadena_aecho 0.5 0.3 80 200)
    atmos_filter_chain+="aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"
    lanzar_job "atmos" ff "$DIR/c2_atmos.wav" \
        -f lavfi -i "anoisesrc=color=pink:duration=${DURACION}:sample_rate=${SAMPLE_RATE}" \
        -af "$atmos_filter_chain"

    esperar_jobs
    _log "OK" "   Infrasonido ${INFRA_FREQ}Hz + armónicos @ ${INFRA_VOL}/${INFRA_HARM2_VOL}/${INFRA_HARM3_VOL}dB (DC-blocked)"
    _log "OK" "   Masa de aire ${ATMOS_FREQ}Hz @ ${ATMOS_VOL}dB (vibrato/tremolo térmico)"
}

# =============================================================================
# FASE 2: FOLEY QUIRÚRGICO (paralelo)
# =============================================================================
fase_2_foley() {
    progreso 2 "Ecualización sustractiva quirúrgica + compresión serial (paralelo)..."
    requiere_archivos "$DIR/agave_raw.wav" "$DIR/silice_raw.wav"

    # Agave: EQ con firequalizer o fallback a equalizers múltiples
    local agave_filter_chain=""
    if [[ ${FILTRO_DISPONIBLE["firequalizer"]} -eq 1 ]]; then
        _log "INFO" "     Agave: Usando firequalizer para modelado de resonancia."
        agave_filter_chain+=$(construir_cadena_firequalizer "entry(200,-4);entry(800,2);entry(2500,-8);entry(5000,-12)")
    elif [[ ${FILTRO_DISPONIBLE["equalizer"]} -eq 1 ]]; then
        _log "INFO" "     Agave: Fallback a equalizer en cascada."
        agave_filter_chain+="equalizer=f=200:width_type=q:width=1.0:g=-4,"
        agave_filter_chain+="equalizer=f=800:width_type=q:width=1.0:g=2,"
        agave_filter_chain+="equalizer=f=2500:width_type=q:width=1.0:g=-8,"
        agave_filter_chain+="equalizer=f=5000:width_type=q:width=1.0:g=-12,"
    else
        _log "WARN" "     Agave: Sin EQ disponible. Se omite modelado de resonancia."
    fi

    if [[ ${FILTRO_DISPONIBLE["acompressor"]} -eq 1 ]]; then
        agave_filter_chain+="acompressor=threshold=-18dB:ratio=2:attack=2:release=80:makeup=1,"
        agave_filter_chain+="acompressor=threshold=-12dB:ratio=4:attack=5:release=150:makeup=1.5,"
    else
        _log "WARN" "     Agave: Filtro 'acompressor' no disponible. Se omite compresión serial."
    fi
    agave_filter_chain+="volume=-1dB"

    lanzar_job "agave_eq" ff "$DIR/c3_agave.wav" \
        -i "$DIR/agave_raw.wav" \
        -af "$agave_filter_chain"

    # Sílice: HP/LP + treble boost (con fallback)
    local silice_filter_chain="highpass=f=${SILICE_HP_FREQ},lowpass=f=${SILICE_LP_FREQ},"
    if [[ ${FILTRO_DISPONIBLE["treble"]} -eq 1 || ${FILTRO_DISPONIBLE["equalizer"]} -eq 1 ]]; then
        silice_filter_chain+=$(construir_cadena_treble "$SILICE_TREBLE_GAIN" "$SILICE_TREBLE_FREQ" 2)
    else
        _log "WARN" "     Sílice: Filtros 'treble'/'equalizer' no disponibles. Se omite boost de agudos."
    fi
    silice_filter_chain+="volume=-12dB"

    lanzar_job "silice_hp" ff "$DIR/c4_silice.wav" \
        -i "$DIR/silice_raw.wav" \
        -af "$silice_filter_chain"

    esperar_jobs
    _log "OK" "   Agave: EQ + compresión serial aplicados"
    _log "OK" "   Sílice: HP ${SILICE_HP_FREQ}Hz, LP ${SILICE_LP_FREQ}Hz, treble ${SILICE_TREBLE_FREQ}Hz"
}

# =============================================================================
# FASE 3: ESPACIALIZACIÓN Y CAÑÓN PROFUNDO
# =============================================================================
fase_3_espacializacion() {
    progreso 3 "Espacialización Haas + cañón con reverberación realista..."
    requiere_archivos "$DIR/viento_raw.wav"

    # Espinas izquierda con efecto Haas y sombra acústica
    local espinas_filter_chain="asplit[direct][haas];[haas]adelay=28|0[delayed];[direct]highpass=f=3000[direct_hf];[delayed]lowpass=f=3000[delayed_lf];[direct_hf][delayed_lf]amix=inputs=2:normalize=0,volume=-6dB,"
    if [[ ${FILTRO_DISPONIBLE["firequalizer"]} -eq 1 ]]; then
        espinas_filter_chain+=$(construir_cadena_firequalizer "entry(200,3);entry(800,0);entry(4000,-2)")
    elif [[ ${FILTRO_DISPONIBLE["equalizer"]} -eq 1 ]]; then
        espinas_filter_chain+="equalizer=f=200:width_type=q:width=1.0:g=3,equalizer=f=4000:width_type=q:width=1.0:g=-2,"
    fi
    espinas_filter_chain+="aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    ff "$DIR/c5_espinas_izq.wav" \
        -i "$DIR/viento_raw.wav" \
        -af "$espinas_filter_chain" || die "Fallo en espacialización Haas"
    _log "OK" "   Espinas L100 (Haas 28ms + sombra acústica)"

    # Cañón profundo con reverberación simulada realista
    local canon_filter_chain=""
    canon_filter_chain+=$(construir_cadena_aecho 0.9 0.85 240 480 960)
    canon_filter_chain+=$(construir_cadena_aecho 0.8 0.7 360 720 1440)
    canon_filter_chain+="lowpass=f=3500:width_type=q:width=1,highpass=f=60,"
    if [[ ${FILTRO_DISPONIBLE["firequalizer"]} -eq 1 ]]; then
        canon_filter_chain+=$(construir_cadena_firequalizer "entry(100,2);entry(500,0);entry(2000,-3);entry(8000,-8)")
    elif [[ ${FILTRO_DISPONIBLE["equalizer"]} -eq 1 ]]; then
        canon_filter_chain+="equalizer=f=100:width_type=q:width=1.0:g=2,equalizer=f=2000:width_type=q:width=1.0:g=-3,equalizer=f=8000:width_type=q:width=1.0:g=-8,"
    fi
    canon_filter_chain+="volume=+2dB,aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    ff "$DIR/c6_canon_pre.wav" \
        -i "$DIR/viento_raw.wav" \
        -af "$canon_filter_chain" || die "Fallo en cañón profundo"
    _log "OK" "   Cañón: reverb simulada (240|480|960ms + 360|720|1440ms) + HP/LP + abs. roca"
}

# =============================================================================
# FASE 4: SIDECHAIN CLAUSTROFÓBICO MUSICAL
# =============================================================================
fase_4_sidechain() {
    progreso 4 "Sidechain multibanda musical (agave -> cañón, subgraves intactos)..."
    requiere_archivos "$DIR/c6_canon_pre.wav" "$DIR/c3_agave.wav"

    if [[ ${FILTRO_DISPONIBLE["asidechaincompress"]} -eq 1 ]]; then
        # Sidechain nativo multibanda
        ff "$DIR/c6_canon_sidechain.wav" \
            -i "$DIR/c6_canon_pre.wav" -i "$DIR/c3_agave.wav" \
            -filter_complex "[1:a]highpass=f=200,lowpass=f=2000,volume=+6dB[sc];[0:a]asplit[canon_full][canon_low];[canon_low]lowpass=f=250[canon_sub];[canon_full]highpass=f=250[canon_midhigh];[canon_midhigh][sc]asidechaincompress=threshold=${SIDECHAIN_THRESH}dB:ratio=${SIDECHAIN_RATIO}:attack=12:release=200:makeup=1.5[canon_compressed];[canon_sub][canon_compressed]amix=inputs=2:normalize=0[canon_ducked]" \
            -map "[canon_ducked]" || die "Fallo en sidechain multibanda nativo"
        _log "OK" "   Sidechain multibanda nativo (mid-high ducked por agave, sub 250Hz intacto)"
    elif [[ ${FILTRO_DISPONIBLE["acompressor"]} -eq 1 ]]; then
        ff "$DIR/c6_canon_sidechain.wav" \
            -i "$DIR/c6_canon_pre.wav" \
            -af "acompressor=threshold=-20dB:ratio=4:attack=5:release=150:level_in=0.7:makeup=1.5" \
            || die "Fallo en fallback acompressor"
        _log "WARN" "   Fallback acompressor aplicado (sin sidechain real)"
    elif [[ ${FILTRO_DISPONIBLE["compand"]} -eq 1 ]]; then
        ff "$DIR/c6_canon_sidechain.wav" \
            -i "$DIR/c6_canon_pre.wav" \
            -af "compand=attacks=5ms:decays=150ms:points=-70/-70|-60/-20|0/-3|20/5:soft-knee=6:gain=0" \
            || die "Fallo en fallback compand"
        _log "WARN" "   Fallback compand aplicado (sin sidechain real)"
    else
        cp "$DIR/c6_canon_pre.wav" "$DIR/c6_canon_sidechain.wav"
        _log "WARN" "   No hay filtros de compresión disponibles. Sidechain omitido."
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

    # Mix chain: 6 entradas (c1-c6) -> [mix]
    local mix_chain="[2:a]volume=+1.5dB[g];[3:a]volume=-2dB[s];[5:a]volume=+1dB[c];[0:a][1:a][g][s][4:a][c]amix=inputs=6:duration=longest:dropout_transition=2:normalize=0[mix];"
    # Wide chain: [mix] -> (stereo widening) -> [wide]
    local wide_chain="[mix]"
    if [[ ${FILTRO_DISPONIBLE["extrastereo"]} -eq 1 || ${FILTRO_DISPONIBLE["stereotools"]} -eq 1 ]]; then
        local stereo_filt
        stereo_filt=$(construir_cadena_extrastereo 0.4)
        # Sintaxis filter_complex: [input_label]filter=params[output_label]
        # Los [] rodean LABELS, no nombres de filtro.
        wide_chain+="${stereo_filt%,}[wide]"
    else
        wide_chain+="anull[wide]"
    fi
    # Lim chain: [wide] -> (limiting) -> [lim] -> aformat -> [final]
    # El label final [final] es el que se mapea con -map.
    local lim_chain="${wide_chain};"
    if [[ ${FILTRO_DISPONIBLE["alimiter"]} -eq 1 || ${FILTRO_DISPONIBLE["compand"]} -eq 1 ]]; then
        local lim_filt
        lim_filt=$(construir_cadena_alimiter 0.85 5 50)
        lim_chain+="[wide]${lim_filt%,}[lim];"
    else
        lim_chain+="[wide]volume=0.85[lim];"
    fi
    lim_chain+="[lim]aformat=sample_fmts=s32:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo[final]"

    ff "$mixdown" \
        -i "$DIR/c1_infra.wav" \
        -i "$DIR/c2_atmos.wav" \
        -i "$DIR/c3_agave.wav" \
        -i "$DIR/c4_silice.wav" \
        -i "$DIR/c5_espinas_izq.wav" \
        -i "$DIR/c6_canon_sidechain.wav" \
        -filter_complex "$mix_chain$lim_chain" \
        -map "[final]" || die "Fallo en mixdown"

    _log "OK" "   Mixdown aplicado (amix + widening + limiting inicial)"

    local loudnorm_applied=0
    local m_i m_tp m_lra m_thresh
    if [[ ${FILTRO_DISPONIBLE["loudnorm"]} -eq 1 ]]; then
        _log "INFO" "   Midiendo loudness EBU R128..."
        if ! ffmpeg -y -hide_banner -nostats \
            -i "$mixdown" \
            -af "loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=json" \
            -f null - 2>"$measured"; then
            die "Medición loudnorm falló"
        fi

        # Parseo portable del JSON (sin grep -P para compatibilidad BSD/macOS)
        m_i=$(sed -n 's/.*"input_i" *: *"\(-\{0,1\}[0-9.]*\)".*/\1/p' "$measured" | head -1)
        m_tp=$(sed -n 's/.*"input_tp" *: *"\(-\{0,1\}[0-9.]*\)".*/\1/p' "$measured" | head -1)
        m_lra=$(sed -n 's/.*"input_lra" *: *"\([0-9.]*\)".*/\1/p' "$measured" | head -1)
        m_thresh=$(sed -n 's/.*"input_thresh" *: *"\(-\{0,1\}[0-9.]*\)".*/\1/p' "$measured" | head -1)

        # Fallbacks si el parseo falla
        : "${m_i:=-23}"; : "${m_tp:=-2}"; : "${m_lra:=7}"; : "${m_thresh:=-33}"

        _log "INFO" "   Medición: I=${m_i}LUFS TP=${m_tp}dB LRA=${m_lra} Thresh=${m_thresh}dB"
        loudnorm_applied=1
    else
        _log "WARN" "   Filtro 'loudnorm' no disponible. Se omite normalización EBU R128."
        m_i="-23"; m_tp="-2"; m_lra="7"; m_thresh="-33"
    fi

    local final="$DIR/paisaje_sonoro_final.${FORMATO}"
    local -a out_args=()

    # Bit depth: aformat no soporta s24 (FFmpeg solo tiene s16/s32/flt/dbl/u8).
    # Para 24-bit usamos el codec pcm_s24le en la salida.
    # Para 16/32-bit podemos forzar via aformat.
    local aformat_fmt=""
    case "$BITS" in
        16) aformat_fmt="s16" ;;
        32) aformat_fmt="s32" ;;
        24) aformat_fmt="s32" ;;  # Internamente s32, codec de salida pcm_s24le
    esac

    if [[ "$FORMATO" == "flac" ]]; then
        out_args+=("-c:a" "flac" "-compression_level" "8")
        case "$BITS" in
            16) out_args+=("-sample_fmt" "s16") ;;
            24) out_args+=("-sample_fmt" "s32") ;;
            32) out_args+=("-sample_fmt" "s32") ;;
        esac
    elif [[ "$FORMATO" == "wav" ]]; then
        case "$BITS" in
            16) out_args+=("-c:a" "pcm_s16le") ;;
            24) out_args+=("-c:a" "pcm_s24le") ;;
            32) out_args+=("-c:a" "pcm_s32le") ;;
        esac
    fi

    # Cadena de mastering condicional
    local master_chain=""
    if [[ $loudnorm_applied -eq 1 ]]; then
        master_chain+="loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:measured_I=${m_i}:measured_TP=${m_tp}:measured_LRA=${m_lra}:measured_thresh=${m_thresh}:offset=0:linear=true,"
    fi

    local limiter_applied=0
    if [[ ${FILTRO_DISPONIBLE["alimiter"]} -eq 1 || ${FILTRO_DISPONIBLE["compand"]} -eq 1 ]]; then
        local lim_filt
        lim_filt=$(construir_cadena_alimiter 0.9 5 50)
        master_chain+="${lim_filt}"
        limiter_applied=1
    fi

    local dither_applied=0
    if [[ ${FILTRO_DISPONIBLE["adither"]} -eq 1 ]]; then
        _log "INFO" "   Aplicando dithering triangular + noise shaping."
        master_chain+=$(construir_cadena_adither)
        dither_applied=1
    else
        _log "INFO" "   Filtro 'adither' no disponible. Se omite dithering."
    fi

    # aformat SIEMPRE con formatos válidos (s16/s32); el bit depth real lo
    # controla el codec de salida.
    master_chain+="aformat=sample_fmts=${aformat_fmt}:sample_rates=${SAMPLE_RATE}:channel_layouts=stereo"

    ff "$final" \
        -i "$mixdown" \
        -af "$master_chain" \
        "${out_args[@]}" || die "Fallo en master final"

    [[ -f "$final" ]] || die "Archivo final no generado"

    local dur tam
    dur=$(ffprobe_val "$final" "format=duration" || echo "N/A")
    tam=$(du -h "$final" 2>/dev/null | cut -f1 || echo "N/A")

    # Mensaje de resumen correcto (no misleading)
    local norm_info="EBU R128 ${TARGET_LUFS}LUFS"
    [[ $loudnorm_applied -eq 0 ]] && norm_info="NINGUNA (filtro no disponible)"

    local lim_info="Limitador final"
    [[ $limiter_applied -eq 1 ]] && lim_info="alimiter/compand @ 0.9"
    [[ $limiter_applied -eq 0 ]] && lim_info="sin limitador final (filtro no disponible)"

    local dither_info="dithering triangular + NS"
    [[ $dither_applied -eq 0 ]] && dither_info="sin dithering (filtro no disponible)"

    _log "OK" "   Master: ${dur}s | ${tam} | ${norm_info} | ${lim_info} | ${dither_info}"
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
        -metadata comment="Infrasonido ${INFRA_FREQ}Hz (armónicos) | Sidechain Multibanda | Haas | ${TARGET_LUFS} LUFS | ${SAMPLE_RATE}Hz/${BITS}-bit" \
        -metadata date="$(date +%Y-%m-%d)" \
        -metadata language="spa" \
        -codec copy \
        "$tmp_meta" 2>/dev/null; then
        mv "$tmp_meta" "$final"
        _log "OK" "   Metadatos incrustados"
    else
        _log "WARN" "   No se pudieron incrustar metadatos (continuando sin ellos)"
        rm -f "$tmp_meta"
    fi

    # Purga segura: solo si DIR está dentro de PROJECT_ROOT/output
    if [[ "$DIR" == "${PROJECT_ROOT}/output"* ]]; then
        rm -f "$DIR"/*_raw.wav "$DIR"/c[1-6]_*.wav
        _log "OK" "   Temporales purgados"
    else
        _log "WARN" "   DIR fuera de PROJECT_ROOT/output. Purga omitida por seguridad."
    fi
}
