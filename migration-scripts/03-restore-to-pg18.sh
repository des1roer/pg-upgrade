#!/bin/bash
# 03-restore-to-pg18.sh — прямое восстановление бекапа PG17 в кластер PG18
# Запускать: docker exec patroni-pgbackup /scripts/03-restore-to-pg18.sh
set -euo pipefail

PROBACKUP="${PROBACKUP_BIN:-pg_probackup-17}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
INSTANCE_17="pg17_cluster"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Прямое восстановление бекапа PG17 в PG18 ==="

# Шаг 1: Поиск последнего бекапа
echo ""
echo "[1/5] Поиск последнего бекапа PG17..."
LATEST_BACKUP_ID=$($PROBACKUP show \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_17" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
backups = json.load(sys.stdin)
valid = [b for b in backups if b.get('status') == 'OK']
if not valid:
    print('NONE')
else:
    print(valid[-1]['id'])
" 2>/dev/null || echo "NONE")

if [ "$LATEST_BACKUP_ID" = "NONE" ]; then
  echo "❌ Нет бекапов. Сначала выполните: 01-backup-pg17.sh"
  exit 1
fi
echo "   ID бекапа: $LATEST_BACKUP_ID"

# Шаг 2: Создание дампа схемы PG17 (для создания структуры в PG18)
echo ""
echo "[2/5] Дамп схемы PG17..."
PGPASSWORD=superpass pg_dump \
  -h postgresql1 -p 5432 -U postgres \
  --schema-only \
  --no-owner \
  --no-acl \
  --file="/tmp/schema_pg17_${TIMESTAMP}.sql" \
  mydb
echo "   Схема сохранена"

# Шаг 3: Восстановление схемы в PG18
echo ""
echo "[3/5] Восстановление схемы в PG18..."
PGPASSWORD=superpass psql \
  -h postgresql4 -p 5432 -U postgres \
  -d mydb \
  -f "/tmp/schema_pg17_${TIMESTAMP}.sql"
echo "   Схема восстановлена"

# Шаг 4: Восстановление данных через pg_probackup restore в PG18
echo ""
echo "[4/5] Восстановление данных из бекапа в PG18..."
RESTORE_DIR="/tmp/restore_to_pg18_${TIMESTAMP}"
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"

$PROBACKUP restore \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_17" \
  --pgdata="$RESTORE_DIR" \
  --log-filename="$BACKUP_DIR/logs/restore_pg18_${TIMESTAMP}.log" \
  --progress

# Шаг 5: Копирование данных в data-каталог PG18
echo ""
echo "[5/5] Перенос данных в PG18..."
echo ""
echo "⚠️  ВАЖНО: Этот шаг требует остановки Patroni на PG18!"
echo "   Выполните вручную внутри контейнера patroni-pg4:"
echo ""
echo "   patronictl stop dc2"
echo "   rm -rf /home/postgres/pgdata/pgdata/*"
echo "   cp -r $RESTORE_DIR/* /home/postgres/pgdata/pgdata/"
echo "   chown -R postgres:postgres /home/postgres/pgdata/pgdata"
echo "   patronictl start dc2"
echo ""
echo "   Или используйте pg_upgrade (скрипт 02-migrate-pgbackup.sh, вариант A)"