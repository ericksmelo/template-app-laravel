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

# Stage 2: runtime (Nginx + PHP-FPM)
FROM php:8.4-fpm-alpine AS runtime

RUN apk add --no-cache \
    nginx supervisor \
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
    && chmod -R 775 storage bootstrap/cache \
    && printf '[PHP]\nmemory_limit=256M\nupload_max_filesize=50M\npost_max_size=50M\nmax_execution_time=60\nexpose_php=Off\n' > /usr/local/etc/php/conf.d/custom.ini \
    && printf '[opcache]\nopcache.enable=1\nopcache.memory_consumption=128\nopcache.interned_strings_buffer=8\nopcache.max_accelerated_files=10000\nopcache.validate_timestamps=0\nopcache.save_comments=1\n' > /usr/local/etc/php/conf.d/opcache.ini

RUN printf 'server {\n\
    listen 80;\n\
    root /var/www/html/public;\n\
    index index.php;\n\
    client_max_body_size 50M;\n\
    location / {\n\
        try_files $uri $uri/ /index.php?$query_string;\n\
    }\n\
    location ~ \\.php$ {\n\
        fastcgi_pass 127.0.0.1:9000;\n\
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;\n\
        include fastcgi_params;\n\
    }\n\
    location ~ /\\.(?!well-known).* {\n\
        deny all;\n\
    }\n\
}\n' > /etc/nginx/http.d/default.conf

RUN printf '[supervisord]\nnodaemon=true\nlogfile=/dev/null\nlogfile_maxbytes=0\n\n\
[program:php-fpm]\ncommand=php-fpm -F\nautostart=true\nautorestart=true\nstdout_logfile=/dev/stdout\nstdout_logfile_maxbytes=0\nstderr_logfile=/dev/stderr\nstderr_logfile_maxbytes=0\n\n\
[program:nginx]\ncommand=nginx -g "daemon off;"\nautostart=true\nautorestart=true\nstdout_logfile=/dev/stdout\nstdout_logfile_maxbytes=0\nstderr_logfile=/dev/stderr\nstderr_logfile_maxbytes=0\n' > /etc/supervisord.conf

EXPOSE 80
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
