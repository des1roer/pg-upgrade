#!/bin/bash
# 01-backup-pg17.sh — полный бекап PG17 через pg_probackup перед миграцией
# Запускать: docker exec patroni-pgbackup /scripts/01-backup-pg17.sh
set -euo pipefail

PROBACKUP_BIN="${PROBACKUP_BIN:-pg_probackup-17}"
BACKUPS_ROOT="${BACKUPS_ROOT:-/backups}"
INSTANCE="${INSTANCE:-pg17_cluster}"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

# Параметры подключения к PG17
DB_HOST="${DB_HOST:-postgresql1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-mydb}"
: "${PGPASSWORD:?PGPASSWORD не задан}"
export PGPASSWORD

echo "=== ШАГ 1: Полный бекап PG17 перед миграцией ==="
echo "Утилита: $PROBACKUP_BIN"
echo "Каталог: $BACKUPS_ROOT"
echo "Инстанс: $INSTANCE"
echo "Хост: $DB_HOST:$DB_PORT"
echo ""

BACKUP_DIR="$BACKUPS_ROOT/pro_backup"

# Инициализация каталога бекапов
if [ ! -d "$BACKUP_DIR/backups" ]; then
  echo "[1/4] Инициализация каталога бекапов..."
  "$PROBACKUP_BIN" init -B "$BACKUP_DIR"
fi

# Регистрация инстанса
echo "[2/4] Регистрация инстанса PG17..."
"$PROBACKUP_BIN" add-instance \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE" \
  -D /dev/null 2>/dev/null || echo "   (уже зарегистрирован)"

# Полный бекап
echo "[3/4] Создание полного бекапа PG17..."
"$PROBACKUP_BIN" backup \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE" \
  -b FULL \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  --compress \
  --stream \
  --temp-slot \
  --log-filename="$BACKUPS_ROOT/logs/backup_${TIMESTAMP}.log" \
  --progress

# Валидация
echo "[4/4] Валидация бекапа..."
"$PROBACKUP_BIN" validate \
  -B "$BACKUP_DIR" \
  --instance="$INSTANCE" \
  --log-filename="$BACKUPS_ROOT/logs/validate_${TIMESTAMP}.log"

echo ""
echo "✅ Бекап PG17 завершён!"
echo "📂 Бекапы на хосте: ./backups/"
echo ""
echo "   docker exec patroni-pgbackup $PROBACKUP_BIN show -B $BACKUP_DIR --instance=$INSTANCE"
echo ""
echo "⚠️  Если миграция сорвётся — восстановление:"
echo "   docker exec patroni-pgbackup $PROBACKUP_BIN restore -B $BACKUP_DIR --instance=$INSTANCE \\"
echo "     -h postgresql4 -p 5432 -U postgres -d mydb \\"
echo "     -D /tmp/restore --progress"