#!/bin/bash

# CONFIGURACIÓN
MTIME_DAYS=1   # ⚠️ CONFIGURABLE: Días de antigüedad para eliminar archivos
THRESHOLD=30   # Umbral de uso de /tmp (no usado actualmente)

# Función para verificar uso de /tmp
check_tmp_usage() {
    df /tmp | tail -1 | awk '{print $5}' | sed 's/%//'
}

# Función para listar archivos y directorios a limpiar
list_files_to_clean_auto() {
    echo "📋 Archivos y directorios detectados para limpieza automática:"
    
    # Contar archivos (con sudo para evitar errores de permisos)
    local total_files=$(sudo find /tmp -type f -mtime +${MTIME_DAYS} \
        ! -path "/tmp/systemd-*" \
        ! -path "/tmp/.font-unix*" \
        ! -path "/tmp/.ICE-unix*" \
        ! -path "/tmp/.Test-unix*" \
        ! -path "/tmp/.X11-unix*" \
        ! -path "/tmp/.XIM-unix*" \
        ! -path "/tmp/snap-private-tmp*" \
        2>/dev/null | wc -l)
        
    # Contar directorios (con sudo para evitar errores de permisos)
    local total_dirs=$(sudo find /tmp -type d -mtime +${MTIME_DAYS} \
        ! -path "/tmp/systemd-*" \
        ! -path "/tmp/.font-unix*" \
        ! -path "/tmp/.ICE-unix*" \
        ! -path "/tmp/.Test-unix*" \
        ! -path "/tmp/.X11-unix*" \
        ! -path "/tmp/.XIM-unix*" \
        ! -path "/tmp/snap-private-tmp*" \
        ! -path "/tmp" \
        2>/dev/null | wc -l)
        
    # Calcular tamaño total (con sudo para evitar errores de permisos)
    local size_mb=$(sudo find /tmp -mtime +${MTIME_DAYS} \
        ! -path "/tmp/systemd-*" \
        ! -path "/tmp/.font-unix*" \
        ! -path "/tmp/.ICE-unix*" \
        ! -path "/tmp/.Test-unix*" \
        ! -path "/tmp/.X11-unix*" \
        ! -path "/tmp/.XIM-unix*" \
        ! -path "/tmp/snap-private-tmp*" \
        ! -path "/tmp" \
        -exec du -sk {} \; 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum/1024}')
    
    echo "💾 Total archivos a eliminar: $total_files (archivos con más de ${MTIME_DAYS} días)"
    echo "📁 Total directorios a eliminar: $total_dirs (directorios con más de ${MTIME_DAYS} días)"
    echo "📦 Espacio aproximado a liberar: ${size_mb}MB"
    
    # Retornar si hay algo que limpiar
    if [ $total_files -gt 0 ] || [ $total_dirs -gt 0 ]; then
        return 0  # Hay contenido para limpiar
    else
        return 1  # No hay nada que limpiar
    fi
}

# Función para verificar jobs corriendo en el nodo actual
check_running_jobs() {
    local nodename=$(hostname -f)
    echo "=== Verificando jobs en SLURM para $nodename ==="
    
    local running_jobs=$(squeue -h -w $nodename 2>/dev/null | wc -l)
    echo "Jobs corriendo en $nodename: $running_jobs"
    
    if [ $running_jobs -gt 0 ]; then
        echo "⚠️  Hay jobs corriendo en $nodename:"
        squeue -w $nodename
        return 0
    else
        echo "ℹ️  No hay jobs corriendo en $nodename"
        return 1
    fi
}

# Función para drainear nodo actual
drain_node() {
    local nodename=$(hostname -f)
    
    echo "🔄 Draineando nodo $nodename..."
    scontrol update NodeName=$nodename State=DRAIN Reason="Limpieza /tmp automática"
    
    echo "⏳ Esperando que terminen los jobs en $nodename..."
    echo "   ⚠️  IMPORTANTE: Esperaremos el tiempo que sea necesario (jobs pueden durar horas/días)"
    
    local wait_cycles=0
    
    while [ $(squeue -h -w $nodename 2>/dev/null | wc -l) -gt 0 ]; do
        local current_jobs=$(squeue -h -w $nodename | wc -l)
        local wait_time_minutes=$((wait_cycles * 30 / 60))
        echo "   Jobs aún corriendo: $current_jobs (esperando desde hace ${wait_time_minutes} minutos)"
        
        # Log cada hora para monitoreo
        if [ $((wait_cycles % 120)) -eq 0 ] && [ $wait_cycles -gt 0 ]; then
            local wait_hours=$((wait_cycles * 30 / 3600))
            echo "   ⏰ ACTUALIZACIÓN: Llevamos ${wait_hours} horas esperando a que terminen los jobs"
            echo "   📊 Jobs restantes:"
            squeue -w $nodename
        fi
        
        sleep 30
        wait_cycles=$((wait_cycles + 1))
    done
    
    echo "✅ Todos los jobs terminaron en $nodename (esperamos $((wait_cycles * 30 / 60)) minutos)"
    return 0
}

