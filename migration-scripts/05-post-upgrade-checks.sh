#!/bin/bash
# 05-post-upgrade-checks.sh — проверка после миграции 17→18
set -euo pipefail

PG18_HOST="${PG18_HOST:-localhost}"
PG18_PORT="${PG18_PORT:-5445}"
DB_NAME="${DB_NAME:-mydb}"

echo "=== Пост-миграционные проверки PG18 ==="

# 1. Версия
echo "[1] Версия PostgreSQL:"
psql -h "$PG18_HOST" -p "$PG18_PORT" -U postgres -c "SELECT version();"

# 2. Размер базы
echo ""
echo "[2] Размер базы '$DB_NAME':"
psql -h "$PG18_HOST" -p "$PG18_PORT" -U postgres -d "$DB_NAME" -c "
SELECT pg_size_pretty(pg_database_size('$DB_NAME')) AS db_size;
"

# 3. Количество таблиц
echo ""
echo "[3] Количество пользовательских таблиц:"
psql -h "$PG18_HOST" -p "$PG18_PORT" -U postgres -d "$DB_NAME" -c "
SELECT count(*) AS table_count FROM pg_stat_user_tables;
"

# 4. Расширения
echo ""
echo "[4] Установленные расширения:"
psql -h "$PG18_HOST" -p "$PG18_PORT" -U postgres -d "$DB_NAME" -c "
SELECT e.extname, e.extversion FROM pg_extension e ORDER BY e.extname;
"

# 5. Индексы
echo ""
echo "[5] Статус индексов (нет ли invalid):"
psql -h "$PG18_HOST" -p "$PG18_PORT" -U postgres -d "$DB_NAME" -c "
SELECT indexrelid::regclass AS index_name, indisvalid, indisready
FROM pg_index
WHERE NOT indisvalid OR NOT indisready;
"

# 6. Запуск ANALYZE
echo ""
echo "[6] Запуск ANALYZE..."
psql -h "$PG18_HOST" -p "$PG18_PORT" -U postgres -d "$DB_NAME" -c "ANALYZE;"

# 7. Статистика по схемам
echo ""
echo "[7] Статистика по схемам:"
psql -h "$PG18_HOST" -p "$PG18_PORT" -U postgres -d "$DB_NAME" -c "
SELECT schemaname, count(*) AS tables,
       sum(n_live_tup) AS live_rows
FROM pg_stat_user_tables
GROUP BY schemaname
ORDER BY schemaname;
"

# 8. Проверка логов на ошибки
echo ""
echo "[8] Проверка логов PG18 на ошибки (последние 20 строк):"
docker logs patroni-pg4 --tail 20 2>/dev/null | grep -i "error\|fatal\|panic" || echo "   (нет критических ошибок в последних 20 строках)"

echo ""
echo "=== Пост-миграционные проверки завершены! ==="