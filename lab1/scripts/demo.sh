#!/usr/bin/env bash
# Прогон лабораторной: репликация, отказ мастера, запись через HAProxy,
# возврат ноды и автоматическое догоняние данных.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p evidence

export PGPASSWORD=postgres
export PGCONNECT_TIMEOUT=5
# statement_timeout срабатывает только на живом сервере.
# Пока HAProxy ещё держит мёртвый бэкенд, клиентский timeout обязателен:
# у прокси timeout server = 30m, без обёртки psql зависнет на полчаса.
export PGOPTIONS='-c statement_timeout=8000'
PSQL=(psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1)

log() {
  printf '\n===== %s =====\n' "$*"
}

role_of() {
  local port="$1"
  "${PSQL[@]}" -p "$port" -tAc "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END;" 2>/dev/null || true
}

wait_ready() {
  local port="$1"
  local i
  for i in $(seq 1 90); do
    if pg_isready -h 127.0.0.1 -p "$port" -U postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "порт $port так и не открылся" >&2
  return 1
}

patroni_role() {
  local container="$1"
  local host="$2"
  docker exec "$container" curl -sf "http://${host}:8008/patroni" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("role","?"))' 2>/dev/null || echo down
}

haproxy_csv() {
  curl -sf 'http://127.0.0.1:7000/;csv' | awk -F, 'NR==1 || $1=="postgres" {print}'
}

