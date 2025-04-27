#####################################
# STAGE 1: builder
#####################################
FROM php:8.1-apache AS builder

LABEL vendor="Mautic"
LABEL maintainer="Mautic core team <>"

# 1) Instala pré-requisitos e extensões PHP
RUN apt-get update \
 && apt-get install --no-install-recommends -y \
    ca-certificates build-essential git curl \
    libcurl4-gnutls-dev libc-client-dev libkrb5-dev \
    libssl-dev libxml2-dev libzip-dev libjpeg-dev \
    libmagickwand-dev libpng-dev libgif-dev libtiff-dev \
    libz-dev libpq-dev imagemagick graphicsmagick \
    libwebp-dev libjpeg62-turbo-dev libxpm-dev \
    libaprutil1-dev libicu-dev libfreetype6-dev libonig-dev \
    librabbitmq-dev unzip nodejs npm \
 && rm -rf /var/lib/apt/lists/*

# 2) Compila e habilita extensão AMQP
RUN curl -L -o /tmp/amqp.tar.gz \
      "https://github.com/php-amqp/php-amqp/archive/refs/tags/v2.1.1.tar.gz" \
 && mkdir -p /usr/src/php/ext/amqp \
 && tar -C /usr/src/php/ext/amqp -zxvf /tmp/amqp.tar.gz --strip 1 \
 && rm /tmp/amqp.tar.gz

# 3) Configura e instala extensões PHP
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
 && docker-php-ext-configure opcache --enable-opcache \
 && docker-php-ext-install intl mbstring mysqli curl pdo_mysql \
      zip bcmath sockets exif amqp gd imap opcache \
 && docker-php-ext-enable intl mbstring mysqli curl pdo_mysql \
      zip bcmath sockets exif amqp gd imap opcache

# 4) Composer
RUN curl -sS https://getcomposer.org/installer | php \
      -- --install-dir=/usr/bin --filename=composer \
 && echo "memory_limit = -1" > /usr/local/etc/php/conf.d/memory.ini

# 5) Cria o projeto Mautic e aplica hacks
ARG MAUTIC_VERSION=6.x-dev
RUN cd /opt \
 && COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_PROCESS_TIMEOUT=10000 \
    composer create-project mautic/recommended-project:${MAUTIC_VERSION} mautic --no-interaction \
 && rm -rf /opt/mautic/var/cache/js \
 && find /opt/mautic/node_modules -mindepth 1 -maxdepth 1 \
      -not \( -name 'jquery' -or -name 'vimeo-froogaloop2' \) \
    | xargs rm -rf \
 \
 # —— hack fixes —— \
 && cd /opt/mautic \
 # a) pasta Views faltante para OAuth Server Bundle
 && mkdir -p vendor/klapaudius/oauth-server-bundle/Resources/views \
 # b) adiciona HttpClient para UriTemplateHttpClient
 && composer require symfony/http-client --no-interaction \
 # c) corrige bool→LoggerInterface no container compilado
 && sed -i 's/, false)/, null)/g' var/cache/prod/Container*/AppKernelProdContainer.php

#####################################
# STAGE 2: runtime
#####################################
FROM php:8.1-apache

# 1) Copia extensions + configs
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# 2) Copia o Mautic “bakeado”
COPY --from=builder --chown=www-data:www-data /opt/mautic /var/www/html

# 3) Instala dependências de runtime (cron, supervisor, mariadb-client…)
RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      unzip libwebp-dev libzip-dev libfreetype6-dev \
      libjpeg62-turbo-dev libpng-dev libc-client-dev \
      librabbitmq4 mariadb-client supervisor cron \
 && apt-get purge -y --auto-remove \
 && rm -rf /var/lib/apt/lists/* \
 && rm /etc/cron.daily/*

# 4) Ajusta php.ini (timezone, memory, uploads)
COPY ./common/php.ini /usr/local/etc/php/php.ini
ENV PHP_INI_VALUE_DATE_TIMEZONE='UTC' \
    PHP_INI_VALUE_MEMORY_LIMIT=512M \
    PHP_INI_VALUE_UPLOAD_MAX_FILESIZE=512M \
    PHP_INI_VALUE_POST_MAX_FILESIZE=512M \
    PHP_INI_VALUE_MAX_EXECUTION_TIME=300 \
    APACHE_DOCUMENT_ROOT=/var/www/html/docroot

# 5) Aponta o docroot e habilita rewrite
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' \
         /etc/apache2/sites-available/*.conf \
 && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' \
         /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf \
 && a2enmod rewrite

# 6) Entry points e supervisor
COPY ./common/docker-entrypoint.sh             /entrypoint.sh
COPY ./common/entrypoint_mautic_web.sh        /entrypoint_mautic_web.sh
COPY ./common/entrypoint_mautic_cron.sh       /entrypoint_mautic_cron.sh
COPY ./common/entrypoint_mautic_worker.sh     /entrypoint_mautic_worker.sh
COPY ./common/supervisord.conf                /etc/supervisor/conf.d/supervisord.conf

RUN chmod +x /entrypoint.sh \
            /entrypoint_mautic_web.sh \
            /entrypoint_mautic_cron.sh \
            /entrypoint_mautic_worker.sh

# 7) Volumes e WORKDIR
VOLUME /var/www/html/config /var/www/html/var/logs /var/www/html/docroot/media
WORKDIR /var/www/html/docroot

ENV DOCKER_MAUTIC_ROLE=mautic_web \
    DOCKER_MAUTIC_RUN_MIGRATIONS=false \
    DOCKER_MAUTIC_LOAD_TEST_DATA=false \
    DOCKER_MAUTIC_WORKERS_CONSUME_EMAIL=2 \
    DOCKER_MAUTIC_WORKERS_CONSUME_HIT=2 \
    DOCKER_MAUTIC_WORKERS_CONSUME_FAILED=2

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
