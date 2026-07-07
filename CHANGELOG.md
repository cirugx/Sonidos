# Changelog

Todos los cambios notables de este proyecto se documentan en este archivo.
El formato está basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/)
y este proyecto se adhiere a [SemVer](https://semver.org/lang/es/).

## [3.3.0] — 2026-07-07

### Added
- Estructura modular: `scripts/lib/{common,filters,phases}.sh`.
- `Makefile` con targets `render`, `smoke`, `lint`, `clean`, `install-deps`.
- `tests/smoke.sh`: test de humo con render de 2s y validación de salida.
- CI en `.github/workflows/ci.yml` con shellcheck + smoke test.
- `docs/ARCHITECTURE.md`: diagrama de arquitectura y decisiones de diseño.
- `docs/PHASES.md`: documentación de las 7 fases del pipeline.
- `CHANGELOG.md`.
- `LICENSE` (MIT).
- `.gitignore` para artefactos de audio, logs y config local.
- Validación de parámetros numéricos antes de ejecutar FFmpeg.
- Flag `--log FILE` para escribir log a archivo además de stderr.
- Purga segura en `fase_6_limpieza`: solo borra si DIR está bajo
  `PROJECT_ROOT/output`.
- Fallback a `equalizer` en cascada para fase 2 (agave) cuando
  `firequalizer` no está disponible.

### Changed
- README reescrito sin paths hardcodeados y con quickstart portable.
- `THREADS` default ahora `$(nproc)`; el valor en `config/default.env`
  se comenta para que el sistema decida por defecto.
- Banner de versión unificado: `v3.3.0` (antes inconsistente entre
  `3.2.2-minimal` y `v3.2.2-MINIMA`).
- Mensaje final de master ahora reporta correctamente si el limitador
  y el dithering se aplicaron o no (antes decía siempre "Sin Limitador").
- Parseo de JSON de loudnorm con `sed` en lugar de `grep -oP` (más
  portable a BSD/macOS).
- Trap de señales ahora hace `exit` explícito (130/143/129) después
  de `cleanup`, evitando que el script continúe tras SIGINT/SIGTERM.

### Removed
- **Bug crítico**: función `construir_cadena_loudnorm` referenciaba
  `${m_thresh}` (variable indefinida) en lugar de `${measured_thresh}`.
  La función era dead code (la fase 5 inlinaba loudnorm); se elimina.
- **Dead code**: función `construir_cadena_asidechaincompress` (nunca
  llamada; la fase 4 inlinaba el sidechain). Se elimina.
- **False dependency**: `bc` listado como dependencia pero nunca usado.
  Se elimina del check y de las instrucciones de instalación.
- Artefactos binarios `output/*.wav` del repositorio (ahora gitignored).

### Fixed
- `trap` no hacía `exit` después de `cleanup` en INT/TERM/HUP, dejando
  jobs en background colgados.
- Mensaje "Sin Limitador (filtro no disponible)" se imprimía siempre,
  incluso cuando el limitador sí se aplicaba.
- Inconsistencia de versión entre `SCRIPT_VERSION` y banner.
- `grep -oP` (GNU-only) reemplazado por `sed` portable.
- `fase_0_materias_primas` no relanzaba jobs tras fallo defensivo
  (bloque defensivo roto eliminado).

## [3.2.2] — 2025 (versión original clonada)

Pipeline monolítico en `scripts/render.sh` (~800 líneas). Versión
"minimal safe" con fallbacks para filtros no disponibles.
