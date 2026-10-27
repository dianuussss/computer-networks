# ЛР 3. HA Postgres Cluster

Двухнодовый Postgres 15 под Patroni 3.3.2. Лидер выбирается через ZooKeeper, снаружи кластер виден одним адресом HAProxy: писать можно только в текущего мастера, реплика догоняет сама.

## Что крутится

| Сервис | Контейнер | Куда ходить с хоста |
| --- | --- | --- |
| Postgres, первая нода | `pg-master` | `127.0.0.1:5433` |
| Postgres, вторая нода | `pg-slave` | `127.0.0.1:5434` |
| HAProxy, точка входа | `postgres_entrypoint` | `127.0.0.1:5432` (база), [статистика](http://127.0.0.1:7000/) |
| ZooKeeper | `zoo` | `127.0.0.1:2181` |

Логин и пароль: `postgres` / `postgres`, база `postgres`.

Имя контейнера не обещает роль. Лидер — тот, у кого Patroni взял lock в ZooKeeper. HAProxy пускает трафик только туда: `GET /` на порту 8008 у Patroni 3.3.2 отвечает 200 только у primary.

## Запуск

Нужны Docker и клиент `psql`.

```bash
docker compose up -d --build
```

Подождать, пока одна нода станет primary, вторая replica, и в `pg_stat_replication` у лидера будет `sync_state = sync`. Проверка:

```bash
PGPASSWORD=postgres psql -h 127.0.0.1 -p 5432 -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery();"
```

`f` значит, что соединение через HAProxy попало на лидера.

Полный прогон из методички (запись, отказ мастера, возврат ноды) делает `scripts/demo.sh`. Он сам останавливает текущего лидера, это не безобидная команда.

```bash
bash scripts/demo.sh
```

Остановить стенд: `docker compose down`. Тома с данными: `docker compose down -v`.

## Отчёт

Ход работы, ответы на вопросы и разбор падения мастера: [REPORT.md](REPORT.md).
