#!/bin/bash
# 01-check-compatibility.sh — проверка совместимости перед миграцией 17→18
set -euo pipefail

PG17_CONTAINER="${PG17_CONTAINER:-patroni-pg1}"

# Хелпер — выполняет psql внутри контейнера
run_pg17() {
    docker exec "$PG17_CONTAINER" psql -U postgres -d "$1" -c "$2"
}

echo "=== Проверка совместимости PostgreSQL 17 → 18 ==="

# 1. Версия PG17
echo "[1] Версия PG17:"
run_pg17 postgres "SELECT version();"

# 2. Расширения
echo "[2] Установленные расширения в PG17:"
run_pg17 mydb "
SELECT e.extname, e.extversion, n.nspname AS schema
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY e.extname;
"

# 3. Размер базы
echo "[3] Размер базы mydb в PG17:"
run_pg17 mydb "SELECT pg_size_pretty(pg_database_size('mydb')) AS db_size;"

# 4. Активные подключения
echo "[4] Активные подключения к PG17:"
run_pg17 postgres "SELECT count(*) AS active_connections FROM pg_stat_activity;"

# 5. Контрольные суммы
echo "[5] Настройки контрольных сумм PG17:"
run_pg17 postgres "SHOW data_checksums;"

# 6. Список пользователей
echo "[6] Роли в PG17:"
run_pg17 postgres "SELECT rolname, rolsuper, rolcanlogin FROM pg_roles WHERE rolname = 'admin' OR rolname = 'postgres';"

# 7. Список баз
echo "[7] Базы данных в PG17:"
run_pg17 postgres "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"

echo ""
echo "=== Проверка завершена. Если всё зелёное — можно переходить к шагу 2 ==="
