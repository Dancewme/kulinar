#!/usr/bin/env bash
# Smoke-тест API «Кулинарного трекера» (curl, без pytest).
#
# Использование:
#   ./smoke_test.sh [base_url]
#   ./smoke_test.sh http://127.0.0.1:8000              # локальный uvicorn
#   ./smoke_test.sh https://<имя-сервиса>.onrender.com # Render
# По умолчанию base_url = http://127.0.0.1:8000
#
# Требует запущенный бэкенд. Созданные в ходе теста данные удаляются в конце.
#
# ВАЖНО: тела запросов передаются через файл (--data-binary @file), а не через
# inline -d: curl.exe из Git Bash искажает кириллицу в аргументах командной
# строки, и сервер получает битый JSON.
#
# Секция «Начальное заполнение» рассчитана на БД с исходными данными
# (свежая база после первого старта). Критерии «пустая БД -> заполнение»
# и «повторный старт не пересоздаёт данные» проверяются отдельным сценарием
# с перезапуском бэкенда, а «старый токен после перезапуска» — вручную
# (локально: rm local.db и перезапуск; Turso: перезапуск сервиса на Render).

set -u

BASE_URL="${1:-http://127.0.0.1:8000}"
PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BODY_FILE="$TMP_DIR/response.json"
REQ_FILE="$TMP_DIR/request.json"
HTTP_CODE=""
BODY=""

# Возвращает путь к файлу в формате, понятном curl.exe из Git Bash.
to_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

request() {
  local method="$1" path="$2" data="${3:-}" auth="${4:-}"
  local args=(-s -o "$BODY_FILE" -w "%{http_code}" -X "$method" "$BASE_URL$path")
  if [ -n "$data" ]; then
    printf '%s' "$data" > "$REQ_FILE"
    args+=(-H "Content-Type: application/json"
           --data-binary "@$(to_path "$REQ_FILE")")
  fi
  if [ -n "$auth" ]; then
    args+=(-H "Authorization: Bearer $auth")
  fi
  HTTP_CODE="$(curl "${args[@]}")"
  BODY="$(cat "$BODY_FILE")"
}

