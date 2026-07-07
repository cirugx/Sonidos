# =============================================================================
# Makefile — Paisaje Sonoro Desértico
# =============================================================================
# Tareas comunes para desarrollo y mantenimiento.
# Uso: make <target>

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

PROJECT_ROOT := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && pwd)
SCRIPT       := $(PROJECT_ROOT)/scripts/render.sh
SMOKE_TEST   := $(PROJECT_ROOT)/tests/smoke.sh
LIB_DIR      := $(PROJECT_ROOT)/scripts/lib

# Colores (solo si TTY)
ifneq (,$(findstring xterm,$(TERM)))
	C_BOLD  := \033[1m
	C_CYAN  := \033[0;36m
	C_GREEN := \033[0;32m
	C_RESET := \033[0m
else
	C_BOLD  :=
	C_CYAN  :=
	C_GREEN :=
	C_RESET :=
endif

.PHONY: help render smoke lint check format clean clean-output install-deps

##@ Ayuda

help: ## Mostrar esta ayuda
	@printf "$(C_BOLD)Paisaje Sonoro Desértico — Makefile$(C_RESET)\n"
	@printf "Uso: make $(C_CYAN)<target>$(C_RESET)\n\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  $(C_CYAN)%-18s$(C_RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Desarrollo

render: ## Render completo (10s default)
	@bash $(SCRIPT)

render-fast: ## Render rápido de prueba (2s, 22050Hz)
	@bash $(SCRIPT) -t 2 -r 22050 -b 16 -j 2

render-long: ## Render largo (60s, FLAC 24-bit)
	@bash $(SCRIPT) -t 60 -f flac -b 24

##@ Testing & Calidad

smoke: ## Test de humo (render de 2s + validación)
	@bash $(SMOKE_TEST)

lint: ## Ejecutar shellcheck en todos los scripts
	@command -v shellcheck >/dev/null 2>&1 || { \
		printf "shellcheck no instalado. Instálalo con:\n"; \
		printf "  Debian/Ubuntu: sudo apt install shellcheck\n"; \
		printf "  macOS:         brew install shellcheck\n"; \
		exit 1; }
	@shellcheck -x -S warning \
		$(SCRIPT) \
		$(LIB_DIR)/common.sh \
		$(LIB_DIR)/filters.sh \
		$(LIB_DIR)/phases.sh \
		$(SMOKE_TEST)
	@printf "$(C_GREEN)✓ shellcheck OK$(C_RESET)\n"

check: lint smoke ## lint + smoke test

##@ Mantenimiento

clean-output: ## Borrar artefactos generados en output/
	@find $(PROJECT_ROOT)/output -type f ! -name '.gitkeep' -delete
	@printf "$(C_GREEN)✓ output/ limpio$(C_RESET)\n"

clean: clean-output ## Alias de clean-output

install-deps: ## Imprimir instrucciones de instalación de dependencias
	@printf "Dependencias necesarias:\n"
	@printf "  - FFmpeg (incluye ffmpeg y ffprobe)\n"
	@printf "\nInstalación por plataforma:\n"
	@printf "  Debian/Ubuntu: sudo apt install ffmpeg\n"
	@printf "  Fedora:        sudo dnf install ffmpeg\n"
	@printf "  Arch:          sudo pacman -S ffmpeg\n"
	@printf "  macOS:         brew install ffmpeg\n"
	@printf "  Windows:       https://ffmpeg.org/download.html\n"
	@printf "\nOpcional (desarrollo):\n"
	@printf "  shellcheck:    sudo apt install shellcheck  (o brew install shellcheck)\n"
