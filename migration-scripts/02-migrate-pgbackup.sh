#!/bin/bash
# 02-migrate-pgbackup.sh — миграция PG17 → PG18 через pg_probackup restore + pg_upgrade
# Запускать: docker exec patroni-pgbackup /scripts/02-migrate-pgbackup.sh
set -euo pipefail

PROBACKUP="${PROBACKUP_BIN:-pg_probackup-17}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
INSTANCE_17="pg17_cluster"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Миграция PG17 → PG18 через pg_probackup ==="

# Шаг 1: Поиск последнего полного бекапа
echo ""
echo "[1/7] Поиск последнего полного бекапа PG17..."
LATEST_BACKUP_ID=$($PROBACKUP show \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_17" \
  --format=json 2>/dev/null | python3 -c "
import json, sys
backups = json.load(sys.stdin)
full_backups = [b for b in backups if b.get('backup-type') == 'FULL' and b.get('status') == 'OK']
if not full_backups:
    print('NONE')
else:
    print(full_backups[-1]['id'])
" 2>/dev/null || echo "NONE")

if [ "$LATEST_BACKUP_ID" = "NONE" ]; then
  echo "❌ Нет полных бекапов. Сначала выполните: 01-backup-pg17.sh"
  exit 1
fi
echo "   ID бекапа: $LATEST_BACKUP_ID"

# Шаг 2: Создание инкрементального бекапа (на случай изменений после полного)
echo ""
echo "[2/7] Создание инкрементального DELTA-бекапа..."
$PROBACKUP backup \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_17" \
  --host=postgresql1 \
  --port=5432 \
  --user=postgres \
  --compress \
  --stream \
  --backup-type=DELTA \
  --parent-backup-id="$LATEST_BACKUP_ID" \
  --log-filename="$BACKUP_DIR/logs/delta_${TIMESTAMP}.log" \
  --progress || echo "   ⚠️  DELTA не удался, использую полный"

# Шаг 3: Остановка приложений
echo ""
echo "[3/7] ⚠️  Остановите приложения, пишущие в PG17!"
echo "   Нажмите Enter, чтобы продолжить..."
read -r

# Шаг 4: Переключение PG17 в read-only (через Patroni)
echo ""
echo "[4/7] Переключение PG17 в режим только чтение..."
psql -h postgresql1 -p 5432 -U postgres -c "ALTER SYSTEM SET default_transaction_read_only = on;"
psql -h postgresql1 -p 5432 -U postgres -c "SELECT pg_reload_conf();"

# Шаг 5: Финальный инкрементальный бекап (после остановки приложений)
echo ""
echo "[5/7] Финальный бекап (после остановки приложений)..."
$PROBACKUP backup \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_17" \
  --host=postgresql1 \
  --port=5432 \
  --user=postgres \
  --compress \
  --stream \
  --backup-type=DELTA \
  --log-filename="$BACKUP_DIR/logs/final_${TIMESTAMP}.log" \
  --progress

# Шаг 6: Восстановление бекапа во временный каталог
echo ""
echo "[6/7] Восстановление бекапа в /tmp/restore_pg17..."
RESTORE_DIR="/tmp/restore_pg17_${TIMESTAMP}"
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"

$PROBACKUP restore \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_17" \
  --pgdata="$RESTORE_DIR" \
  --log-filename="$BACKUP_DIR/logs/restore_${TIMESTAMP}.log" \
  --progress

echo "   Бекап восстановлен в: $RESTORE_DIR"

# Шаг 7: Инструкция по завершению миграции
echo ""
echo "[7/7] Миграция через pg_probackup завершена!"
echo ""
echo "📋 Дальнейшие действия:"
echo ""
echo "   ВАРИАНТ A — pg_upgrade (in-place, быстрый):"
echo "   -------------------------------------------"
echo "   1. Зайдите в контейнер PG18:"
echo "      docker exec -it patroni-pg4 bash"
echo "   2. Остановите Patroni: patronictl stop dc2"
echo "   3. Выполните pg_upgrade:"
echo "      /usr/lib/postgresql/18/bin/pg_upgrade \\"
echo "        --old-bindir=/usr/lib/postgresql/17/bin \\"
echo "        --new-bindir=/usr/lib/postgresql/18/bin \\"
echo "        --old-datadir=$RESTORE_DIR \\"
echo "        --new-datadir=/home/postgres/pgdata/pgdata \\"
echo "        --link"
echo ""
echo "   ВАРИАНТ B — pg_dump/pg_restore (надёжный):"
echo "   -------------------------------------------"
echo "   1. Сделайте dump из восстановленного бекапа:"
echo "      docker exec patroni-pgbackup pg_dump -h postgresql1 -p 5432 -U postgres \\"
echo "        -Fc mydb > /backups/mydb_pg17_${TIMESTAMP}.dump"
echo "   2. Восстановите в PG18:"
echo "      docker exec patroni-pgbackup pg_restore -h postgresql4 -p 5432 -U postgres \\"
echo "        -d mydb /backups/mydb_pg17_${TIMESTAMP}.dump"
echo ""
echo "   ВАРИАНТ C — Логическая репликация (zero-downtime):"
echo "   --------------------------------------------------"
echo "   Используйте скрипт 04-migrate-logical-replication.sh"
