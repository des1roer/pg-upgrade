#!/bin/bash
# start-cluster.sh — правильный запуск кластера PG18
set -euo pipefail

echo "=== Запуск кластера PG18 ==="

# 1. Убедиться, что etcd работает
echo "[1/4] Проверка etcd..."
docker compose up -d etcd
sleep 3

# 2. Запустить мастера
echo "[2/4] Запуск мастера (postgresql4)..."
docker compose up -d postgresql4

# 3. Ждать, пока станет мастером
echo "[3/4] Ожидание мастера..."
for i in $(seq 1 30); do
  ROLE=$(curl -sf http://localhost:8011/health 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('role',''))" 2>/dev/null || echo "waiting")
  if [ "$ROLE" = "master" ]; then
    echo "   ✅ postgresql4 стал мастером!"
    break
  fi
  echo "   Ожидание... ($i/30)"
  sleep 2
done

# 4. Запустить реплики
echo "[4/4] Запуск реплик (postgresql5, postgresql6)..."
docker compose up -d postgresql5 postgresql6

# 5. Финальная проверка
sleep 10
echo ""
echo "=== Состояние кластера ==="
docker exec patroni-pg4 patronictl list
