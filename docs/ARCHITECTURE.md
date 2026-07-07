# Arquitectura

## Visión general

El proyecto es un **pipeline procedural de síntesis de audio** implementado en
Bash puro sobre FFmpeg. Genera un paisaje sonoro desértico de ~N segundos
partiendo de ruido y ondas puras, sin muestras externas.

El diseño sigue el principio **single-responsibility** y **fail-safe con
fallbacks**: si un filtro FFmpeg no está disponible en la instalación, se
sustituye por uno equivalente o se omite con un warning explícito.

```
┌─────────────────────────────────────────────────────────────────┐
│                      scripts/render.sh                          │
│                  (entry point, CLI parsing)                     │
└──────────────────────────────┬──────────────────────────────────┘
                               │ source
                               ▼
        ┌──────────────────────┴───────────────────────┐
        │                                              │
        ▼                                              ▼
┌──────────────────┐                         ┌──────────────────┐
│ scripts/lib/     │                         │ scripts/lib/     │
│ common.sh        │                         │ filters.sh       │
│ ──────────────── │                         │ ──────────────── │
│ - logging        │◄────────────────────────│ - constructores  │
│ - cleanup/trap   │  usa FILTRO_DISPONIBLE  │   de filtros     │
│ - dependencias   │                         │ - fallbacks      │
│ - paths          │                         └──────────────────┘
│ - ff() wrapper   │
│ - jobs paralelos │
└────────┬─────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ scripts/lib/phases.sh                                          │
│ ──────────────────                                             │
│ fase_0_materias_primas  →  viento_raw, agave_raw, silice_raw  │
│ fase_1_infrasonido      →  c1_infra, c2_atmos                 │
│ fase_2_foley            →  c3_agave, c4_silice                │
│ fase_3_espacializacion  →  c5_espinas_izq, c6_canon_pre       │
│ fase_4_sidechain        →  c6_canon_sidechain                 │
│ fase_5_master           →  paisaje_sonoro_final.{wav,flac}    │
│ fase_6_limpieza         →  metadatos + purga de temporales    │
└────────────────────────────────────────────────────────────────┘
```

## Decisiones de diseño

### 1. Modularización en `scripts/lib/`

El script original era un monolito de ~800 líneas. Se divide en tres
módulos con responsabilidades claras:

| Módulo         | Responsabilidad                                   |
|----------------|---------------------------------------------------|
| `common.sh`    | Infraestructura: logging, paths, deps, cleanup, wrapper FFmpeg, paralelización |
| `filters.sh`   | Constructores de cadenas de filtros con fallback automático |
| `phases.sh`    | Las 7 fases del pipeline                          |

Esto permite:
- Testear funciones aisladas.
- Reutilizar `common.sh` y `filters.sh` en otros proyectos.
- Hacer cambios en una fase sin tocar el código de CLI o logging.

### 2. Fail-safe con `FILTRO_DISPONIBLE`

Al arrancar, `verificar_dependencias()` consulta `ffmpeg -filters` y
construye un mapa `FILTRO_DISPONIBLE[name]=0|1`. Los constructores en
`filters.sh` consultan este mapa y devuelven:
- La cadena del filtro si está disponible.
- Una cadena de fallback equivalente (p. ej. `equalizer` en lugar de
  `treble`).
- Cadena vacía si no hay fallback razonable (se omite con warn).

Esto garantiza que el script corra en instalaciones mínimas (FFmpeg
sin codecs LGPL extra), degradando la calidad en lugar de fallar.

### 3. Trap con exit explícito

```bash
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup' EXIT
```

El trap original llamaba `cleanup` sin `exit`, lo que en señales como
SIGINT no terminaba el proceso y dejaba jobs en background colgados.
Los códigos de salida siguen la convención POSIX (128 + signal number).

### 4. Purga segura en `fase_6_limpieza`

```bash
if [[ "$DIR" == "${PROJECT_ROOT}/output"* ]]; then
    rm -f "$DIR"/*_raw.wav "$DIR"/c[1-6]_*.wav
else
    _log "WARN" "DIR fuera de PROJECT_ROOT/output. Purga omitida por seguridad."
fi
```

Si el usuario pasa `-d /tmp/foo` o cualquier ruta fuera del output
canónico, **no se purgan archivos**. Esto evita `rm` destructivos
cuando el directorio de salida es un path compartido.

### 5. Lock file con `$$`

El lock file contiene el PID del proceso principal. Al arrancar, si
existe, se comprueba con `kill -0 $pid` si el proceso sigue vivo. Si
lo está, se aborta (evita renders paralelos sobre el mismo output). Si
no, se trata de un lock stale y se reemplaza.

### 6. Paralelización con `JOBS` associative array

```bash
lanzar_job() { local nombre="$1"; shift; "$@" &; JOBS[$!]="$nombre"; }
esperar_jobs() {
    local fail=0
    for pid in "${!JOBS[@]}"; do
        wait "$pid" 2>/dev/null || fail=1
    done
    [[ $fail -eq 1 ]] && die "Uno o más jobs paralelos fallaron"
}
```

Permite lanzar varias fases de FFmpeg en paralelo (CPU-bound) y esperar
a todas antes de continuar. El array asocia PID → nombre humano para
logs de error.

## Flujo de datos

```
   FASE 0 (paralelo)
   anoisesrc pink ──► viento_raw.wav ─────────────┐
   anoisesrc brown ─► agave_raw.wav  ──┐          │
   anoisesrc white ─► silice_raw.wav ──┤          │
                                      │          │
   FASE 1 (paralelo)                  │          │
   sine 19/38/57Hz ─► c1_infra.wav    │          │
   pink + bandpass ─► c2_atmos.wav    │          │
                                      │          │
   FASE 2 (paralelo)                  │          │
   agave_raw + EQ + comp ─► c3_agave.wav         │
   silice_raw + HP/LP + treble ─► c4_silice.wav  │
                                                 │
   FASE 3 (secuencial)                           │
   viento_raw + Haas + EQ ─► c5_espinas_izq.wav  │
   viento_raw + aecho + EQ ─► c6_canon_pre.wav ──┤
                                                 │
   FASE 4                                        │
   c6_canon_pre + c3_agave ──► c6_canon_sidechain.wav
                                                 │
   FASE 5                                        │
   amix(c1,c2,c3,c4,c5,c6_sidechain)             │
   + extrastereo + alimiter ─► .mixdown.wav      │
                                                 │
   loudnorm 2-pass (medir + aplicar)             │
   + alimiter + adither ─► paisaje_sonoro_final.wav
                                                 │
   FASE 6                                        │
   metadatos + purga de *_raw y c[1-6]_*         │
```

## Configuración

El archivo `config/default.env` se carga al arrancar si existe. Las
variables de entorno tienen prioridad (pueden sobreescribirse con
`VAR=valor bash scripts/render.sh` o pasando flags CLI).

Para overrides locales sin tocar el repo, crea
`config/local.env` (está en `.gitignore`).

## Extensibilidad

### Añadir una fase nueva

1. Crea `fase_N_nombre()` en `scripts/lib/phases.sh`.
2. Añade el caso en el `case` de `main()` en `scripts/render.sh`.
3. Documenta en `docs/PHASES.md`.
4. Añade un test en `tests/smoke.sh` si la fase es crítica.

### Añadir un filtro con fallback

1. Crea `construir_cadena_<filtro>()` en `scripts/lib/filters.sh`.
2. Añade el nombre del filtro a `filtros_requeridos` en
   `verificar_dependencias()`.
3. La función debe consultar `FILTRO_DISPONIBLE["<filtro>"]` y devolver
   cadena vacía o un fallback.
