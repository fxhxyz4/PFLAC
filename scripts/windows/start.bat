@echo off
echo === PFLAC DEPLOY SCRIPT ===
echo requirements: Docker
echo.

:: ---------------------------
:: 0. Проверка Docker
:: ---------------------------
where docker >nul 2>&1
if errorlevel 1 (
    echo [INFO] Docker не найден. Попробуем установить...
    echo [INFO] Пожалуйста, скачайте Docker Desktop с официального сайта и установите его вручную.
    echo https://www.docker.com/products/docker-desktop/
    pause
    exit /b 1
) else (
    echo [OK] Docker найден.
)

echo ""
echo ""

:: ---------------------------
:: 0.1 Запуск Docker Desktop (если не запущен)
:: ---------------------------
tasklist /FI "IMAGENAME eq Docker Desktop.exe" | find /I "Docker Desktop.exe" >nul 2>&1
if errorlevel 1 (
    echo [INFO] Запуск Docker Desktop...
    start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    echo [INFO] Ожидание запуска Docker (10 секунд)...
    timeout /t 10 /nobreak >nul
) else (
    echo [OK] Docker Desktop уже запущен.
)

echo ""
echo ""

:: ---------------------------
:: 0.2 Добавление скрипта в автозагрузку
:: ---------------------------
set SCRIPT_PATH=%~f0
echo [INFO] Добавляем скрипт в автозагрузку Windows...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v PFLAC_DEPLOY /t REG_SZ /d "\"%SCRIPT_PATH%\"" /f >nul
echo [OK] Скрипт добавлен в автозагрузку.

echo ""

:: ---------------------------
:: 1. Ввод данных для .env
:: ---------------------------
set /p NODE_ENV="Введите NODE_ENV (prod/dev): "
set /p DB_USER="Введите DB_USER: "
set /p DB_NAME="Введите DB_NAME: "
set /p DB_PASS="Введите DB_PASS: "
set /p DB_PORT="Введите DB_PORT (например 3306 или 3307): "

:: ---------------------------
:: 2. Создаём .env
:: ---------------------------
cd ..
(
echo NODE_ENV=%NODE_ENV%
echo DB_USER=%DB_USER%
echo DB_NAME=%DB_NAME%
echo DB_PASS=%DB_PASS%
echo DB_PORT=%DB_PORT%
echo DB_SERVER=mysql_local
echo.
echo # REM REDIS CONFIG
echo REDIS_KEY=app_state
echo REDIS_CONNECTION=redis://redis_local:6379
) > .env

echo [OK] Файл .env создан:
type .env
echo ------------------------------

:: ---------------------------
:: 3. Клонируем API
:: ---------------------------
if not exist "pflac_api" (
    echo [INFO] Клонируем API...
    git clone https://github.com/fxhxyz4/pflac_api.git
) else (
    echo [INFO] API уже клонирован.
)

:: ---------------------------
:: 4. Создаём сеть Docker
:: ---------------------------
docker network create pflac_network >nul 2>&1
echo [OK] Docker сеть pflac_network готова.

:: ---------------------------
:: 5. Запуск Redis (Docker)
:: ---------------------------
echo [INFO] Запуск Redis...
docker rm -f redis_local >nul 2>&1
docker run -d --name redis_local --network pflac_network -p 6379:6379 redis:latest
echo [OK] Redis запущен: redis_local:6379

:: ---------------------------
:: 6. Запуск MySQL (Docker)
:: ---------------------------
echo [INFO] Запуск MySQL...
docker rm -f mysql_local >nul 2>&1
cd pflac_api
set SCHEMA_FILE=.\db\scheme.sql
if not exist "%SCHEMA_FILE%" (
    echo [ERROR] SQL-файл %SCHEMA_FILE% не найден!
    exit /b 1
)
docker run -d --name mysql_local --network pflac_network -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=%DB_NAME% -e MYSQL_USER=%DB_USER% -e MYSQL_PASSWORD=%DB_PASS% -p %DB_PORT%:3306 mysql:8 --disable-log-bin

echo [INFO] Ожидаем запуска MySQL...
:wait_mysql
docker exec mysql_local mysql -u%DB_USER% -p%DB_PASS% -e "SELECT 1;" %DB_NAME% >nul 2>&1
if errorlevel 1 (
    echo MySQL ещё не готов... ждём 2 сек
    timeout /t 2 /nobreak >nul
    goto wait_mysql
)
echo [OK] MySQL готов!

:: ---------------------------
:: 6.1 Импорт схемы
:: ---------------------------
echo [INFO] Импортируем SQL-схему...
docker exec -i mysql_local mysql -u%DB_USER% -p%DB_PASS% %DB_NAME% < "%SCHEMA_FILE%"
if errorlevel 1 (
    echo [ERROR] Ошибка при импорте схемы!
    exit /b 1
) else (
    echo [OK] Схема успешно импортирована!
)
cd ..

:: ---------------------------
:: 7. Запуск PHPMyAdmin (Docker)
:: ---------------------------
echo [INFO] Запуск PHPMyAdmin...
docker rm -f phpmyadmin_local >nul 2>&1
docker run -d --name phpmyadmin_local --network pflac_network -e PMA_HOST=mysql_local -e PMA_PORT=3306 -e PMA_ARBITRARY=1 -p 8080:80 phpmyadmin/phpmyadmin:latest
echo.
echo [OK] PHPMyAdmin: http://localhost:8080
echo !!! В поле 'Сервер' phpMyAdmin используйте: mysql_local
echo.

:: ---------------------------
:: 8. Запуск локального API (Docker)
:: ---------------------------
echo [INFO] Строим образ API...
docker build -t pflac_api_image .\pflac_api

echo [INFO] Запуск API...
docker rm -f pflac_api_local >nul 2>&1
docker run -d --name pflac_api_local --network pflac_network --env-file .env -p 8000:8000 pflac_api_image

echo [OK] API запущен: http://localhost:8000
echo [INFO] Проверить статус API: http://localhost:8000/status/
pause
