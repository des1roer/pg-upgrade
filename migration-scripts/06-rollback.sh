#!/bin/bash
# 06-rollback.sh — откат с PG18 обратно на PG17
set -euo pipefail

echo "=== Откат миграции: PG18 → PG17 ==="

# Вариант A: Если использовался pg_dump
echo ""
echo "Вариант A: Если миграция была через pg_dump — просто переключите приложения обратно на PG17"
echo "  Порт PG17: 5442 (localhost) или 5000 (HAProxy write)"
echo "  Никаких дополнительных действий не требуется."
echo ""

# Вариант B: Если использовалась логическая репликация
echo "Вариант B: Если миграция была через логическую репликацию:"
echo "  1. Переключите приложения на PG17 (порт 5442)"
echo "  2. Удалите подписку на PG18:"
echo "     psql -h localhost -p 5445 -U postgres -d mydb -c \"DROP SUBSCRIPTION IF EXISTS sub_pg18_from_17;\""
echo "  3. Удалите публикацию на PG17 (опционально):"
echo "     psql -h localhost -p 5442 -U postgres -d mydb -c \"DROP PUBLICATION IF EXISTS pub_pg17_to_18;\""
echo ""

# Вариант C: Если использовался pg_upgrade с --link
echo "Вариант C: Если миграция была через pg_upgrade с --link:"
echo "  ⚠️  Старые data-файлы были переиспользованы (hard links)."
echo "  Откат возможен ТОЛЬКО из бекапа."
echo "  Выполните:"
echo "    docker exec patroni-pg4 bash -c 'pg_ctl -D /home/postgres/pgdata/pgdata stop'"
echo "    docker exec patroni-pg1 bash -c 'pg_ctl -D /home/postgres/pgdata/pgdata start'"
echo ""

echo "=== Инструкции по откату предоставлены ==="