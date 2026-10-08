"""Бэкенд «Кулинарного трекера»: FastAPI + Turso (libSQL).

Локальный запуск:
    DATABASE_URL="file:local.db" \
    ALLOWED_ORIGIN="http://localhost:5500,http://127.0.0.1:5500" \
        uvicorn app:app --host 127.0.0.1 --port 8000

Запуск на Render (см. render.yaml):
    uvicorn app:app --host 0.0.0.0 --port $PORT

Переменные окружения:
    DATABASE_URL     — адрес БД: libsql://... (Turso) или file:local.db (локально). Обязательна.
    TURSO_AUTH_TOKEN — токен доступа к Turso (для file: не нужен).
    ALLOWED_ORIGIN   — список разрешённых origin через запятую. Обязательна.
    ADMIN_PASSWORD   — пароль администратора (по умолчанию "admin123").

Эндпоинты объявлены синхронными (def): FastAPI выполняет их в threadpool,
поэтому блокирующие вызовы libsql не блокируют event loop.
"""

import os
import secrets
import time
from collections.abc import Iterator
from contextlib import asynccontextmanager, contextmanager

import libsql
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.exceptions import HTTPException as StarletteHTTPException

# --- Конфигурация -----------------------------------------------------------

DATABASE_URL = os.environ.get("DATABASE_URL", "")
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL is not set")

TURSO_AUTH_TOKEN = os.environ.get("TURSO_AUTH_TOKEN", "")

ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "admin123")

_allowed_origin = os.environ.get("ALLOWED_ORIGIN", "")
ALLOWED_ORIGINS = [origin.strip() for origin in _allowed_origin.split(",") if origin.strip()]
if not ALLOWED_ORIGINS:
    raise RuntimeError("ALLOWED_ORIGIN is not set")
if "*" in ALLOWED_ORIGINS:
    raise RuntimeError('ALLOWED_ORIGIN must not contain "*"')

MAX_NAME_LENGTH = 100


# --- Работа с БД ------------------------------------------------------------

