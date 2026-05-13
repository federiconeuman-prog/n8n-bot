#!/bin/bash

# Función para mostrar la ayuda
show_help() {
    echo "Uso: ./logs.sh [servicio]"
    echo ""
    echo "Servicios disponibles:"
    echo "  n8n   - Ver logs de n8n"
    echo "  evo   - Ver logs de Evolution API"
    echo "  db    - Ver logs de PostgreSQL"
    echo "  all   - Ver logs de todos los servicios combinados"
}

case "$1" in
    n8n)
        echo "--- Mostrando logs de n8n (Ctrl+C para salir) ---"
        docker compose logs -f n8n
        ;;
    evo)
        echo "--- Mostrando logs de Evolution API (Ctrl+C para salir) ---"
        docker compose logs -f evolution
        ;;
    db)
        echo "--- Mostrando logs de Postgres (Ctrl+C para salir) ---"
        docker compose logs -f postgres
        ;;
    all)
        echo "--- Mostrando logs de TODO (Ctrl+C para salir) ---"
        docker compose logs -f
        ;;
    *)
        show_help
        ;;
esac