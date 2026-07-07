#!/usr/bin/env bash
# =============================================================================
# tests/smoke.sh — Test de humo: render de 2s y validación de salida
# =============================================================================
# Ejecuta el pipeline completo con duración mínima y verifica que el archivo
# final existe y tiene formato correcto. Sale con código != 0 si algo falla.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RENDER="${PROJECT_ROOT}/scripts/render.sh"
SMOKE_OUT="$(mktemp -d)"
trap 'rm -rf "$SMOKE_OUT"' EXIT

echo "::group::Smoke test setup"
echo "Project: ${PROJECT_ROOT}"
echo "Output:  ${SMOKE_OUT}"
echo "::endgroup::"

# Validar que las dependencias mínimas están presentes
for dep in ffmpeg ffprobe bash; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "FAIL: dependencia faltante: $dep"
        exit 2
    fi
done

# Render de 2s a 8kHz mono-ish para que sea rápido
echo "::group::Render (2s, 22050Hz, 16-bit)"
if ! bash "$RENDER" \
    -d "$SMOKE_OUT" \
    -t 2 \
    -r 22050 \
    -b 16 \
    -j 2 \
    -q; then
    echo "FAIL: render.sh salió con error"
    exit 1
fi
echo "::endgroup::"

# Validar archivo de salida
echo "::group::Validación de salida"
FINAL="${SMOKE_OUT}/paisaje_sonoro_final.wav"
if [[ ! -f "$FINAL" ]]; then
    echo "FAIL: archivo final no existe: $FINAL"
    ls -la "$SMOKE_OUT"
    exit 1
fi

# Validar que es un WAV válido y tiene duración ~2s (con tolerancia)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FINAL" 2>/dev/null || echo "0")
echo "Duración detectada: ${DUR}s"
if (( $(echo "$DUR < 1.5" | bc -l 2>/dev/null || awk "BEGIN{exit !($DUR < 1.5)}") )); then
    echo "FAIL: duración insuficiente (${DUR}s < 1.5s)"
    exit 1
fi

# Validar que es estéreo
CHANNELS=$(ffprobe -v error -show_entries stream=channels -of csv=p=0 "$FINAL" 2>/dev/null | head -1)
echo "Canales: ${CHANNELS}"
if [[ "$CHANNELS" != "2" ]]; then
    echo "FAIL: se esperaba estéreo (2 canales), se obtuvo: $CHANNELS"
    exit 1
fi

# Validar sample rate
SR=$(ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$FINAL" 2>/dev/null | head -1)
echo "Sample rate: ${SR}Hz"
if [[ "$SR" != "22050" ]]; then
    echo "FAIL: sample rate esperado 22050, se obtuvo: $SR"
    exit 1
fi

TAM=$(du -h "$FINAL" | cut -f1)
echo "::endgroup::"

echo "::group::Resultado"
echo "OK: archivo final válido"
echo "  - Path:     $FINAL"
echo "  - Tamaño:   $TAM"
echo "  - Duración: ${DUR}s"
echo "  - Canales:  $CHANNELS"
echo "  - SR:       ${SR}Hz"
echo "::endgroup::"

echo ""
echo "✓ SMOKE TEST PASSED"
