#!/bin/sh
# Entrypoint de PRODUCCIÓN para maya_dms backend.
#
# Reglas:
#   - NO composer install (las deps van en la imagen).
#   - NO migrate (lo hace el Job helm hook pre-upgrade).
#   - SÍ config:cache + route:cache + view:cache + event:cache (warm-up).
#   - Arranca el binario según CONTAINER_ROLE (api|worker|scheduler|reverb).
#
# Si CMD viene sobrescrito (p. ej. para depuración), se exec()uta tal cual.
set -e

cd /var/www/html

# ─── Secretos vía Vault Agent Injector (si el sidecar/init los inyectó) ───────
# El Vault Agent escribe /vault/secrets/config con líneas `export VAR="..."`.
# Lo cargamos ANTES de cachear config para que artisan vea las credenciales
# (APP_KEY, DB_PASSWORD, KEYCLOAK_CLIENT_SECRET, ...). Sin fichero (dev / Secret
# k8s clásico), este bloque es un no-op y la env llega por envFrom.
if [ -f /vault/secrets/config ]; then
    set -a
    . /vault/secrets/config
    set +a
fi

ROLE="${CONTAINER_ROLE:-api}"

# Limpiar caches con env del pod ANTES de regenerarlos (los cachés de la imagen
# se construyeron sin secrets). No silenciamos stderr para que un fallo real
# salga a los logs del pod en vez de quedar enterrado bajo un `|| true`.
php artisan config:clear --ansi || true
php artisan route:clear  --ansi || true
php artisan view:clear   --ansi || true
php artisan event:clear  --ansi || true

# Warm-up para todos los roles excepto migrate (que no debería usar este entrypoint).
php artisan config:cache --ansi
php artisan route:cache  --ansi
php artisan view:cache   --ansi || true
php artisan event:cache  --ansi || true

# Smoke test del PVC en el rol api/worker (DMS escribe a storage/app/media).
case "$ROLE" in
    api|worker)
        if [ ! -d storage/app/media ]; then
            echo "[entrypoint] FATAL: storage/app/media does not exist" >&2
            exit 1
        fi
        if [ ! -w storage/app/media ]; then
            echo "[entrypoint] FATAL: storage/app/media is not writable" >&2
            exit 1
        fi
        ;;
esac

case "$ROLE" in
    api)
        # Servidor PHP-FPM (CMD = php-fpm --nodaemonize).
        exec "$@"
        ;;
    worker)
        # Cola RabbitMQ — vladimir-yuldashev/laravel-queue-rabbitmq.
        # tries=3 + backoff exponencial; --max-time evita que crezcan los workers.
        exec php artisan queue:work \
            --queue="${QUEUE_NAME:-default}" \
            --tries=3 \
            --backoff=10 \
            --max-time=3600 \
            --sleep=1 \
            --verbose
        ;;
    scheduler)
        # En maya_dms no hay schedule:work (scheduler vive en dashboard), pero
        # dejamos el branch para compat de chart.
        exec php artisan schedule:work --verbose
        ;;
    reverb)
        exec php artisan reverb:start --host=0.0.0.0 --port=8080
        ;;
    migrate)
        exec php artisan migrate --force --no-interaction
        ;;
    custom)
        # Permite arrancar cualquier CMD pasado al pod (debug, jobs one-shot).
        exec "$@"
        ;;
    *)
        echo "[entrypoint] Unknown CONTAINER_ROLE='$ROLE' (api|worker|scheduler|reverb|migrate|custom)" >&2
        exit 64
        ;;
esac