@contextmanager
def db() -> Iterator[libsql.Connection]:
    """Новое соединение на каждый запрос.

    У libSQL PRAGMA действует только в рамках соединения, поэтому
    foreign_keys включается сразу после подключения. Соединение не покидает
    поток, в котором создано, — это безопасно при работе из threadpool FastAPI.
    """
    conn = libsql.connect(DATABASE_URL, auth_token=TURSO_AUTH_TOKEN)
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db() -> None:
    """Создаёт таблицы, очищает сессии и однократно заполняет данные."""
    with db() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS dishes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                category_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS tokens (
                token TEXT PRIMARY KEY,
                created_at INTEGER NOT NULL
            )
            """
        )

        # Токены живут в рамках одного запуска процесса: после перезапуска
        # (в том числе пробуждения free-сервиса Render) старые сессии мертвы.
        conn.execute("DELETE FROM tokens")

        initialized = conn.execute(
            "SELECT 1 FROM meta WHERE key = 'initialized'"
        ).fetchone()
        if initialized is None:
            category_id = conn.execute(
                "INSERT INTO categories (name) VALUES (?) RETURNING id", ("Супы",)
            ).fetchone()[0]
            for dish_name in ("Борщ", "Харчо", "Гаспачо"):
                conn.execute(
                    "INSERT INTO dishes (category_id, name) VALUES (?, ?)",
                    (category_id, dish_name),
                )
            conn.execute("INSERT INTO meta (key, value) VALUES ('initialized', '1')")


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield


app = FastAPI(lifespan=lifespan)


# --- Единый формат ошибок: {"error": "..."} ---------------------------------

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(status_code=400, content={"error": "Invalid request body"})


@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    return JSONResponse(status_code=exc.status_code, content={"error": exc.detail})


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    return JSONResponse(status_code=500, content={"error": "Internal server error"})


app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization"],
)


# --- Модели тел запросов ----------------------------------------------------

class LoginBody(BaseModel):
    password: str


class NameBody(BaseModel):
    name: str


class DishCreateBody(BaseModel):
    category_id: int
    name: str


# --- Вспомогательные функции ------------------------------------------------

def clean_name(raw: str) -> str:
    name = raw.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Name is required")
    if len(name) > MAX_NAME_LENGTH:
        raise HTTPException(status_code=400, detail="Name too long")
    return name


def is_unique_violation(error: ValueError) -> bool:
    return "UNIQUE constraint failed" in str(error)


def require_admin(authorization: str | None = Header(default=None)) -> None:
    token = authorization.removeprefix("Bearer ").strip() if authorization else ""
    if not token:
        raise HTTPException(status_code=401, detail="Unauthorized")
    with db() as conn:
        row = conn.execute(
            "SELECT 1 FROM tokens WHERE token = ?", (token,)
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=401, detail="Unauthorized")


# --- API --------------------------------------------------------------------

@app.get("/api/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/api/menu")
def get_menu() -> dict:
    with db() as conn:
        categories = conn.execute(
            "SELECT id, name FROM categories ORDER BY id ASC"
        ).fetchall()
        dishes = conn.execute(
            "SELECT id, category_id, name FROM dishes ORDER BY id ASC"
        ).fetchall()

    dishes_by_category: dict[int, list[dict]] = {}
    for dish in dishes:
        dishes_by_category.setdefault(dish[1], []).append(
            {"id": dish[0], "name": dish[2]}
        )

    return {
        "categories": [
            {
                "id": category[0],
                "name": category[1],
                "dishes": dishes_by_category.get(category[0], []),
            }
            for category in categories
        ]
    }


@app.post("/api/login")
def login(body: LoginBody) -> dict:
    if not secrets.compare_digest(
        body.password.encode("utf-8"), ADMIN_PASSWORD.encode("utf-8")
    ):
        raise HTTPException(status_code=401, detail="Invalid password")
    token = secrets.token_urlsafe(32)
    with db() as conn:
        conn.execute(
            "INSERT INTO tokens (token, created_at) VALUES (?, ?)",
            (token, int(time.time())),
        )
    return {"token": token}


@app.post("/api/categories", dependencies=[Depends(require_admin)])
def create_category(body: NameBody) -> dict:
    name = clean_name(body.name)
    with db() as conn:
        try:
            row = conn.execute(
                "INSERT INTO categories (name) VALUES (?) RETURNING id", (name,)
            ).fetchone()
        except ValueError as error:
            if is_unique_violation(error):
                raise HTTPException(status_code=409, detail="Category already exists")
            raise
    return {"id": row[0], "name": name}


@app.put("/api/categories/{category_id}", dependencies=[Depends(require_admin)])
def update_category(category_id: int, body: NameBody) -> dict:
    name = clean_name(body.name)
    with db() as conn:
        try:
            row = conn.execute(
                "UPDATE categories SET name = ? WHERE id = ? RETURNING id",
                (name, category_id),
            ).fetchone()
        except ValueError as error:
            if is_unique_violation(error):
                raise HTTPException(status_code=409, detail="Category already exists")
            raise
        if row is None:
            raise HTTPException(status_code=404, detail="Not found")
    return {"id": category_id, "name": name}


@app.delete("/api/categories/{category_id}", dependencies=[Depends(require_admin)])
def delete_category(category_id: int) -> dict:
    with db() as conn:
        row = conn.execute(
            "DELETE FROM categories WHERE id = ? RETURNING id", (category_id,)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Not found")
        # Страховка на случай, если PRAGMA foreign_keys окажется неактивна.
        conn.execute("DELETE FROM dishes WHERE category_id = ?", (category_id,))
    return {"ok": True}


@app.post("/api/dishes", dependencies=[Depends(require_admin)])
def create_dish(body: DishCreateBody) -> dict:
    name = clean_name(body.name)
    with db() as conn:
        category = conn.execute(
            "SELECT 1 FROM categories WHERE id = ?", (body.category_id,)
        ).fetchone()
        if category is None:
            raise HTTPException(status_code=404, detail="Not found")
        row = conn.execute(
            "INSERT INTO dishes (category_id, name) VALUES (?, ?) RETURNING id",
            (body.category_id, name),
        ).fetchone()
    return {"id": row[0], "name": name}


@app.put("/api/dishes/{dish_id}", dependencies=[Depends(require_admin)])
def update_dish(dish_id: int, body: NameBody) -> dict:
    name = clean_name(body.name)
    with db() as conn:
        row = conn.execute(
            "UPDATE dishes SET name = ? WHERE id = ? RETURNING id", (name, dish_id)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Not found")
    return {"id": dish_id, "name": name}


@app.delete("/api/dishes/{dish_id}", dependencies=[Depends(require_admin)])
def delete_dish(dish_id: int) -> dict:
    with db() as conn:
        row = conn.execute(
            "DELETE FROM dishes WHERE id = ? RETURNING id", (dish_id,)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Not found")
    return {"ok": True}