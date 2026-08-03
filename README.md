# pg-upgrade

https://pgconf.ru/talk/1588270 - презентация от разработчиков patroni

```bash
docker exec patroni-pg1 psql -U postgres -d postgres -c "ALTER ROLE admin LOGIN;" -c "ALTER ROLE admin PASSWORD 'admin';"
docker exec patroni-pg2 psql -U postgres -d postgres -c "ALTER ROLE admin LOGIN;" -c "ALTER ROLE admin PASSWORD 'admin';"
docker exec patroni-pg3 psql -U postgres -d postgres -c "ALTER ROLE admin LOGIN;" -c "ALTER ROLE admin PASSWORD 'admin';"
```

superuser
```bash
docker exec patroni-pg3 psql -U postgres -d postgres -c "SET password_encryption = 'scram-sha-256'; ALTER USER postgres PASSWORD 'superpass';"
```

Проверка текущего состояния:

```bash
curl http://localhost:8008 | python3 -m json.tool # pg1
curl http://localhost:8009 | python3 -m json.tool # pg2
curl http://localhost:8010 | python3 -m json.tool  # pg3
```

В "role": "primary" — лидер, "role": "replica" — реплика.

Тест failover:

# Найдите лидера (тот у кого "primary")
```bash
curl -s http://localhost:8008 | grep role
curl -s http://localhost:8009 | grep role
curl -s http://localhost:8010 | grep role
```

# Прибейте его (например, если pg2 лидер):
```bash
docker stop patroni-pg3
```

# Через 3-5 секунд проверьте:
```bash
curl -s http://localhost:8008 | python3 -m json.tool
curl -s http://localhost:8010 | python3 -m json.tool
```

Один из оставшихся должен стать "primary" — и это будет Patroni auto-failover.

После теста — верните обратно:

```bash
docker start patroni-pg3
```
# Он автоматически подключится как replica
```bash
curl -s http://localhost:8009 | python3 -m json.tool
```

Или через HAProxy stats:

# Проверить кто alive/dead
```bash
curl -s http://localhost:7000 | grep -i pg
```

# Миграция

Сделать скрипты исполняемыми:
```bash
chmod +x migration-scripts/*.sh
```
Список
```bash
# 1. Собрать образ pgbackup
docker compose build pgbackup

# 2. Запустить всё
docker compose up -d

# 3. Проверить кластеры
docker exec pgupgrade-pg17 patronictl list
docker exec pgupgrade-pg18 patronictl list

# 4. Бекап PG17
docker exec patroni-pgbackup /scripts/01-backup-pg17.sh

# 5. Миграция
docker exec patroni-pgbackup /scripts/02-migrate-pgbackup.sh

# 6. Бекап PG18 + проверка
docker exec patroni-pgbackup /scripts/04-backup-pg18-verify.sh
docker exec patroni-pgbackup /scripts/05-post-upgrade-checks.sh
```
```bash
chmod +x start-cluster.sh
```
pg 18 start
```bash
docker compose stop postgresql4 postgresql5 postgresql6

# 2. Удалить конфигурацию кластера из etcd
docker exec patroni-etcd etcdctl --endpoints=http://localhost:2379 del /service/dc2/ --prefix

# 3. Удалить данные PG18
docker compose rm -f postgresql4 postgresql5 postgresql6
docker volume rm patroni-pg4-data patroni-pg5-data patroni-pg6-data

# 4. Запустить только мастера
docker compose up -d postgresql4
sleep 20

# 5. Проверить
docker exec patroni-pg4 patronictl list

# 6. Запустить реплики
docker compose up -d postgresql5 postgresql6
sleep 15

# 7. Финальная проверка
docker exec patroni-pg4 patronictl list
```

```bash
# 1. Сначала проверьте wal_level на PG17 (должен быть logical)
docker exec patroni-pg1 bash -c "psql -U postgres -c 'SHOW wal_level;'"

# Если не logical — добавьте в docker-compose.yml для postgresql1/2/3:
# PATRONI_POSTGRESQL_PARAMETERS: "max_connections=100,shared_buffers=128MB,wal_level=logical"
# И перезапустите: docker compose restart postgresql1 postgresql2 postgresql3

# 2. Запустите миграцию
chmod +x migration-scripts/04-migrate-logical-replication.sh
./migration-scripts/04-migrate-logical-replication.sh

# 3. Когда будете готовы переключиться — выполните шаги из инструкции
```