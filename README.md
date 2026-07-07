# Paisaje Sonoro Desértico

[![CI](https://github.com/cirugx/Sonidos/actions/workflows/ci.yml/badge.svg)](https://github.com/cirugx/Sonidos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-3.3.0-blue.svg)](CHANGELOG.md)

Proyecto de **síntesis procedural de audio** con FFmpeg y Bash que genera un
paisaje sonoro ambiental desértico. El pipeline está dividido en 7 fases
independientes (síntesis → espacialización → sidechain → masterización) con
**fallbacks automáticos** para instalaciones mínimas de FFmpeg.

- **Sin muestras externas**: todo se sintetiza a partir de `anoisesrc` y `sine`.
- **Fail-safe**: si un filtro no está disponible, se sustituye o se omite con warn.
- **Portable**: compatible con FFmpeg 4.x y 5.x, en Linux/macOS/WSL.
- **Modular**: lógica separada en `scripts/lib/{common,filters,phases}.sh`.

---

## Requisitos

| Dependencia | Versión mínima | Notas                                  |
|-------------|----------------|----------------------------------------|
| `ffmpeg`    | 4.0            | Incluye `ffprobe`                      |
| `bash`      | 4.0            | Usa arrays asociativos                 |

Opcional para desarrollo:

| Herramienta  | Uso                              |
|--------------|----------------------------------|
| `shellcheck` | Linting (`make lint`)            |
| `make`       | Atajos del `Makefile`            |

### Instalación de dependencias

```bash
# Debian / Ubuntu
sudo apt install ffmpeg

# Fedora
sudo dnf install ffmpeg

# Arch
sudo pacman -S ffmpeg

# macOS (Homebrew)
brew install ffmpeg

# Windows: descarga desde https://ffmpeg.org/download.html
```

---

## Quickstart

```bash
# 1. Clonar
git clone https://github.com/cirugx/Sonidos.git
cd Sonidos

# 2. Render completo (10s, 48kHz, 24-bit, WAV)
bash scripts/render.sh

# 3. El archivo final queda en:
#    output/paisaje_sonoro_final.wav
```

### Ejemplos comunes

```bash
# 30 segundos, target -14 LUFS (más alto para streaming)
bash scripts/render.sh -t 30 -l -14

# 60 segundos en FLAC 24-bit
bash scripts/render.sh -t 60 -f flac -b 24

# Render rápido de prueba (2s, 22050Hz, 16-bit)
bash scripts/render.sh -t 2 -r 22050 -b 16 -j 2

# Solo una fase (para iterar en mastering sin recalcular todo)
bash scripts/render.sh 5

# Logging a archivo + verbose
bash scripts/render.sh --log render.log -v -t 120
```

### Uso con Make

```bash
make render        # render completo (10s)
make render-fast   # render rápido de prueba (2s)
make render-long   # render largo (60s FLAC 24-bit)
make smoke         # test de humo
make lint          # shellcheck
make check         # lint + smoke
make clean-output  # borrar output/
make help          # ver todos los targets
```

---

## Estructura del proyecto

```
Sonidos/
├── .github/workflows/
│   └── ci.yml                    # CI: shellcheck + smoke test
├── config/
│   └── default.env               # Parámetros de diseño sonoro
├── docs/
│   ├── ARCHITECTURE.md           # Diagrama y decisiones de diseño
│   └── PHASES.md                 # Documentación de cada fase
├── output/                       # Artefactos generados (gitignored)
│   └── .gitkeep
├── scripts/
│   ├── render.sh                 # Entry point: CLI + main()
│   └── lib/
│       ├── common.sh             # Logging, cleanup, deps, paths
│       ├── filters.sh            # Constructores de filtros + fallbacks
│       └── phases.sh             # Fases 0-6 del pipeline
├── tests/
│   └── smoke.sh                  # Render de 2s + validación
├── .gitignore
├── CHANGELOG.md
├── LICENSE
├── Makefile
└── README.md
```

---

## Pipeline de síntesis

| Fase | Nombre             | Salida                                       | Paralelo |
|------|--------------------|----------------------------------------------|----------|
| 0    | Materias primas    | `viento_raw.wav`, `agave_raw.wav`, `silice_raw.wav` | Sí (3 jobs) |
| 1    | Infrasonido + aire | `c1_infra.wav`, `c2_atmos.wav`               | Sí (2 jobs) |
| 2    | Foley quirúrgico   | `c3_agave.wav`, `c4_silice.wav`              | Sí (2 jobs) |
| 3    | Espacialización    | `c5_espinas_izq.wav`, `c6_canon_pre.wav`     | Secuencial |
| 4    | Sidechain          | `c6_canon_sidechain.wav`                     | — |
| 5    | Master + loudnorm  | `paisaje_sonoro_final.{wav,flac}`            | — |
| 6    | Metadatos + purga  | (limpieza)                                   | — |

Detalle completo en [`docs/PHASES.md`](docs/PHASES.md).
Decisiones de diseño en [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Configuración

Todos los parámetros viven en [`config/default.env`](config/default.env) y
pueden sobreescribirse de tres formas (orden de prioridad):

1. **Flag CLI** (máxima prioridad): `bash scripts/render.sh -t 30 -l -14`
2. **Variable de entorno**: `DURACION=30 bash scripts/render.sh`
3. **Archivo `config/default.env`** (mínima prioridad)

Para overrides locales sin tocar el repo, crea `config/local.env`
(ignorado por git).

### Parámetros destacados

| Variable           | Default | Descripción                                |
|--------------------|---------|--------------------------------------------|
| `DURACION`         | `10`    | Duración en segundos                       |
| `SAMPLE_RATE`      | `48000` | Sample rate en Hz                          |
| `BITS`             | `24`    | Bit depth: 16, 24, 32                      |
| `FORMATO`          | `wav`   | Formato contenedor: `wav` o `flac`         |
| `TARGET_LUFS`      | `-16`   | Loudness target EBU R128                   |
| `INFRA_FREQ`       | `19`    | Frecuencia del infrasonido (Hz)            |
| `THREADS`          | `nproc` | Hilos paralelos                            |

---

## Desarrollo

### Linting

```bash
make lint   # requiere shellcheck
```

### Test de humo

```bash
make smoke   # render de 2s + validación con ffprobe
```

### CI

Cada push / PR a `main` ejecuta en GitHub Actions:
- `shellcheck` en todos los scripts (`-S warning`)
- `tests/smoke.sh`

Ver [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

---

## Licencia

[MIT](LICENSE) © cirugx
