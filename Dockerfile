# ===========================================================================
# Bagisto image for ONCE (https://github.com/basecamp/once)
#
# Built from this repository's source (not a GitHub tag), on top of the
# upstream single-container production setup in docker/production/:
# Nginx + PHP 8.4 FPM + bundled MySQL + queue worker + cron, under Supervisor.
#
# ONCE contract:
#   - listens on port 80, GET /up returns 200 (Laravel health route)
#   - everything that must survive updates lives under /storage:
#       /storage/mysql   database files
#       /storage/app     Laravel storage/ (uploads, product images, logs)
#       /storage/app_key per-install APP_KEY (unless APP_KEY/SECRET_KEY_BASE given)
#   - a fresh, empty /storage is seeded from the store installed at build time
# ===========================================================================

FROM ubuntu:24.04

ARG DB_ENGINE=mysql
ARG PHP_VERSION=8.4

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

LABEL org.opencontainers.image.source="https://github.com/Jameson13B/neon-clubhouse" \
      org.opencontainers.image.description="Bagisto Laravel e-commerce, packaged for ONCE"

RUN apt-get update && apt-get install -y \
        apt-transport-https ca-certificates curl git gnupg software-properties-common unzip \
    && add-apt-repository ppa:ondrej/php -y \
    && apt-get update && apt-get install -y cron imagemagick nginx supervisor \
    && apt-get install -y \
        php${PHP_VERSION}-bcmath php${PHP_VERSION}-calendar php${PHP_VERSION}-cli \
        php${PHP_VERSION}-curl php${PHP_VERSION}-exif php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-gd php${PHP_VERSION}-gmp php${PHP_VERSION}-imagick \
        php${PHP_VERSION}-intl php${PHP_VERSION}-mbstring php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-pgsql php${PHP_VERSION}-pdo php${PHP_VERSION}-soap \
        php${PHP_VERSION}-sockets php${PHP_VERSION}-xml php${PHP_VERSION}-zip \
    && rm -rf /var/lib/apt/lists/*

# Bundled database server
COPY docker/production/shared/db/${DB_ENGINE}/ /usr/local/share/bagisto/db/
RUN . /usr/local/share/bagisto/db/engine.sh \
    && apt-get update && apt-get install -y $(db_server_packages) \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

WORKDIR /var/www/bagisto

# Dependencies first, for layer caching
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --no-scripts --no-autoloader \
    && rm -rf /root/.composer/cache

COPY . .
RUN composer dump-autoload --optimize --no-dev --no-scripts

RUN cp .env.example .env \
    && sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/' .env \
    && sed -i 's/^DB_HOST=.*/DB_HOST=127.0.0.1/' .env \
    && sed -i 's/^DB_DATABASE=.*/DB_DATABASE=bagisto/' .env \
    && sed -i 's/^DB_USERNAME=.*/DB_USERNAME=bagisto/' .env \
    && sed -i 's/^DB_PASSWORD=.*/DB_PASSWORD=bagisto/' .env \
    && sed -i 's|^APP_URL=.*|APP_URL=http://localhost|' .env

# Install Bagisto (migrations + seed + demo products) at build time
COPY docker/production/shared/build-install.sh /tmp/build-install.sh
RUN mkdir -p /docker-entrypoint-initdb.d \
    && cp /usr/local/share/bagisto/db/init.sql /docker-entrypoint-initdb.d/init.sql \
    && chmod +x /usr/local/share/bagisto/db/*.sh \
    && . /usr/local/share/bagisto/db/engine.sh \
    && sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=$(db_connection)/" .env \
    && sed -i "s/^DB_PORT=.*/DB_PORT=$(db_default_port)/" .env \
    && DB_ENGINE=${DB_ENGINE} bash /tmp/build-install.sh \
    && rm /tmp/build-install.sh \
    && sed -i 's/^APP_ENV=.*/APP_ENV=production/' .env \
    && sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=warning/' .env

# PHP, Nginx, Supervisor, workers
COPY docker/production/shared/php.ini /etc/php/${PHP_VERSION}/fpm/conf.d/99-production.ini
COPY docker/production/nginx/config/php-fpm.conf /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
RUN rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
COPY docker/production/nginx/config/nginx.conf /etc/nginx/conf.d/bagisto.conf
COPY docker/production/nginx/config/supervisord.conf /etc/supervisor/conf.d/bagisto.conf
RUN sed -i "s/__PHP_VERSION__/${PHP_VERSION}/g" /etc/supervisor/conf.d/bagisto.conf
COPY docker/production/shared/db/${DB_ENGINE}/supervisord.conf /etc/supervisor/conf.d/database.conf
COPY docker/production/shared/workers/supervisord.conf /etc/supervisor/conf.d/workers.conf
COPY docker/production/shared/workers/job-log.sh /usr/local/bin/bagisto-job-log
COPY docker/production/shared/workers/crontab /etc/cron.d/bagisto
RUN chmod +x /usr/local/bin/bagisto-job-log \
    && chmod 0644 /etc/cron.d/bagisto \
    && find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly -type f ! -name bagisto ! -name .placeholder -delete \
    && sed -i 's/^session\s\+required\s\+pam_loginuid\.so/session    optional     pam_loginuid.so/' /etc/pam.d/cron \
    && mkdir -p /run/php /run/mysqld /var/log/supervisor /var/log/bagisto

RUN chown -R www-data:www-data /var/www/bagisto \
    && chmod -R 775 storage bootstrap/cache \
    && find storage bootstrap/cache -type d -exec chmod g+s {} +

# Move the installed state out of the image paths into a seed, and point the
# app at /storage, where ONCE mounts its persistent volume.
RUN mkdir -p /usr/local/share/bagisto/seed \
    && mv /var/lib/mysql /usr/local/share/bagisto/seed/mysql \
    && mv /var/www/bagisto/storage /usr/local/share/bagisto/seed/app \
    && ln -s /storage/mysql /var/lib/mysql \
    && ln -s /storage/app /var/www/bagisto/storage \
    && sed -i 's|--datadir=/var/lib/mysql|--datadir=/storage/mysql|' /etc/supervisor/conf.d/database.conf

COPY docker/production/shared/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/once/entrypoint.sh /usr/local/bin/once-entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/once-entrypoint.sh \
    && apt-get autoremove -y && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

EXPOSE 80
VOLUME /storage

ENTRYPOINT ["/usr/local/bin/once-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
