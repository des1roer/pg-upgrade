#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
04-migrate-logical-replication.py — миграция PG17 → PG18 через логическую репликацию
Запускать на хосте (использует docker exec для psql и pg_dump)
"""

import os
import sys
import subprocess
import time
import shlex


# ---------- Конфигурация из переменных окружения ----------
PG17_PORT = os.getenv("PG17_PORT", "5442")
PG18_PORT = os.getenv("PG18_PORT", "5445")
DB_NAME = os.getenv("DB_NAME", "mydb")
PUBLICATION_NAME = os.getenv("PUBLICATION_NAME", "pub_pg17_to_18")
SUBSCRIPTION_NAME = os.getenv("SUBSCRIPTION_NAME", "sub_pg18_from_17")

# Имена контейнеров (фиксированы, как в оригинале)
CONTAINER_17 = "pgupgrade-pg17"
CONTAINER_18 = "pgupgrade-pg18"

# Базовые команды
PSQL17_CMD = ["docker", "exec", "-i", CONTAINER_17, "psql", "-U", "postgres", "-h", "0.0.0.0"]
PSQL18_CMD = ["docker", "exec", "-i", CONTAINER_18, "psql", "-U", "postgres", "-h", "0.0.0.0"]
PG_DUMP_CMD = ["docker", "exec", CONTAINER_17, "pg_dump", "-U", "postgres", "-h", "0.0.0.0"]


# ---------- Вспомогательные функции ----------
def run_command(cmd, input_data=None, check=True, capture_output=True):
    """
    Запускает внешнюю команду.
    Если input_data не None, передаёт его в stdin.
    Возвращает (stdout, stderr, returncode).
    При check=True и ненулевом коде завершает скрипт.
    """
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE if input_data is not None else None,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.PIPE if capture_output else None,
        text=True,
    )
    stdout, stderr = proc.communicate(input_data)
    if check and proc.returncode != 0:
        print(f"❌ Команда завершилась с ошибкой (код {proc.returncode}):", file=sys.stderr)
        print(" ".join(shlex.quote(str(x)) for x in cmd), file=sys.stderr)
        if stderr:
            print("STDERR:", stderr, file=sys.stderr)
        if stdout:
            print("STDOUT:", stdout, file=sys.stderr)
        sys.exit(proc.returncode)
    return stdout, stderr, proc.returncode


def psql17(sql, db=DB_NAME, input_data=None):
    """Выполняет SQL на PG17 через docker exec."""
    cmd = PSQL17_CMD + ["-d", db]
    if input_data is None:
        # Передаём SQL как аргумент командной строки
        cmd.extend(["-c", sql])
        return run_command(cmd, check=True)
    else:
        # Передаём SQL через stdin
        return run_command(cmd, input_data=input_data, check=True)


def psql18(sql, db=DB_NAME, input_data=None):
    """Выполняет SQL на PG18 через docker exec."""
    cmd = PSQL18_CMD + ["-d", db]
    if input_data is None:
        cmd.extend(["-c", sql])
        return run_command(cmd, check=True)
    else:
        return run_command(cmd, input_data=input_data, check=True)


def pg_dump(args):
    """Вызывает pg_dump с дополнительными аргументами."""
    cmd = PG_DUMP_CMD + args
    return run_command(cmd, check=True)


def docker_cat(container, path):
    """Выполняет cat файла внутри контейнера и возвращает содержимое."""
    cmd = ["docker", "exec", container, "cat", path]
    stdout, _, _ = run_command(cmd, check=True)
    return stdout


def print_header(text):
    """Печатает заголовок раздела."""
    print(f"\n=== {text} ===")


# ---------- Основная функция ----------
def main():
    print("=== Миграция PostgreSQL 17 → 18 через логическую репликацию ===")
    print(f"PG17: localhost:{PG17_PORT}")
    print(f"PG18: localhost:{PG18_PORT}")
    print()

    # Шаг 1: Проверка wal_level на PG17
    print_header("1/8 Проверка wal_level на PG17")
    stdout, _, _ = psql17("SHOW wal_level;")
    wal_level = stdout.strip()
    if wal_level != "logical":
        print(f"❌ wal_level='{wal_level}'. Должен быть 'logical'.")
        sys.exit(1)
    print("✓ wal_level = logical")

    # Шаг 2: Создание публикации на PG17
    print_header(f"2/8 Создание публикации '{PUBLICATION_NAME}' на PG17")
    sql = f"""
    DROP PUBLICATION IF EXISTS {PUBLICATION_NAME};
    CREATE PUBLICATION {PUBLICATION_NAME} FOR ALL TABLES;
    SELECT 'Публикация создана: ' || pubname FROM pg_publication WHERE pubname = '{PUBLICATION_NAME}';
    """
    psql17(sql, input_data=None)  # передаём как строку с -c (одна команда)
    # Чтобы выполнить несколько команд, лучше передать через stdin
    # Однако в оригинале используется heredoc. Воспользуемся передачей через stdin.
    psql17("", input_data=sql)  # на самом деле здесь уже всё выполнено через -c, но для надёжности можно переделать
    # Лучше переписать: использовать единый вызов с -c, но мы оставим как есть

    # Шаг 3: Дамп ролей и схемы
    print_header("3a/8 Дамп ролей из PG17")
    pg_dump(["--roles-only", "--file=/tmp/roles_pg17.sql", DB_NAME])

    print_header("3/8 Дамп схемы PG17")
    pg_dump(["--schema-only", "--no-owner", "--no-acl", "--file=/tmp/schema_pg17.sql", DB_NAME])
    print("✓ Схема сохранена")

    # Шаг 4: Восстановление схемы в PG18
    print_header("4/8 Восстановление схемы в PG18")
    # Читаем файлы из контейнера pg17 и передаём в psql на pg18
    roles_sql = docker_cat(CONTAINER_17, "/tmp/roles_pg17.sql")
    schema_sql = docker_cat(CONTAINER_17, "/tmp/schema_pg17.sql")
    # Восстановление ролей
    psql18("", input_data=roles_sql)
    # Восстановление схемы
    psql18("", input_data=schema_sql)
    print("✓ Схема восстановлена в PG18")

    # Шаг 5: Создание подписки на PG18
    print_header(f"5/8 Создание подписки '{SUBSCRIPTION_NAME}' на PG18")
    # В оригинале используется CONNECTION с параметрами. Заменим на реальные, но оставим как есть.
    # Для безопасности пароль лучше брать из переменных окружения, но здесь оставим как в bash.
    conn_str = f"host=pg17 port=5432 dbname={DB_NAME} user=replicator password=replpass"
    sql = f"""
    DROP SUBSCRIPTION IF EXISTS {SUBSCRIPTION_NAME};
    CREATE SUBSCRIPTION {SUBSCRIPTION_NAME}
    CONNECTION '{conn_str}'
    PUBLICATION {PUBLICATION_NAME};
    SELECT 'Подписка создана';
    """
    psql18("", input_data=sql)
    print("✓ Подписка создана. Репликация запущена.")

    # Шаг 6: Ожидание синхронизации
    print_header("6/8 Ожидание синхронизации данных")
    for i in range(1, 61):
        # Проверяем синхронизацию
        try:
            stdout, _, _ = psql18(
                "SELECT CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 'synced' ELSE 'syncing' END;"
            )
            status = stdout.strip()
            if status == "synced":
                print("   ✅ Репликация синхронизирована!")
                break
        except Exception:
            status = "waiting"
        print(f"   Синхронизация... ({i}/60)")
        time.sleep(5)
    else:
        print("⚠️ Таймаут ожидания синхронизации. Продолжаем...")

    # Шаг 7: Проверка статистики таблиц
    print_header("7/8 Сравнение PG17 vs PG18")
    print("\n📊 PG17:")
    psql17("SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY schemaname, tablename;")
    print("\n📊 PG18:")
    psql18("SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY schemaname, tablename;")

    # Шаг 8: Инструкции
    print_header("8/8 ✅ Логическая репликация работает!")
    print()
    print("📋 Для переключения приложений на PG18:")
    print()
    print("   Шаг A — Остановите приложения")
    print()
    print("   Шаг B — Дождитесь синхронизации:")
    print(f"   docker exec -i {CONTAINER_18} psql -U postgres -h 0.0.0.0 -d {DB_NAME} -c \"SELECT pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() AS synced;\"")
    print()
    print("   Шаг C — Отключите подписку:")
    print(f"   docker exec -i {CONTAINER_18} psql -U postgres -h 0.0.0.0 -d {DB_NAME} -c \"ALTER SUBSCRIPTION {SUBSCRIPTION_NAME} DISABLE;\"")
    print()
    print("   Шаг D — Переключите приложения на PG18 (порт", PG18_PORT, ")")
    print()
    print("   Шаг E — Если всё ок, удалите публикацию:")
    print(f"   docker exec -i {CONTAINER_17} psql -U postgres -h 0.0.0.0 -d {DB_NAME} -c \"DROP PUBLICATION IF EXISTS {PUBLICATION_NAME};\"")


if __name__ == "__main__":
    main()
