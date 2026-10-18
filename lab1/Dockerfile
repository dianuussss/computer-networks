FROM postgres:15

# Зависимости Patroni. Бинарники Postgres уже есть в базовом образе —
# Patroni ими и управляет, отдельный Postgres рядом не ставим.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        netcat-openbsd \
        python3-pip \
        curl \
        python3-psycopg2 \
        python3-venv \
        iputils-ping \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Patroni 3.3.2: OPTIONS/GET / на REST API — это проверка лидера.
# Именно на это рассчитан httpchk в HAProxy из методички.
# На более новых мажорах контракт / мог бы разъехаться, поэтому версия зафиксирована.
RUN python3 -m venv /opt/patroni-venv && \
    /opt/patroni-venv/bin/pip install --upgrade pip && \
    /opt/patroni-venv/bin/pip install --no-cache-dir \
        'patroni[zookeeper]==3.3.2' \
        'psycopg2-binary==2.9.10'

COPY postgres0.yml /postgres0.yml
COPY postgres1.yml /postgres1.yml
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENV PATH="/opt/patroni-venv/bin:${PATH}"

# Стартуем root-ом только чтобы выставить владельца тома.
# Дальше entrypoint делает gosu postgres и запускает Patroni.
# В методичке сразу USER postgres, но именованный volume Docker
# создаёт от root, и Patroni не может создать data_dir.
ENTRYPOINT ["/entrypoint.sh"]
