# Деплой «Кулинарного трекера» в облако

Архитектура: **Render** (бэкенд, free) + **Turso** (БД, free) + **GitHub Pages** (фронт).
Сайт работает при выключенном ПК. Первый заход после простоя до ~1 минуты — это
Render free «просыпается» после 15 минут без трафика.

## 0. Предварительно

- Аккаунт GitHub с этим репозиторием.
- Аккаунт Render (регистрация через GitHub) — https://render.com
- Аккаунт Turso — https://turso.tech (регистрация через GitHub, карта не нужна).
- Turso CLI (для Windows — в WSL или Git Bash):

  ```bash
  curl -sSfL https://get.tur.so/install.sh | bash
  turso auth signup
  ```

## 1. Создать БД в Turso

```bash
turso db create kulinar
turso db show kulinar --url          # -> libsql://kulinar-<...>.turso.io
turso db tokens create kulinar       # -> токен доступа
```

Сохраните оба значения: это будущие `DATABASE_URL` и `TURSO_AUTH_TOKEN`.

## 2. Задеплоить бэкенд на Render

1. Render Dashboard -> **New** -> **Blueprint** -> выбрать этот репозиторий.
   Render прочитает `render.yaml` и создаст сервис `kulinar-backend`
   (rootDir `backend`, health check `/api/health`).
2. В окне создания/в настройках сервиса задать **Environment** (sync: false
   означает, что значения вводятся в дашборде, а не в файле):

   | Переменная        | Значение                                                     |
   |-------------------|--------------------------------------------------------------|
   | `ADMIN_PASSWORD`  | пароль админа (например, `admin123` для теста)               |
   | `ALLOWED_ORIGIN`  | `https://<username>.github.io,http://localhost:5500,http://127.0.0.1:5500` |
   | `DATABASE_URL`    | `libsql://...` из шага 1                                     |
   | `TURSO_AUTH_TOKEN`| токен из шага 1                                              |

   Локальные origins можно оставить — они нужны только для тестов на вашем ПК.

   Альтернатива без Blueprint: **New** -> **Web Service** -> репозиторий ->
   Root Directory `backend`, Build Command `pip install -r requirements.txt`,
   Start Command `uvicorn app:app --host 0.0.0.0 --port $PORT`, Instance Type
   `Free`, те же 4 переменные окружения.

3. Дождаться деплоя и проверить:

   ```bash
   curl https://<имя-сервиса>.onrender.com/api/health
   # {"status":"ok"}
   ```

   При первом старте бэкенд создаст таблицы в Turso и зальёт «Супы: Борщ,
   Харчо, Гаспачо».

## 3. Обновить фронтенд

В `docs/index.html` заменить адрес бэкенда на свой:

```js
const BACKEND_URL = "https://<имя-сервиса>.onrender.com";
```

## 4. Включить GitHub Pages

1. Запушить `docs/index.html` в репозиторий.
2. Repository -> Settings -> Pages -> Source: `Deploy from a branch`,
   Branch: `main`, папка `/docs`. Сохранить.
3. Через пару минут сайт откроется по адресу
   `https://<username>.github.io/<repo>/`.

## 5. Проверка

Прогнать smoke-тест по облачному адресу:

```bash
cd backend
bash smoke_test.sh https://<имя-сервиса>.onrender.com
```

Ручные проверки в браузере — по чек-листу из `tz.txt` (п.12): вход админа,
добавление/переименование/удаление, режим гостя, мобильная вёрстка.

## Обновление кода

`git push` в `main` — Render передеплоит сервис автоматически.
Фронт на GitHub Pages обновится сам после пуша (кэш браузера может
задержать на пару минут).

## Полезное

- Логи Render: Dashboard -> сервис -> Logs.
- Если сайт показывает «Не удалось подключиться к серверу»: подождать минуту
  (cold start), проверить `/api/health` и что origin сайта указан
  в `ALLOWED_ORIGIN` (протокол и домен должны совпадать точно).
- Локальная разработка без облака:

  ```bash
  cd backend
  DATABASE_URL="file:local.db" ALLOWED_ORIGIN="http://localhost:5500,http://127.0.0.1:5500" \
      uvicorn app:app --host 127.0.0.1 --port 8000
  ```

  `local.db` создастся рядом с `app.py` и не попадёт в git (см. `.gitignore`).

  Фронт для локального теста: `python -m http.server 5500` в каталоге `docs`,
  открыть `http://localhost:5500`.

