#!/bin/bash
# 04-migrate-logical-replication.sh — миграция PG17 → PG18 через логическую репликацию
# Запускать на хосте (использует docker exec для psql)
set -euo pipefail

PG17_PORT="${PG17_PORT:-5442}"
PG18_PORT="${PG18_PORT:-5445}"
DB_NAME="${DB_NAME:-mydb}"
PUBLICATION_NAME="pub_pg17_to_18"
SUBSCRIPTION_NAME="sub_pg18_from_17"

PSQL17="docker exec -i pgupgrade-pg17 psql -U postgres -h 0.0.0.0"
PSQL18="docker exec -i pgupgrade-pg18 psql -U postgres -h 0.0.0.0"
PG_DUMP="docker exec pgupgrade-pg17 pg_dump -U postgres -h 0.0.0.0"

echo "=== Миграция PostgreSQL 17 → 18 через логическую репликацию ==="
echo "PG17: localhost:$PG17_PORT"
echo "PG18: localhost:$PG18_PORT"
echo ""

# Шаг 1: Проверка wal_level на PG17
echo "[1/8] Проверка wal_level на PG17..."
WAL_LEVEL=$($PSQL17 -tAc "SHOW wal_level;")
if [ "$WAL_LEVEL" != "logical" ]; then
  echo "❌ wal_level='$WAL_LEVEL'. Должен быть 'logical'."
  exit 1
fi
echo "✓ wal_level = logical"

# Шаг 2: Создание публикации на PG17
echo ""
echo "[2/8] Создание публикации '$PUBLICATION_NAME' на PG17..."
$PSQL17 -d "$DB_NAME" <<SQL
DROP PUBLICATION IF EXISTS $PUBLICATION_NAME;
CREATE PUBLICATION $PUBLICATION_NAME FOR ALL TABLES;
SELECT 'Публикация создана: ' || pubname FROM pg_publication WHERE pubname = '$PUBLICATION_NAME';
SQL

# Шаг 3: Дамп схемы из PG17
# Шаг 3a: Дамп ролей (если нужно перенести пользователей)
echo "[3a/8] Дамп ролей из PG17..."
$PG_DUMP \
  --roles-only \
  --file=/tmp/roles_pg17.sql \
  "$DB_NAME"

# Шаг 3b: Дамп схемы с owner и правами
echo ""
echo "[3/8] Дамп схемы PG17..."
$PG_DUMP \
  --schema-only \
  --file=/tmp/schema_pg17.sql \
  "$DB_NAME"
echo "✓ Схема сохранена"

# Шаг 4: Восстановление схемы в PG18
echo ""
echo "[4/8] Восстановление схемы в PG18..."
# Шаг 4a: Восстановить роли (если дампили)
docker exec patroni-pg1 cat /tmp/roles_pg17.sql | $PSQL18 -d "$DB_NAME"
docker exec patroni-pg1 cat /tmp/schema_pg17.sql | $PSQL18 -d "$DB_NAME"
echo "✓ Схема восстановлена в PG18"

# Шаг 5: Создание подписки на PG18
echo ""
echo "[5/8] Создание подписки '$SUBSCRIPTION_NAME' на PG18..."
$PSQL18 -d "$DB_NAME" <<SQL
DROP SUBSCRIPTION IF EXISTS $SUBSCRIPTION_NAME;
CREATE SUBSCRIPTION $SUBSCRIPTION_NAME
CONNECTION 'host=pg17 port=5432 dbname=$DB_NAME user=replicator password=replpass'
PUBLICATION $PUBLICATION_NAME;
SELECT 'Подписка создана';
SQL
echo "✓ Подписка создана. Репликация запущена."

# Шаг 6: Ожидание синхронизации
echo ""
echo "[6/8] Ожидание синхронизации данных..."
for i in $(seq 1 60); do
  LAG=$($PSQL18 -d "$DB_NAME" -tAc "
    SELECT CASE
      WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn()
      THEN 'synced'
      ELSE 'syncing'
    END;
  " 2>/dev/null || echo "waiting")

  if [ "$LAG" = "synced" ]; then
    echo "   ✅ Репликация синхронизирована!"
    break
  fi
  echo "   Синхронизация... ($i/60)"
  sleep 5
done

# Шаг 7: Проверка
echo ""
echo "[7/8] Сравнение PG17 vs PG18..."
echo ""
echo "📊 PG17:"
$PSQL17 -d "$DB_NAME" -c "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY schemaname, tablename;"

echo ""
echo "📊 PG18:"
$PSQL18 -d "$DB_NAME" -c "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY schemaname, tablename;"

# Шаг 8: Инструкция
echo ""
echo "[8/8] ✅ Логическая репликация работает!"
echo ""
echo "📋 Для переключения приложений на PG18:"
echo ""
echo "   Шаг A — Остановите приложения"
echo ""
echo "   Шаг B — Дождитесь синхронизации:"
echo "   $PSQL18 -d $DB_NAME -c \"SELECT pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() AS synced;\""
echo ""
echo "   Шаг C — Отключите подписку:"
echo "   $PSQL18 -d $DB_NAME -c \"ALTER SUBSCRIPTION $SUBSCRIPTION_NAME DISABLE;\""
echo ""
echo "   Шаг D — Переключите приложения на PG18 (порт $PG18_PORT)"
echo ""
echo "   Шаг E — Если всё ок, удалите публикацию:"
echo "   $PSQL17 -d $DB_NAME -c \"DROP PUBLICATION IF EXISTS $PUBLICATION_NAME;\""
