# Stage 1: build (PHP + Node juntos para o wayfinder poder rodar artisan durante npm build)
FROM php:8.4-alpine AS builder

RUN apk add --no-cache \
    bash git curl \
    libpng-dev libjpeg-turbo-dev freetype-dev \
    libzip-dev oniguruma-dev icu-dev \
    nodejs npm \
    $PHPIZE_DEPS \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install pdo_mysql mbstring bcmath gd zip intl \
    && apk del $PHPIZE_DEPS

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app

COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist

COPY . .
RUN mkdir -p storage/framework/views storage/framework/cache/data storage/framework/sessions storage/logs bootstrap/cache \
    && composer dump-autoload --optimize \
    && cp .env.example .env \
    && php artisan key:generate --force

COPY package.json package-lock.json ./
RUN npm ci && npm run build

# Stage 2: runtime PHP-FPM
FROM php:8.4-fpm-alpine AS runtime

RUN apk add --no-cache \
    libpng libjpeg-turbo freetype libzip icu-libs oniguruma \
    libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev icu-dev oniguruma-dev zlib-dev \
    $PHPIZE_DEPS \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install pdo_mysql mbstring bcmath gd zip intl opcache \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del $PHPIZE_DEPS libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev icu-dev oniguruma-dev zlib-dev

WORKDIR /var/www/html

COPY --from=builder /app/vendor ./vendor
COPY --from=builder /app/public/build ./public/build
COPY --from=builder /app/bootstrap/cache ./bootstrap/cache
COPY . .

RUN mkdir -p storage/framework/views storage/framework/cache/data storage/framework/sessions storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

COPY docker/php/php.ini /usr/local/etc/php/conf.d/custom.ini
COPY docker/php/opcache.ini /usr/local/etc/php/conf.d/opcache.ini

EXPOSE 9000
CMD ["php-fpm"]