# Función para limpiar /tmp del nodo actual
clean_tmp() {
    echo "🧹 Limpiando /tmp en $(hostname -f)..."
    
    local before=$(sudo find /tmp -type f | wc -l)
    local before_dirs=$(sudo find /tmp -type d \
        ! -path "/tmp/systemd-*" \
        ! -path "/tmp/.font-unix*" \
        ! -path "/tmp/.ICE-unix*" \
        ! -path "/tmp/.Test-unix*" \
        ! -path "/tmp/.X11-unix*" \
        ! -path "/tmp/.XIM-unix*" \
        ! -path "/tmp/snap-private-tmp*" \
        ! -path "/tmp" \
        -mtime +${MTIME_DAYS} | wc -l)
    local before_size=$(df -h /tmp | tail -1 | awk '{print $3}')
    
    # Limpiar archivos antiguos primero (con sudo para permisos)
    sudo find /tmp -type f -mtime +${MTIME_DAYS} \
        ! -path "/tmp/systemd-*" \
        ! -path "/tmp/.font-unix*" \
        ! -path "/tmp/.ICE-unix*" \
        ! -path "/tmp/.Test-unix*" \
        ! -path "/tmp/.X11-unix*" \
        ! -path "/tmp/.XIM-unix*" \
        ! -path "/tmp/snap-private-tmp*" \
        -delete 2>/dev/null
    
    # Limpiar directorios antiguos (con sudo para permisos)
    sudo find /tmp -depth -type d -mtime +${MTIME_DAYS} \
        ! -path "/tmp/systemd-*" \
        ! -path "/tmp/.font-unix*" \
        ! -path "/tmp/.ICE-unix*" \
        ! -path "/tmp/.Test-unix*" \
        ! -path "/tmp/.X11-unix*" \
        ! -path "/tmp/.XIM-unix*" \
        ! -path "/tmp/snap-private-tmp*" \
        ! -path "/tmp" \
        -exec rmdir {} \; 2>/dev/null
    
    local after=$(sudo find /tmp -type f | wc -l)
    local after_dirs=$(sudo find /tmp -type d \
        ! -path "/tmp/systemd-*" \
        ! -path "/tmp/.font-unix*" \
        ! -path "/tmp/.ICE-unix*" \
        ! -path "/tmp/.Test-unix*" \
        ! -path "/tmp/.X11-unix*" \
        ! -path "/tmp/.XIM-unix*" \
        ! -path "/tmp/snap-private-tmp*" \
        ! -path "/tmp" \
        -mtime +${MTIME_DAYS} | wc -l)
    local after_size=$(df -h /tmp | tail -1 | awk '{print $3}')
    
    echo "   �� Archivos eliminados: $((before - after))"
    echo "   📁 Directorios eliminados: $((before_dirs - after_dirs))"
    echo "   📊 Uso antes: $before_size → después: $after_size"
    echo "   📊 Uso actual: $(check_tmp_usage)%"
}

# Función para reactivar nodo actual
resume_node() {
    local nodename=$(hostname -f)
    
    echo "🔄 Reactivando nodo $nodename..."
    scontrol update NodeName=$nodename State=RESUME
    echo "✅ Nodo $nodename reactivado"
}

# Función principal
main() {
    local nodename=$(hostname -f)
    echo "=== LIMPIEZA AUTOMÁTICA de /tmp en nodo $nodename ==="
    echo "⏰ Ejecutado en: $(date)"
    echo "🔧 CONFIGURACIÓN: Eliminando archivos/directorios con más de ${MTIME_DAYS} días"
    
    # Verificar que NO tiene loop device
    if mount | grep -q 'loop.*on /tmp'; then
        echo "ℹ️  $nodename tiene loop device, no necesita limpieza"
        exit 0
    fi
    
    echo "✅ $nodename tiene /tmp normal"
    
    # Verificar uso actual
    usage=$(check_tmp_usage)
    echo "📊 Uso actual de /tmp: ${usage}%"
    
    # ⚠️ VERIFICAR JOBS PRIMERO - antes de decidir si hay archivos para limpiar
    was_drained="no"
    if check_running_jobs; then
        echo "⚠️  AVISO: Hay jobs corriendo. El nodo será draineado y esperaremos indefinidamente hasta que terminen todos los jobs"
        drain_node
        was_drained="yes"
    fi
    
    # Verificar si hay contenido para limpiar (DESPUÉS de jobs)
    if ! list_files_to_clean_auto; then
        echo "ℹ️  No hay archivos antiguos para limpiar. Finalizando."
        # Reactivar nodo si se draineó
        if [[ "$was_drained" == "yes" ]]; then
            resume_node
        fi
        exit 0
    fi
    
    echo "🚀 Iniciando limpieza automática..."
    
    # Limpiar (solo si había archivos para limpiar)
    clean_tmp
    
    # Reactivar si se draineó
    if [[ "$was_drained" == "yes" ]]; then
        resume_node
    fi
    
    echo ""
    echo "=== Limpieza automática completada en $(date) ==="
    echo "Estado final del nodo:"
    if sinfo -N -l | grep -q $nodename; then
        sinfo -N -l | grep $nodename
    else
        echo "ℹ️  $nodename es master/head node (no aparece en compute nodes)"
    fi
    echo "=========================================="
}

# Ejecutar función principal
main