pass() { PASS=$((PASS + 1)); echo "  OK   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

expect_code() { # <описание> <ожидаемый код>
  if [ "$HTTP_CODE" = "$2" ]; then
    pass "$1"
  else
    fail "$1 (ожидался $2, получен $HTTP_CODE; тело: $BODY)"
  fi
}

expect_contains() { # <описание> <подстрока>
  if printf '%s' "$BODY" | grep -qF -- "$2"; then
    pass "$1"
  else
    fail "$1 (нет «$2» в теле: $BODY)"
  fi
}

extract_id() { # первое "id":N из тела
  printf '%s' "$BODY" | sed -E 's/.*"id":([0-9]+).*/\1/'
}

section() { echo; echo "== $1 =="; }

echo "Smoke-тест API: $BASE_URL"

# --- 1. Health --------------------------------------------------------------
section "Health"
request GET /api/health
expect_code "GET /api/health -> 200" 200
expect_contains "ответ содержит status: ok" '"status":"ok"'

# --- 2. Начальные данные ----------------------------------------------------
section "Начальное заполнение"
request GET /api/menu
expect_code "GET /api/menu -> 200" 200
expect_contains "есть категория «Супы»" '"name":"Супы"'
expect_contains "есть «Борщ»" '"name":"Борщ"'
expect_contains "есть «Харчо»" '"name":"Харчо"'
expect_contains "есть «Гаспачо»" '"name":"Гаспачо"'

# --- 3. Авторизация ---------------------------------------------------------
section "Авторизация"
request POST /api/login '{"password":"wrong-password"}'
expect_code "неверный пароль -> 401" 401
expect_contains "ошибка Invalid password" '"error":"Invalid password"'

request POST /api/login '{"password":"admin123"}'
expect_code "верный пароль -> 200" 200
TOKEN="$(printf '%s' "$BODY" | sed -E 's/.*"token":"([^"]+)".*/\1/')"
if [ -n "$TOKEN" ] && [ "$TOKEN" != "$BODY" ]; then
  pass "получен токен"
else
  fail "токен не получен (тело: $BODY)"
  TOKEN=""
fi

request POST /api/categories '{"name":"Без токена"}' ""
expect_code "POST без токена -> 401" 401
expect_contains "ошибка Unauthorized" '"error":"Unauthorized"'

request DELETE /api/categories/1 "" "not-a-real-token"
expect_code "DELETE с неверным токеном -> 401" 401

# --- 4. Категории -----------------------------------------------------------
section "Категории (CRUD)"
request POST /api/categories '{"name":"Салаты"}' "$TOKEN"
expect_code "создание категории -> 200" 200
CAT_ID="$(extract_id)"
expect_contains "имя в ответе" '"name":"Салаты"'

request POST /api/categories '{"name":"Салаты"}' "$TOKEN"
expect_code "дубликат категории -> 409" 409
expect_contains "ошибка Category already exists" '"error":"Category already exists"'

request POST /api/categories '{"name":"   "}' "$TOKEN"
expect_code "пустое имя -> 400" 400
expect_contains "ошибка Name is required" '"error":"Name is required"'

LONG_NAME="$(printf 'a%.0s' $(seq 1 101))"
request POST /api/categories "{\"name\":\"$LONG_NAME\"}" "$TOKEN"
expect_code "имя 101 символ -> 400" 400
expect_contains "ошибка Name too long" '"error":"Name too long"'

request POST /api/categories '{}' "$TOKEN"
expect_code "тело без name -> 400 (не 422)" 400

request PUT "/api/categories/$CAT_ID" '{"name":"Салаты и закуски"}' "$TOKEN"
expect_code "переименование -> 200" 200
expect_contains "новое имя в ответе" '"name":"Салаты и закуски"'

request PUT "/api/categories/$CAT_ID" '{"name":"Салаты и закуски"}' "$TOKEN"
expect_code "PUT с тем же именем (сам в себя) -> 200" 200

request PUT "/api/categories/$CAT_ID" '{"name":"Супы"}' "$TOKEN"
expect_code "PUT в имя другой категории -> 409" 409

request PUT /api/categories/999999 '{"name":"Нет такой"}' "$TOKEN"
expect_code "PUT несуществующей категории -> 404" 404

request POST /api/categories '{"name":"Вторые блюда"}' "$TOKEN"
CAT2_ID="$(extract_id)"

request GET /api/menu
LAST_ID="$(printf '%s' "$BODY" | grep -o '"id":[0-9]*' | tail -1 | sed -E 's/"id":([0-9]+)/\1/')"
if [ "$LAST_ID" = "$CAT2_ID" ]; then
  pass "новая категория в конце списка (id $CAT2_ID)"
else
  fail "новая категория не в конце списка (последний id: $LAST_ID, ожидался $CAT2_ID)"
fi

# --- 5. Блюда ---------------------------------------------------------------
section "Блюда (CRUD)"
request POST /api/dishes "{\"category_id\":$CAT_ID,\"name\":\"Оливье\"}" "$TOKEN"
expect_code "создание блюда -> 200" 200
DISH_ID="$(extract_id)"
expect_contains "имя в ответе" '"name":"Оливье"'

request POST /api/dishes "{\"category_id\":$CAT_ID,\"name\":\"Оливье\"}" "$TOKEN"
expect_code "дубликат блюда разрешён -> 200" 200
DISH_DUP_ID="$(extract_id)"

request POST /api/dishes '{"category_id":999999,"name":"Сирота"}' "$TOKEN"
expect_code "блюдо в несуществующую категорию -> 404" 404

request POST /api/dishes "{\"category_id\":$CAT_ID,\"name\":\"  \"}" "$TOKEN"
expect_code "пустое имя блюда -> 400" 400

request POST /api/dishes "{\"category_id\":$CAT_ID,\"name\":\"$LONG_NAME\"}" "$TOKEN"
expect_code "имя блюда 101 символ -> 400" 400

request POST /api/dishes "{\"category_id\":\"abc\",\"name\":\"Кривой\"}" "$TOKEN"
expect_code "неверный тип category_id -> 400 (не 422)" 400

request GET /api/menu
FIRST_DISH_ID="$(printf '%s' "$BODY" | grep -o '"id":[0-9]*,"name":"Оливье"' | head -1 | sed -E 's/"id":([0-9]+).*/\1/')"
LAST_DISH_ID="$(printf '%s' "$BODY" | grep -o '"id":[0-9]*,"name":"Оливье"' | tail -1 | sed -E 's/"id":([0-9]+).*/\1/')"
if [ "$FIRST_DISH_ID" = "$DISH_ID" ] && [ "$LAST_DISH_ID" = "$DISH_DUP_ID" ]; then
  pass "блюда в порядке добавления (id $DISH_ID, затем $DISH_DUP_ID)"
else
  fail "порядок блюд неверный (первый: $FIRST_DISH_ID, последний: $LAST_DISH_ID)"
fi

request PUT "/api/dishes/$DISH_ID" '{"name":"Оливье по-новому"}' "$TOKEN"
expect_code "переименование блюда -> 200" 200
expect_contains "новое имя в ответе" '"name":"Оливье по-новому"'

request PUT /api/dishes/999999 '{"name":"Нет такого"}' "$TOKEN"
expect_code "PUT несуществующего блюда -> 404" 404

# --- 6. Удаление и каскад ---------------------------------------------------
section "Удаление и каскад"
request DELETE "/api/dishes/$DISH_DUP_ID" "" "$TOKEN"
expect_code "DELETE блюда -> 200" 200
expect_contains "ответ ok" '"ok":true'

request DELETE "/api/dishes/$DISH_DUP_ID" "" "$TOKEN"
expect_code "повторный DELETE блюда -> 404" 404

request DELETE "/api/categories/$CAT_ID" "" "$TOKEN"
expect_code "DELETE категории -> 200" 200

request DELETE "/api/dishes/$DISH_ID" "" "$TOKEN"
expect_code "блюдо удалено каскадом (404)" 404

request GET /api/menu
if printf '%s' "$BODY" | grep -qF '"Салаты и закуски"'; then
  fail "удалённая категория всё ещё в меню"
else
  pass "удалённая категория отсутствует в меню"
fi

request DELETE /api/categories/999999 "" "$TOKEN"
expect_code "DELETE несуществующей категории -> 404" 404

# --- 7. Пароль не утекает во фронтенд --------------------------------------
# Фронт лежит в docs/index.html (GitHub Pages раздаёт эту папку);
# старый путь frontend/ поддержан как fallback.
section "Пароль во фронтенде"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRONTEND=""
for candidate in "$SCRIPT_DIR/../docs/index.html" "$SCRIPT_DIR/../frontend/index.html"; do
  if [ -f "$candidate" ]; then
    FRONTEND="$candidate"
    break
  fi
done
if [ -n "$FRONTEND" ]; then
  if grep -qF "admin123" "$FRONTEND"; then
    fail "пароль admin123 найден в $FRONTEND"
  else
    pass "пароля нет в $FRONTEND"
  fi
else
  fail "index.html не найден ни в docs/, ни в frontend/"
fi

# --- Cleanup ----------------------------------------------------------------
request DELETE "/api/categories/$CAT2_ID" "" "$TOKEN"

# --- Итог -------------------------------------------------------------------
echo
echo "==============================="
echo "Пройдено: $PASS, провалено: $FAIL"
echo "==============================="
[ "$FAIL" -eq 0 ]