{
  log "роли нод до записи"
  wait_ready 5433
  wait_ready 5434
  wait_ready 5432

  # Ждём, пока Patroni раздаст роли и HAProxy увидит лидера.
  for i in $(seq 1 45); do
    r0="$(role_of 5433)"
    r1="$(role_of 5434)"
    echo "попытка $i: pg-master:5433=$r0 pg-slave:5434=$r1"
    if { [ "$r0" = primary ] && [ "$r1" = replica ]; } || { [ "$r0" = replica ] && [ "$r1" = primary ]; }; then
      break
    fi
    sleep 2
  done

  echo "patroni pg-master: $(patroni_role pg-master pg-master)"
  echo "patroni pg-slave: $(patroni_role pg-slave pg-slave)"
  log "HAProxy до отказа"
  haproxy_csv || true

  if [ "$(role_of 5433)" = primary ]; then
    LEADER_PORT=5433
    LEADER_NAME=pg-master
    REPLICA_PORT=5434
  else
    LEADER_PORT=5434
    LEADER_NAME=pg-slave
    REPLICA_PORT=5433
  fi
  echo "лидер: $LEADER_NAME (host port $LEADER_PORT), реплика port $REPLICA_PORT"

  log "ждём synchronous standby, иначе Patroni не отдаст лидерство реплике"
  for i in $(seq 1 30); do
    sync_state="$("${PSQL[@]}" -p "$LEADER_PORT" -tAc "SELECT COALESCE(sync_state,'') FROM pg_stat_replication LIMIT 1;" 2>/dev/null || true)"
    echo "попытка $i: sync_state=${sync_state:-нет реплики}"
    if [ "$sync_state" = sync ]; then
      break
    fi
    sleep 2
  done
  if [ "$sync_state" != sync ]; then
    echo "FAIL: реплика не стала synchronous. Останавливать лидера нельзя: при synchronous_mode Patroni не промоутит ноду, которой нет в ключе /sync." >&2
    exit 1
  fi

  log "создание таблицы на лидере"
  "${PSQL[@]}" -p "$LEADER_PORT" <<'SQL'
DROP TABLE IF EXISTS lab_ha;
CREATE TABLE lab_ha (
    id int PRIMARY KEY,
    note text NOT NULL,
    written_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO lab_ha (id, note) VALUES (1, 'записано на исходном лидере');
SELECT id, note FROM lab_ha ORDER BY id;
SQL

  log "чтение с реплики"
  "${PSQL[@]}" -p "$REPLICA_PORT" -c "SELECT id, note FROM lab_ha ORDER BY id;"

  log "попытка записи на реплику (ожидаем отказ)"
  set +e
  "${PSQL[@]}" -p "$REPLICA_PORT" -c "INSERT INTO lab_ha (id, note) VALUES (99, 'это не должно записаться');"
  echo "код выхода psql на реплике: $?"
  set -e

  log "останавливаем текущего лидера: docker stop $LEADER_NAME"
  date -u +%Y-%m-%dT%H:%M:%SZ
  docker stop "$LEADER_NAME"

  log "ждём, пока запись через HAProxy :5432 снова пройдёт"
  ok=0
  for i in $(seq 1 40); do
    if timeout 12 "${PSQL[@]}" -p 5432 -c "INSERT INTO lab_ha (id, note) VALUES (2, 'записано через HAProxy после падения лидера');" >/tmp/haproxy-insert.txt 2>&1; then
      echo "вставка через HAProxy удалась на попытке $i"
      cat /tmp/haproxy-insert.txt
      ok=1
      break
    fi
    echo "попытка $i: ещё нельзя писать"
    tail -n 2 /tmp/haproxy-insert.txt || true
    sleep 3
  done
  if [ "$ok" != 1 ]; then
    echo "FAIL: через entrypoint так и не удалось записать" >&2
    exit 1
  fi

  log "кто теперь лидер"
  echo "pg-master patroni: $(patroni_role pg-master pg-master)"
  echo "pg-slave patroni: $(patroni_role pg-slave pg-slave)"
  echo "роль :5433 $(role_of 5433)"
  echo "роль :5434 $(role_of 5434)"
  log "HAProxy после отказа"
  haproxy_csv || true

  log "чтение через HAProxy"
  "${PSQL[@]}" -p 5432 -c "SELECT id, note, pg_is_in_recovery() AS this_connection_is_replica FROM lab_ha ORDER BY id;"

  SURVIVOR=pg-slave
  if [ "$LEADER_NAME" = pg-slave ]; then
    SURVIVOR=pg-master
  fi
  log "хвост лога выжившей ноды ($SURVIVOR)"
  docker logs --tail 80 "$SURVIVOR" 2>&1

  log "возвращаем $LEADER_NAME и пишем ещё одну строку, пока он догоняет"
  docker start "$LEADER_NAME"
  "${PSQL[@]}" -p 5432 -c "INSERT INTO lab_ha (id, note) VALUES (3, 'записано, пока старый лидер возвращался');"

  log "ждём, что вернувшаяся нода стала репликой и видит все три строки"
  caught=0
  for i in $(seq 1 45); do
    back_role="$(role_of "$LEADER_PORT")"
    rows="$("${PSQL[@]}" -p "$LEADER_PORT" -tAc "SELECT count(*) FROM lab_ha;" 2>/dev/null || echo err)"
    echo "попытка $i: $LEADER_NAME role=$back_role rows=$rows"
    if [ "$back_role" = replica ] && [ "$rows" = 3 ]; then
      caught=1
      break
    fi
    sleep 3
  done

  log "содержимое на обеих нодах"
  echo "-- port $LEADER_PORT ($LEADER_NAME)"
  "${PSQL[@]}" -p "$LEADER_PORT" -c "SELECT id, note FROM lab_ha ORDER BY id;" || true
  echo "-- port $REPLICA_PORT"
  "${PSQL[@]}" -p "$REPLICA_PORT" -c "SELECT id, note FROM lab_ha ORDER BY id;" || true

  log "хвост лога вернувшейся ноды ($LEADER_NAME)"
  docker logs --tail 100 "$LEADER_NAME" 2>&1

  if [ "$caught" != 1 ]; then
    echo "FAIL: нода не догнала данные после возвращения" >&2
    exit 1
  fi
  echo
  echo "OK: репликация, отказ мастера и автоматическое догоняние прошли"
} 2>&1 | tee evidence/demo.log
