# Paisaje Sonoro Desértico

Proyecto de síntesis procedural de audio con FFmpeg y Bash para generar un paisaje sonoro ambiental, con fases separadas de síntesis, espacialización, sidechain y masterización.

## Estructura del proyecto

- scripts/ : scripts de ejecución y orquestación
- config/ : configuración y parámetros del proyecto
- output/ : artefactos de audio generados y temporales
- docs/ : documentación y referencias

## Requisitos

- FFmpeg
- ffprobe
- bc

## Uso rápido

```bash
cd /home/jesuslangarica/Música/Audio/Sonidos
bash scripts/render.sh --help
bash scripts/render.sh -t 10 -l -16
```

## Notas de arquitectura

- El pipeline está dividido en fases independientes.
- Los artefactos intermedios se generan en output/.
- La configuración puede extenderse mediante archivos en config/.
