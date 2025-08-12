ARG IMAGE_TAG

FROM dunglas/frankenphp:${IMAGE_TAG}

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

RUN install-php-extensions \
        @composer \
        intl \
        pdo_mysql \
        pdo_pgsql \
        redis \
        zip
