#!/usr/bin/env bash
set -u

# ЗАГРУЗКА ПЕРЕМЕННЫХ ИЗ .env

ENV_PATH="$(dirname "$0")/.env"

if [[ ! -f "$ENV_PATH" ]]; then
    echo "[ERROR] Файл переменных окружения .env не найден: $ENV_PATH"
    exit 1
fi

# Загружаем переменные
set -o allexport
source "$ENV_PATH"
set +o allexport

# НАСТРОЙКИ (значения берём из .env, при отсутствии - дефолт)

# Где временно храним дампы
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/tmp/pg_backups}"

# Куда складываем готовые архивы (считаем, что это отдельный диск)
BACKUP_TARGET_DIR="${BACKUP_TARGET_DIR:-/backups}"

# Лог-файл
LOG_FILE="${LOG_FILE:-/var/log/pg_backup.log}"

# Настройки PostgreSQL
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"

# Ротация: сколько последних бэкапов хранить
BACKUP_KEEP="${BACKUP_KEEP:-5}"

# Исключаемые БД
PGDATABASE_EXCLUDE=("postgres" "template0" "template1")

# Глобальные переменные (служебные)
TMP_DIR=""
ARCHIVE_PATH=""
DB_LIST=()

# ЛОГИРОВАНИЕ

log_info() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [INFO]  $msg" | tee -a "$LOG_FILE"
}

log_error() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [ERROR] $msg" | tee -a "$LOG_FILE" >&2
}

fail() {
    local msg="$1"
    log_error "$msg"
    exit 1
}

# ОЧИСТКА ВРЕМЕННЫХ ФАЙЛОВ

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
        log_info "Временный каталог $TMP_DIR удален"
    fi
}

trap cleanup EXIT INT TERM

# ПРОВЕРКИ

check_requirements() {
    local bins=("psql" "pg_dump" "tar" "gzip")

    for b in "${bins[@]}"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            fail "Не найден бинарник '$b' в PATH"
        fi
    done

    if [[ ! -d "$BACKUP_TARGET_DIR" ]]; then
        fail "Каталог для бэкапов $BACKUP_TARGET_DIR не существует"
    fi

    log_info "Проверка окружения пройдена"
}

# ИНИЦИАЛИЗАЦИЯ

init_backup() {
    TMP_DIR="$(mktemp -d "${BACKUP_BASE_DIR}/pg_backup_XXXXXX")" \
        || fail "Не удалось создать временный каталог"

    log_info "Временный каталог создан: $TMP_DIR"

    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    ARCHIVE_PATH="${TMP_DIR}/pg_backup_${ts}.tar.gz"
}

# ПОЛУЧЕНИЕ СПИСКА БАЗ

get_databases() {
    log_info "Получаем список баз данных"

    local raw_dbs
    raw_dbs=$(PGUSER="$PGUSER" PGHOST="$PGHOST" PGPORT="$PGPORT" \
        psql -At -d postgres -c "SELECT datname FROM pg_database WHERE datistemplate = false;" \
    ) || fail "Ошибка получения списка баз"

    local db
    for db in $raw_dbs; do
        local skip=0
        for ex in "${PGDATABASE_EXCLUDE[@]}"; do
            [[ "$db" == "$ex" ]] && skip=1
        done
        [[ $skip -eq 1 ]] && continue
        DB_LIST+=("$db")
    done

    if [[ ${#DB_LIST[@]} -eq 0 ]]; then
        fail "Нет баз данных для бэкапа"
    fi

    log_info "Баз для бэкапа: ${#DB_LIST[@]}"
}

# СОЗДАНИЕ ДАМПОВ

dump_database() {
    local db_name="$1"
    local dump_file="${TMP_DIR}/${db_name}.sql"

    log_info "Создаём дамп базы '${db_name}'"

    if ! PGUSER="$PGUSER" PGHOST="$PGHOST" PGPORT="$PGPORT" \
        pg_dump "$db_name" -f "$dump_file" >/dev/null 2>&1; then
        log_error "Ошибка дампа базы '${db_name}'"
        return 1
    fi

    log_info "Дамп базы '${db_name}' создан"
}

dump_all_databases() {
    log_info "Создаем дампы всех баз"

    local db
    for db in "${DB_LIST[@]}"; do
        if ! dump_database "$db"; then
            fail "Ошибка: дамп базы '$db' не создан, процесс остановлен"
        fi
    done

    log_info "Все дампы созданы успешно"
}


# АРХИВИРОВАНИЕ И ПРОВЕРКА

create_archive() {
    log_info "Создаём архив: $ARCHIVE_PATH"

    (cd "$TMP_DIR" && tar -czf "$ARCHIVE_PATH" ./*.sql) \
        || fail "Ошибка создания архива"

    log_info "Архив успешно создан"

    # truncate -s 50 "$ARCHIVE_PATH"
}

test_archive() {
    log_info "Тестируем архив"

    if ! tar -tzf "$ARCHIVE_PATH" >/dev/null 2>&1; then
        fail "Архив поврежден"
    fi

    log_info "Архив прошёл проверку"
}

# ПЕРЕНОС ГОТОВОГО АРХИВА

move_archive() {
    log_info "Переносим архив в $BACKUP_TARGET_DIR"

    local filename
    filename="$(basename "$ARCHIVE_PATH")"

    if ! mv "$ARCHIVE_PATH" "${BACKUP_TARGET_DIR}/${filename}"; then
        fail "Не удалось переместить архив"
    fi

    log_info "Архив перемещён в ${BACKUP_TARGET_DIR}/${filename}"
}

# РОТАЦИЯ БЕКАПОВ

rotate_backups() {
    local keep="${BACKUP_KEEP:-5}"
    local pattern="pg_backup_*.tar.gz"

    log_info "Запускаем ротацию бэкапов (хранить только ${keep})"

    mapfile -t files < <(
        find "$BACKUP_TARGET_DIR" -maxdepth 1 -type f -name "$pattern" -printf "%T@ %p\n" \
        | sort -nr \
        | awk '{print $2}'
    )

    local total=${#files[@]}

    if (( total <= keep )); then
        log_info "Ротация не требуется: бэкапов всего ${total}"
        return 0
    fi

    for ((i = keep; i < total; i++)); do
        local old_file="${files[$i]}"
        if rm -f "$old_file"; then
            log_info "Удалён старый архив: $(basename "$old_file")"
        else
            log_error "Ошибка удаления старого бэкапа: $(basename "$old_file")"
        fi
    done
}

# MAIN

main() {
    log_info "Запуск скрипта резервного копирования PostgreSQL"

    check_requirements
    init_backup
    get_databases
    dump_all_databases
    create_archive
    test_archive
    move_archive

    rotate_backups

    log_info "Бэкап успешно завершён"
}

main "$@"
