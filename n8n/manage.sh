#!/bin/bash

# Función para mostrar la ayuda
show_help() {
    echo "Uso: ./manage.sh [comando]"
    echo ""
    echo "Comandos disponibles:"
    echo "  n8n       - Levanta n8n y sus dependencias (postgres)"
    echo "  evo       - Levanta Evolution API y sus dependencias (postgres, redis)"
    echo "  all       - Levanta todos los servicios"
    echo "  stop      - Detiene todos los servicios"
    echo "  status    - Muestra el estado de los contenedores"
    echo "  clean     - Detiene todo y borra volúmenes (CUIDADO: Borra bases de datos)"
}

case "$1" in
    n8n)
        echo "Levantando n8n..."
        docker compose up -d n8n
        ;;
    evo)
        echo "Levantando Evolution API..."
        docker compose up -d evolution
        ;;
    all)
        echo "Levantando todos los servicios..."
        docker compose up -d
        ;;
    stop)
        echo "Deteniendo servicios..."
        docker compose stop
        ;;
    status)
        docker compose ps
        ;;
    clean)
        read -p "¿Estás seguro de que quieres borrar TODOS los datos? (s/n): " confirm
        if [ "$confirm" == "s" ]; then
            docker compose down -v
        fi
        ;;
    *)
        show_help
        ;;
esac