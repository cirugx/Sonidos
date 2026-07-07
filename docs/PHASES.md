# Fases del pipeline

El pipeline se divide en 7 fases numeradas (0 a 6). Cada fase se puede
ejecutar de forma independiente con `bash scripts/render.sh <número>`,
lo que es útil para iterar en una fase concreta sin recalcular las
anteriores (los artefactos intermedios se conservan en `output/`).

## Fase 0 — Materias primas (paralelo)

`bash scripts/render.sh 0`

Genera tres texturas base a partir de ruido procedural de FFmpeg:

| Archivo          | Fuente lavfi          | Características                              |
|------------------|-----------------------|----------------------------------------------|
| `viento_raw.wav` | `anoisesrc=pink`      | Lowpass 800Hz + tremolo 0.15Hz + aecho        |
| `agave_raw.wav`  | `anoisesrc=brown`     | Bandpass 800Hz (Q=3) + aecho + tremolo 4Hz   |
| `silice_raw.wav` | `anoisesrc=white`     | Aecho granular + HP 8kHz + LP 16kHz          |

Las tres se lanzan en paralelo con `lanzar_job` para aprovechar todos
los núcleos.

## Fase 1 — Infrasonido + masa de aire (paralelo)

`bash scripts/render.sh 1`

Requiere: `viento_raw.wav` (sólo para validar dependencia; no se usa directamente).

| Archivo        | Síntesis                                          |
|----------------|---------------------------------------------------|
| `c1_infra.wav` | 3 sine waves a 19/38/57Hz, mezcladas con `amix normalize=0`, highpass 15Hz para quitar DC |
| `c2_atmos.wav` | Pink noise + bandpass 55Hz (width 20Hz) + vibrato 0.2Hz + tremolo 0.15Hz + aecho |

El infrasonido a 19Hz está por debajo del umbral auditivo pero produce
sensación de tensión / presencia. Los armónicos a 38/57Hz lo hacen
"audible" psicológicamente sin que sea molesto.

## Fase 2 — Foley quirúrgico (paralelo)

`bash scripts/render.sh 2`

Requiere: `agave_raw.wav`, `silice_raw.wav`.

| Archivo         | Procesamiento                                              |
|-----------------|------------------------------------------------------------|
| `c3_agave.wav`  | firequalizer (notches en 200/2500/5000, boost 800) + 2 etapas acompressor serial |
| `c4_silice.wav` | HP 8kHz + LP 16kHz + treble +4dB @ 12kHz                   |

Si `firequalizer` no está disponible, se usa un fallback de 4
`equalizer` en cascada.

## Fase 3 — Espacialización y cañón profundo (secuencial)

`bash scripts/render.sh 3`

Requiere: `viento_raw.wav`.

| Archivo              | Procesamiento                                                |
|----------------------|--------------------------------------------------------------|
| `c5_espinas_izq.wav` | Haas effect: asplit + adelay 28ms + HP/LF crossover 3kHz + EQ sombra acústica |
| `c6_canon_pre.wav`   | 2 cadenas aecho (240/480/960ms + 360/720/1440ms) + LP 3500Hz + HP 60Hz + EQ absorción roca |

El efecto Haas genera una imagen estéreo "L100" (todo a la izquierda)
usando delay interaural en lugar de pan. El cañón profundo simula
reverberación de cañón con dos cascadas de eco que emulan reflexiones
primarias y secundarias.

## Fase 4 — Sidechain multibanda musical

`bash scripts/render.sh 4`

Requiere: `c6_canon_pre.wav`, `c3_agave.wav`.

El cañón se parte en dos bandas:
- **Sub** (< 250Hz): pasa sin tocar (los subgraves son la "masa" del cañón).
- **Mid-high** (> 250Hz): se comprime con `asidechaincompress` cuyo sidechain
  es el agave filtrado a 200-2000Hz (la "fibra" más aguda).

Resultado: cuando el agave "suena", el cañón se duckea en medios/agudos
pero el subgrave sigue intacto, dando un movimiento musical sin perder
cuerpo.

Si `asidechaincompress` no está, fallback a `acompressor` o `compand`
(sin sidechain real).

## Fase 5 — Master con 2-pass loudnorm EBU R128 + dithering

`bash scripts/render.sh 5`

Requiere: `c1_infra.wav`, `c2_atmos.wav`, `c3_agave.wav`, `c4_silice.wav`,
`c5_espinas_izq.wav`, `c6_canon_sidechain.wav`.

Pasos:
1. **Mixdown** con `amix normalize=0` (sin normalizar, se controlan
   los volúmenes individualmente: agave +1.5dB, sílice -2dB, cañón +1dB).
2. **Widening** con `extrastereo 0.4` (o fallback `stereotools`).
3. **Limiting inicial** con `alimiter 0.85` (o fallback `compand`).
4. **Medición loudnorm** (1ª pasada) → JSON con `input_i`, `input_tp`,
   `input_lra`, `input_thresh`.
5. **Aplicación loudnorm linear=true** (2ª pasada) con los valores medidos.
6. **Limiting final** con `alimiter 0.9`.
7. **Dithering** triangular con noise shaping si `adither` está disponible.

Target por defecto: **-16 LUFS, -1.5 dBTP, LRA 11** (estándar de
streaming moderno, más alto que EBU R128 broadcast).

## Fase 6 — Metadatos y purga

`bash scripts/render.sh 6`

Requiere: `paisaje_sonoro_final.{wav,flac}`.

1. Incrusta metadatos ID3/RIFF: title, artist, album, genre, comment,
   date, language.
2. Purga archivos intermedios `*_raw.wav` y `c[1-6]_*.wav` (solo si
   DIR está dentro de `PROJECT_ROOT/output` por seguridad).
3. Conserva únicamente `paisaje_sonoro_final.{wav,flac}`.

## Tabla de dependencias entre fases

```
0 ──► 1 ──► 2 ──► 3 ──► 4 ──► 5 ──► 6
       │            ▲      ▲
       └────────────┘      │
                  (c3_agave.wav)
```

- Fase 1 requiere artefacto de fase 0 (`viento_raw.wav`) sólo como
  comprobación; en realidad no lo consume.
- Fase 3 requiere `viento_raw.wav` (fase 0).
- Fase 4 requiere `c6_canon_pre.wav` (fase 3) y `c3_agave.wav` (fase 2).
- Fase 5 requiere todas las capas c1-c6.
- Fase 6 requiere el master final (fase 5).

Por tanto, ejecutar `0 1 2 3 4 5 6` en orden equivale a `all`, pero
permite re-ejecutar sólo una fase si cambias parámetros de esa fase.
