# ЛР 2. Loki + Zabbix + Grafana

Стенд подключает к Nextcloud сбор логов через Promtail и Loki, проверку состояния через Zabbix и два дашборда Grafana.

## Состав

| Сервис | Адрес с хоста | Назначение |
| --- | --- | --- |
| Nextcloud | [http://localhost:8080](http://localhost:8080) | Тестовое приложение |
| Loki | [http://localhost:3100/ready](http://localhost:3100/ready) | Хранение логов |
| Grafana | [http://localhost:3000](http://localhost:3000) | Визуализация |
| Zabbix | [http://localhost:8082](http://localhost:8082) | Мониторинг |

Nextcloud: `admin` / `admin`. Grafana: `admin` / `admin`. Zabbix: `Admin` / `zabbix`.

## Запуск

```bash
docker compose up -d
docker compose ps
```

Nextcloud инициализируется автоматически. Первый запуск Zabbix и установка плагина Grafana занимают несколько минут.

## Настройка Zabbix

1. Открыть **Data collection → Templates → Import** и импортировать `zabbix-template.yml`.
2. Открыть **Data collection → Hosts → Create host**.
3. Указать имя хоста `nextcloud`, видимое имя `Nextcloud Server` и группу `Applications`.
4. Подключить шаблон `Test ping template` и сохранить хост.
5. В **Monitoring → Latest data** проверить значение `healthy` у элемента `Nextcloud: ping service`.

## Настройка Grafana

1. В **Administration → Plugins** включить плагин Zabbix.
2. Создать источник Loki с URL `http://loki:3100`.
3. Создать источник Zabbix с URL `http://zabbix-web:8080/api_jsonrpc.php` и данными `Admin` / `zabbix`.
4. Импортировать `dashboards/nextcloud-status.json` и `dashboards/nextcloud-logs.json`.

Для Loki используются запросы:

```logql
{job="nextcloud_logs"}
{job="nextcloud_logs"} |= "error"
{job="nextcloud_logs"} | json
```

## Проверка

```bash
curl -s http://localhost:8080/status.php
curl -s http://localhost:3100/loki/api/v1/labels
docker compose logs promtail
```

Остановка без удаления данных:

```bash
docker compose down
```

Полный сброс стенда:

```bash
docker compose down -v
```

Ход работы и ответы на вопросы находятся в [REPORT.md](REPORT.md).
