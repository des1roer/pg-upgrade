# pg-upgrade

```bash
docker exec patroni-pg1 psql -U postgres -d postgres -c "ALTER ROLE admin LOGIN;" -c "ALTER ROLE admin PASSWORD 'admin';"
```

Проверка текущего состояния:

```bash
curl http://localhost:8008  # pg1
curl http://localhost:8009  # pg2
curl http://localhost:8010  # pg3
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
docker stop patroni-pg2
```

# Через 3-5 секунд проверьте:
```bash
curl -s http://localhost:8008 | python3 -m json.tool
curl -s http://localhost:8010 | python3 -m json.tool
```

Один из оставшихся должен стать "primary" — и это будет Patroni auto-failover.

После теста — верните обратно:

```bash
docker start patroni-pg2
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
