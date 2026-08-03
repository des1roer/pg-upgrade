#!/bin/bash
# 04-backup-pg18-verify.sh — бекап PG18 после успешной миграции + верификация
# Запускать: docker exec patroni-pgbackup /scripts/04-backup-pg18-verify.sh
set -euo pipefail

PROBACKUP="${PROBACKUP_BIN:-pg_probackup-17}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
INSTANCE_18="pg18_cluster"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Бекап PG18 после миграции + верификация ==="

# Инициализация backup-каталога для PG18 (если ещё не сделано)
if [ ! -d "$BACKUP_DIR/backups/$INSTANCE_18" ]; then
  echo "[1/6] Инициализация каталога для PG18..."
  $PROBACKUP init -B "$BACKUP_DIR"
fi

# Регистрация инстанса PG18
echo "[2/6] Регистрация инстанса PG18..."
$PROBACKUP add-instance \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_18" \
  --pgdata=/dev/null 2>/dev/null || true

# Полный бекап PG18
echo "[3/6] Полный бекап PG18..."
$PROBACKUP backup \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_18" \
  --host=postgresql4 \
  --port=5432 \
  --user=postgres \
  --compress \
  --stream \
  --backup-type=FULL \
  --log-filename="$BACKUP_DIR/logs/pg18_full_${TIMESTAMP}.log" \
  --progress

# Валидация бекапа
echo "[4/6] Валидация бекапа PG18..."
$PROBACKUP validate \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_18" \
  --log-filename="$BACKUP_DIR/logs/validate_${TIMESTAMP}.log"

# Сравнение количества записей между PG17 и PG18
echo "[5/6] Сравнение данных PG17 vs PG18..."
echo ""
echo "   📊 Таблицы в PG17:"
PGPASSWORD=superpass psql -h postgresql1 -p 5432 -U postgres -d myb -c "
  SELECT schemaname, tablename, n_live_tup
  FROM pg_stat_user_tables
  ORDER BY schemaname, tablename;
" 2>/dev/null || echo "   (PG17 недоступен — уже выключен)"

echo ""
echo "   📊 Таблицы в PG18:"
PGPASSWORD=superpass psql -h postgresql4 -p 5432 -U postgres -d myd -c "
  SELECT schemaname, tablename, n_live_tup
  FROM pg_stat_user_tables
  ORDER BY schemaname, tablename;
"

# Список бекапов
echo "[6/6] Список всех бекапов:"
$PROBACKUP show \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE_18"

echo ""
echo "✅ Миграция завершена! Бекап PG18 создан."
echo "   Все бекапы хранятся в volume 'backups'"
echo "   Для просмотра: docker exec patroni-pgbackup $PROBACKUP show -B $BACKUP_DIR"