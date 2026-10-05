# NaiveProxy: Caddy + sing-box

Свой прокси на базе NaiveProxy. Снаружи сервер выглядит как обычный HTTPS-сайт, а CONNECT-запросы с правильной авторизацией уходят в прокси.

> В примерах используются плейсхолдеры: `proxy.example.com`, `admin@example.com`, `PROXY_LOGIN`, `PROXY_PASSWORD`. Реальные значения в репозиторий не коммитить.

## Как это устроено

```
Клиент (naive) ──HTTPS/H2──> Caddy :443 ──h2c──> sing-box 127.0.0.1:1080 ──> интернет
                               │
                               └── всё остальное ──> статический сайт /var/www/html
```

- **Caddy** терминирует TLS и сам получает сертификат Let's Encrypt. Для наблюдателя это обычный сайт с настоящим сертификатом.
- **sing-box** (inbound `naive`) реализует серверную часть протокола и проверяет логин и пароль. Слушает только `127.0.0.1`.
- **Матчер по `Proxy-Authorization` в Caddy** защищает от active probing. Запрос без правильного заголовка не получает `407` (по нему сканер понял бы, что это прокси), а получает страницу-заглушку. Саму проверку логина всё равно делает sing-box, Caddy только отсекает чужих.

## Требования

- VPS с Debian/Ubuntu (amd64 или arm64), доступ под root или через `sudo`
- Домен с A-записью на IP сервера
- Открытый порт `443/tcp`. Порт 80 не нужен: сертификат выпускается через TLS-ALPN на 443 (`disable_http_challenge`)

## Установка

Скопируйте `install.sh` на сервер и запустите:

```bash
scp install.sh user@SERVER_IP:
ssh user@SERVER_IP
sudo ./install.sh proxy.example.com admin@example.com
```

Свои логин и пароль можно задать переменными, иначе они генерируются (буквы и цифры, чтобы не думать про URL-кодирование):

```bash
sudo PROXY_LOGIN=mylogin PROXY_PASSWORD=mypass ./install.sh proxy.example.com admin@example.com
```

В конце скрипт печатает логин, пароль и готовый ключ для клиента. **Сохраните их сразу**, повторно скрипт их не покажет.

### Что делает скрипт

1. Ставит `openssl`, `curl`, `gnupg`, `dnsutils`.
2. Сверяет A-запись домена (через `nslookup` к `1.1.1.1`) с внешним IP сервера. При несовпадении только предупреждает.
3. Ставит Caddy из официального репозитория и sing-box из GitHub-релиза.
4. Создаёт системного пользователя `sing-box` без shell и каталоги для логов.
5. Пишет `/etc/sing-box/config.json`, unit `sing-box.service`, `/etc/caddy/Caddyfile` и заглушку `/var/www/html/index.html`.
6. Открывает 443/tcp в `ufw`, если он активен.
7. Включает и перезапускает сервисы.

Скрипт идемпотентен в части установки: уже стоящие бинарники и существующая заглушка не трогаются. Но **повторный запуск заменяет логин и пароль** на новые (если не передать свои), так что ключи на клиентах придётся обновить.

## Клиентский ключ

```
naive+https://PROXY_LOGIN:PROXY_PASSWORD@proxy.example.com:443
```

Если задаёте пароль сами и в нём есть `@ : / # %`, URL-кодируйте их в ключе.

## Проверка

Первый запрос может занять несколько секунд: Caddy выпускает сертификат при первом обращении.

```bash
curl -v -x https://PROXY_LOGIN:PROXY_PASSWORD@proxy.example.com:443 https://ifconfig.me
```

Должен вернуться IP сервера.

```bash
sudo systemctl status sing-box caddy
sudo tail -f /var/log/caddy/access.log        # CONNECT со status 200 = прокси работает
sudo tail -f /var/log/sing-box/sing-box.log
```

Проверка маскировки: `curl -i https://proxy.example.com` отдаёт заглушку, а CONNECT без авторизации не должен возвращать `407`.

## Где что лежит

| Путь | Назначение |
|---|---|
| `/etc/sing-box/config.json` | Конфиг sing-box, **содержит логин и пароль** (права `640`) |
| `/etc/caddy/Caddyfile` | Конфиг Caddy, **содержит base64 от `логин:пароль`** (права `640`) |
| `/etc/systemd/system/sing-box.service` | Unit sing-box |
| `/var/www/html/` | Сайт-заглушка |
| `/var/log/caddy/access.log` | Access-лог Caddy (ротация: 100 МБ, 7 файлов, 7 суток) |
| `/var/log/sing-box/sing-box.log` | Лог sing-box |

Логин и пароль хранятся в файлах напрямую. sing-box не подставляет переменные окружения в JSON, поэтому схема с `${PROXY_LOGIN}` и `EnvironmentFile` не работает: сервис стартует, но принимает только буквальный логин `${PROXY_LOGIN}`.

## Смена пароля

Логин и пароль лежат в **двух** местах, менять нужно оба, иначе будет `407` или статика вместо прокси. Самый простой способ: заново запустить `install.sh`, он перепишет оба файла сам.

Вручную:

```bash
NEWPASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)
echo "$NEWPASS"
echo -n "PROXY_LOGIN:$NEWPASS" | base64 -w0
```

1. Новый пароль в `/etc/sing-box/config.json`, затем `sudo systemctl restart sing-box`.
2. Новая base64-строка в `/etc/caddy/Caddyfile`, затем `sudo systemctl reload caddy`.
3. Обновить ключ на клиентах.

Забыли пароль: он лежит в `/etc/sing-box/config.json` (`sudo cat`).

## Диагностика

| Симптом | Причина |
|---|---|
| `407` в access.log, `authorization failed` в логе sing-box | Логин и пароль в sing-box не совпадают с клиентом |
| Вместо прокси отдаётся заглушка | Base64 в Caddyfile не совпадает с логином и паролем клиента, либо схема не `Basic` (с большой буквы) |
| Caddy не стартует | Нет прав на `/var/log/caddy` (`chown -R caddy:caddy`) или ошибка синтаксиса (`caddy validate --config /etc/caddy/Caddyfile`) |
| Нет сертификата | Не открыт 443, A-запись не указывает на сервер, либо есть AAAA-запись на другой сервер. Смотреть `journalctl -u caddy -n 50` |
| `authorization failed` с одним и тем же портом `127.0.0.1:xxxxx` | Это одно h2c-соединение от Caddy, а не атака |

Проверить AAAA: `nslookup -type=AAAA proxy.example.com 1.1.1.1`. Let's Encrypt предпочитает IPv6, и «лишняя» AAAA-запись ломает выпуск сертификата.

## Безопасность

- Не вставлять в чаты, тикеты и репозитории `Caddyfile`, `config.json` и вывод `history` без вычистки. Base64 из Caddyfile декодируется в `логин:пароль` одной командой.
- Если пароль попал в `history` или в чужие руки, смените его и почистите историю: `history -c && history -w`, затем удалите лишние строки из `~/.bash_history`.
- sing-box должен слушать только `127.0.0.1`. Если поменять `listen` на `0.0.0.0`, в обход Caddy появится открытый прокси, защищённый только паролем.