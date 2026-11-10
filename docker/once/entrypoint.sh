#!/bin/bash
# ===========================================================================
# ONCE entrypoint: prepares /storage, then hands off to the upstream
# production entrypoint (docker/production/shared/entrypoint.sh).
# ===========================================================================
set -e

SEED=/usr/local/share/bagisto/seed

log() { echo "[once-entrypoint] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

mkdir -p /storage

# Database files: seed a fresh volume with the store installed at build time.
if [ ! -d /storage/mysql/mysql ]; then
    log "Seeding /storage/mysql from the image"
    rm -rf /storage/mysql
    cp -a "$SEED/mysql" /storage/mysql
fi
chown -R mysql:mysql /storage/mysql
chown mysql:mysql /run/mysqld

# Laravel storage/ (uploads, product images, logs, sessions)
if [ ! -d /storage/app/framework ]; then
    log "Seeding /storage/app from the image"
    rm -rf /storage/app
    cp -a "$SEED/app" /storage/app
fi
mkdir -p /storage/app/framework/{cache/data,sessions,views} /storage/app/logs /storage/app/app/public
chown -R www-data:www-data /storage/app

# APP_KEY: explicit APP_KEY wins, then one derived from ONCE's SECRET_KEY_BASE,
# then a random key generated once per install and kept in /storage.
if [ -z "$APP_KEY" ]; then
    if [ -n "$SECRET_KEY_BASE" ]; then
        APP_KEY="base64:$(php -r 'echo base64_encode(hash("sha256", getenv("SECRET_KEY_BASE"), true));')"
    else
        if [ ! -s /storage/app_key ]; then
            log "Generating a new APP_KEY in /storage/app_key"
            echo "base64:$(head -c 32 /dev/urandom | base64)" > /storage/app_key
            chmod 600 /storage/app_key
        fi
        APP_KEY="$(cat /storage/app_key)"
    fi
    export APP_KEY
fi

exec /usr/local/bin/entrypoint.sh "$@"
