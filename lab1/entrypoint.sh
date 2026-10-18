#!/bin/bash
set -euo pipefail

# Официальный entrypoint образа postgres чинит права только если команда — postgres.
# Здесь команда — patroni, поэтому chown делаем сами, затем сбрасываем привилегии.
if [ "$(id -u)" = "0" ]; then
    mkdir -p /var/lib/postgresql/data
    chown -R postgres:postgres /var/lib/postgresql/data
    chmod 700 /var/lib/postgresql/data
    # Сокет, оставшийся в PGDATA после падения, pg_rewind открыть не может.
    # Живой сокет у нас в /tmp, эти файлы — мусор от прошлого запуска.
    find /var/lib/postgresql/data -name '.s.PGSQL.*' -delete || true
    exec gosu postgres "$@"
fi

exec "$@"
