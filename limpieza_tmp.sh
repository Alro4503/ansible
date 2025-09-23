#!/bin/bash
# Script de limpieza automática de /tmp para nodos de cluster
# Diseñado para ejecutarse desde AWX/Ansible Tower

# Configuración
MTIME_DAYS=1
SYSTEMD_PATHS=(
    "/tmp/systemd-*"
    "/tmp/.font-unix*"
    "/tmp/.ICE-unix*"
    "/tmp/.Test-unix*"
    "/tmp/.X11-unix*"
    "/tmp/.XIM-unix*"
    "/tmp/snap-private-tmp*"
)

# Funciones de utilidad
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 1. Verificar si /tmp tiene loop device
if mount | grep -q 'loop.*on /tmp'; then
    log "/tmp está montado como loop device, saliendo..."
    exit 0
fi

# 2. Obtener hostname completo
HOSTNAME_FULL=$(hostname -f)
log "Iniciando limpieza en nodo: $HOSTNAME_FULL"

# 3. Verificar jobs corriendo en SLURM
RUNNING_JOBS=$(squeue -h -w "$HOSTNAME_FULL" 2>/dev/null | wc -l)
log "Jobs corriendo actualmente: $RUNNING_JOBS"

if [ "$RUNNING_JOBS" -gt 0 ]; then
    # Mostrar jobs corriendo
    log "Jobs actuales en el nodo:"
    squeue -w "$HOSTNAME_FULL"
    
    # Drainear nodo
    log "Draineando nodo..."
    scontrol update NodeName="$HOSTNAME_FULL" State=DRAIN Reason="Limpieza /tmp automática" || true
    
    # Esperar a que terminen los jobs (máximo 12 horas)
    MAX_RETRIES=1440
    RETRY_DELAY=30
    for ((i=1; i<=MAX_RETRIES; i++)); do
        CURRENT_JOBS=$(squeue -h -w "$HOSTNAME_FULL" 2>/dev/null | wc -l)
        if [ "$CURRENT_JOBS" -eq 0 ]; then
            break
        fi
        if [ "$i" -eq "$MAX_RETRIES" ]; then
            log "Tiempo de espera agotado, todavía hay jobs corriendo"
            exit 1
        fi
        sleep $RETRY_DELAY
    done
fi

# 4. Limpieza de archivos antiguos
log "Buscando archivos antiguos para eliminar..."
OLD_FILES_COUNT=$(find /tmp -type f -mtime +"$MTIME_DAYS" \
    ! -name "*.time" \
    $(printf "! -path %s " "${SYSTEMD_PATHS[@]}") | wc -l)

if [ "$OLD_FILES_COUNT" -gt 0 ]; then
    log "Eliminando $OLD_FILES_COUNT archivos antiguos..."
    find /tmp -type f -mtime +"$MTIME_DAYS" \
        ! -name "*.time" \
        $(printf "! -path %s " "${SYSTEMD_PATHS[@]}") \
        -delete
fi

# 5. Limpieza de directorios antiguos
log "Buscando directorios antiguos para eliminar..."
OLD_DIRS_COUNT=$(find /tmp -type d -mtime +"$MTIME_DAYS" \
    $(printf "! -path %s " "${SYSTEMD_PATHS[@]}") \
    ! -path "/tmp" | wc -l)

if [ "$OLD_DIRS_COUNT" -gt 0 ]; then
    log "Eliminando $OLD_DIRS_COUNT directorios antiguos..."
    find /tmp -type d -mtime +"$MTIME_DAYS" \
        $(printf "! -path %s " "${SYSTEMD_PATHS[@]}") \
        ! -path "/tmp" \
        -exec rmdir {} + 2>/dev/null || true
fi

# 6. Reactivar nodo si fue dreneado
if [ "$RUNNING_JOBS" -gt 0 ]; then
    log "Verificando estado del nodo..."
    NODE_STATE=$(scontrol show node "$HOSTNAME_FULL" | grep State)
    
    if echo "$NODE_STATE" | grep -q "State=DRAIN"; then
        log "Reactivando nodo..."
        scontrol update NodeName="$HOSTNAME_FULL" State=RESUME
    else
        log "Nodo no requiere reactivación"
    fi
fi

# 7. Mostrar resultado final
log "Limpieza completada en $HOSTNAME_FULL"
log "Resumen:"
log "  - Jobs iniciales: $RUNNING_JOBS"
log "  - Archivos eliminados: $OLD_FILES_COUNT"
log "  - Directorios eliminados: $OLD_DIRS_COUNT"
log "  - Estado del nodo: ${NODE_STATE:-OK}"
log "  - Uso final de /tmp:"
df -h /tmp | tail -1

exit 0
