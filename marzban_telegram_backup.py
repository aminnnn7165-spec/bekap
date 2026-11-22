#!/usr/bin/env python3
# Marzban MySQL ZIP backup bot - Python standard library only.
# Keeps secrets/settings on the server; never commit the config file to GitHub.

import argparse
import getpass
import http.client
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit, unquote, urlencode
from urllib.request import Request, urlopen

APP_NAME = "marzban-telegram-backup"
INSTALL_DIR = Path("/opt/marzban-telegram-backup")
INSTALLED_SCRIPT = INSTALL_DIR / "marzban_telegram_backup.py"
CONFIG_FILE = Path("/var/lib/marzban-telegram-backup/config.json")
SERVICE_FILE = Path("/etc/systemd/system/marzban-telegram-backup.service")
MARZBAN_ENV = Path("/opt/marzban/.env")
PART_SIZE = 40 * 1024 * 1024  # comfortably below Telegram's standard Bot API upload ceiling
POLL_TIMEOUT = 20
ALLOWED_INTERVALS = [1, 2, 3, 4, 6, 8, 12, 24]


def log(message):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)


def read_config():
    if not CONFIG_FILE.exists():
        raise RuntimeError("تنظیمات پیدا نشد؛ ابتدا --install را اجرا کن.")
    with CONFIG_FILE.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_config(cfg):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_FILE.parent, 0o700)
    tmp = CONFIG_FILE.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(CONFIG_FILE)
    os.chmod(CONFIG_FILE, 0o600)


def telegram_api(token, method, data=None, timeout=35):
    url = f"https://api.telegram.org/bot{token}/{method}"
    body = urlencode(data or {}).encode("utf-8")
    req = Request(url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urlopen(req, timeout=timeout) as response:
            result = json.loads(response.read().decode("utf-8", "replace"))
    except Exception as exc:
        raise RuntimeError(f"خطای ارتباط با تلگرام در {method}: {exc}") from exc
    if not result.get("ok"):
        raise RuntimeError(f"Telegram {method}: {result.get('description', 'unknown error')}")
    return result.get("result")


def send_document(token, chat_id, file_path, caption):
    """Stream a document upload to Telegram without loading a 40MB part into RAM."""
    file_path = Path(file_path)
    boundary = "----MarzbanBackup" + secrets.token_hex(12)
    fields = {
        "chat_id": str(chat_id),
        "caption": caption[:900],
    }
    chunks = []
    for key, value in fields.items():
        chunks.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
            f"{value}\r\n".encode("utf-8")
        )
    filename = file_path.name.replace('"', "_").replace("\r", "_").replace("\n", "_")
    prefix = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="document"; filename="{filename}"\r\n'
        "Content-Type: application/zip\r\n\r\n"
    ).encode("utf-8")
    suffix = f"\r\n--{boundary}--\r\n".encode("ascii")
    fields_blob = b"".join(chunks) + prefix
    content_length = len(fields_blob) + file_path.stat().st_size + len(suffix)

    conn = http.client.HTTPSConnection("api.telegram.org", timeout=300)
    try:
        path = f"/bot{token}/sendDocument"
        conn.putrequest("POST", path)
        conn.putheader("Content-Type", f"multipart/form-data; boundary={boundary}")
        conn.putheader("Content-Length", str(content_length))
        conn.endheaders()
        conn.send(fields_blob)
        with file_path.open("rb") as f:
            while True:
                block = f.read(1024 * 1024)
                if not block:
                    break
                conn.send(block)
        conn.send(suffix)
        raw = conn.getresponse().read()
        result = json.loads(raw.decode("utf-8", "replace"))
    except Exception as exc:
        raise RuntimeError(f"خطا در ارسال فایل به تلگرام: {exc}") from exc
    finally:
        conn.close()
    if not result.get("ok"):
        raise RuntimeError(f"تلگرام فایل را نپذیرفت: {result.get('description', 'unknown error')}")
    return result.get("result", {})


def send_message(cfg, text, reply_markup=None, chat_id=None):
    target = chat_id if chat_id is not None else cfg.get("owner_id")
    if not target:
        return
    data = {"chat_id": str(target), "text": text, "disable_web_page_preview": "true"}
    if reply_markup is not None:
        data["reply_markup"] = json.dumps(reply_markup, ensure_ascii=False)
    telegram_api(cfg["bot_token"], "sendMessage", data)


def main_keyboard(cfg):
    schedule_label = "⏸ توقف زمان‌بندی" if cfg.get("enabled", True) else "▶️ ادامه زمان‌بندی"
    return {
        "inline_keyboard": [
            [{"text": "📦 بکاپ همین الان", "callback_data": "backup_now"}],
            [{"text": "⏱ تنظیم فاصله بکاپ", "callback_data": "interval_menu"}],
            [{"text": schedule_label, "callback_data": "toggle_schedule"}],
            [{"text": "📊 وضعیت بکاپ", "callback_data": "status"}],
            [{"text": "ℹ️ راهنما", "callback_data": "help"}],
        ]
    }


def interval_keyboard():
    rows = []
    row = []
    for hours in ALLOWED_INTERVALS:
        row.append({"text": f"هر {hours} ساعت", "callback_data": f"interval:{hours}"})
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([{"text": "⬅️ بازگشت", "callback_data": "menu"}])
    return {"inline_keyboard": rows}


def status_text(cfg):
    interval = int(cfg.get("interval_hours", 6))
    enabled = cfg.get("enabled", True)
    last = cfg.get("last_backup_at") or "هنوز بکاپ موفقی ثبت نشده"
    result = cfg.get("last_result", "نامشخص")
    next_text = "غیرفعال" if not enabled else f"حدوداً {interval} ساعت پس از آخرین تلاش"
    return (
        "📊 وضعیت بکاپ مرزبان\n\n"
        f"وضعیت زمان‌بندی: {'روشن ✅' if enabled else 'متوقف ⏸'}\n"
        f"فاصله بکاپ: هر {interval} ساعت\n"
        f"آخرین بکاپ موفق: {last}\n"
        f"نتیجه آخرین اجرا: {result}\n"
        f"زمان اجرای بعدی: {next_text}\n\n"
        "نوع بکاپ: فقط دیتابیس مرزبان، در قالب ZIP"
    )


def help_text():
    return (
        "راهنمای ربات بکاپ مرزبان\n\n"
        "📦 بکاپ همین الان: فوراً از دیتابیس بکاپ می‌گیرد و ZIP را می‌فرستد.\n"
        "⏱ تنظیم فاصله بکاپ: فاصله خودکار را انتخاب می‌کنی.\n"
        "⏸ توقف/ادامه: زمان‌بندی خودکار را خاموش یا روشن می‌کند.\n"
        "📊 وضعیت بکاپ: زمان آخرین بکاپ و تنظیمات را نشان می‌دهد.\n\n"
        "دستورها: /start /status /run /interval /pause /resume /help"
    )


def parse_dotenv_value(path, wanted_key):
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() != wanted_key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        return value
    return ""


def get_database_settings():
    if not MARZBAN_ENV.is_file():
        raise RuntimeError(f"فایل تنظیمات مرزبان پیدا نشد: {MARZBAN_ENV}")
    database_url = parse_dotenv_value(MARZBAN_ENV, "SQLALCHEMY_DATABASE_URL")
    if not database_url:
        raise RuntimeError("SQLALCHEMY_DATABASE_URL در فایل .env پیدا نشد.")
    parsed = urlsplit(database_url)
    if not parsed.scheme.startswith(("mysql", "mariadb")):
        raise RuntimeError(f"این نسخه برای MySQL/MariaDB آماده شده؛ نوع فعلی: {parsed.scheme}")
    username = unquote(parsed.username or "")
    password = unquote(parsed.password or "")
    database = unquote(parsed.path.lstrip("/").split("?", 1)[0])
    if not username or not password or not database:
        raise RuntimeError("نام کاربری، رمز یا نام دیتابیس از آدرس اتصال خوانده نشد.")
    return username, password, database


def find_mysql_container():
    proc = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}|{{.Image}}"],
        capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        raise RuntimeError("دستور docker ps اجرا نشد: " + proc.stderr[-1200:])
    matches = []
    for line in proc.stdout.splitlines():
        parts = line.split("|", 1)
        if len(parts) == 2 and re.search(r"mysql|mariadb", parts[1], re.I):
            matches.append(parts[0])
    if not matches:
        raise RuntimeError("کانتینر در حال اجرای MySQL/MariaDB پیدا نشد.")
    # Prefer the familiar Marzban DB container name when several MySQL containers exist.
    matches.sort(key=lambda name: (0 if "marzban" in name.lower() else 1, name))
    return matches[0]


def create_zip_backup():
    username, password, database = get_database_settings()
    container = find_mysql_container()
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    work = Path(tempfile.mkdtemp(prefix="marzban-telegram-backup-"))
    sql_file = work / "database.sql"
    zip_file = work / f"marzban_db_{stamp}.zip"

    log(f"شروع بکاپ دیتابیس {database} از کانتینر {container}")
    dump_shell = (
        'if command -v mysqldump >/dev/null 2>&1; then DUMP=mysqldump; '
        'elif command -v mariadb-dump >/dev/null 2>&1; then DUMP=mariadb-dump; '
        'else echo "mysqldump/mariadb-dump not found in MySQL container" >&2; exit 127; fi; '
        'exec "$DUMP" --single-transaction --quick --routines --triggers '
        '--events --no-tablespaces -h 127.0.0.1 -P 3306 '
        '-u "$DB_USER" "$DB_NAME"'
    )
    # Pass the DB password through docker exec stdin, not its command-line arguments.
    safe_shell = "IFS= read -r MYSQL_PWD || exit 1; export MYSQL_PWD; " + dump_shell
    command = [
        "docker", "exec", "-i",
        "-e", "DB_USER=" + username,
        "-e", "DB_NAME=" + database,
        container, "sh", "-c", safe_shell,
    ]
    try:
        with sql_file.open("wb") as output:
            result = subprocess.run(
                command, input=(password + "\n").encode("utf-8"),
                stdout=output, stderr=subprocess.PIPE, text=False
            )
        if result.returncode != 0:
            err_text = (result.stderr or b"no details").decode("utf-8", "replace")
            raise RuntimeError("خطای mysqldump: " + err_text[-2500:])
        if not sql_file.is_file() or sql_file.stat().st_size == 0:
            raise RuntimeError("خروجی SQL خالی است.")

        with zipfile.ZipFile(zip_file, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            archive.write(sql_file, arcname=f"marzban_{database}_{stamp}.sql")
        with zipfile.ZipFile(zip_file, "r") as archive:
            bad_member = archive.testzip()
            if bad_member:
                raise RuntimeError(f"فایل ZIP خراب است: {bad_member}")

        return work, zip_file, stamp, database, sql_file.stat().st_size
    except Exception:
        shutil.rmtree(work, ignore_errors=True)
        raise


def split_if_needed(zip_file, work_dir):
    if zip_file.stat().st_size <= PART_SIZE:
        return [zip_file]
    parts = []
    with zip_file.open("rb") as src:
        index = 1
        while True:
            data = src.read(PART_SIZE)
            if not data:
                break
            part_path = work_dir / f"{zip_file.name}.part{index:04d}"
            part_path.write_bytes(data)
            parts.append(part_path)
            index += 1
    return parts


def do_backup(cfg, notify=True):
    owner = cfg.get("owner_id")
    if not owner:
        raise RuntimeError("ربات هنوز به صاحبش متصل نشده است؛ ابتدا /pair CODE را بفرست.")
    if cfg.get("backup_running"):
        return

    cfg["backup_running"] = True
    cfg["last_attempt_epoch"] = int(time.time())
    write_config(cfg)

    work = None
    try:
        if notify:
            send_message(cfg, "⏳ بکاپ دیتابیس مرزبان شروع شد...")
        work, zip_file, stamp, database, raw_size = create_zip_backup()
        parts = split_if_needed(zip_file, work)
        total = len(parts)
        zip_size = zip_file.stat().st_size
        if total > 1:
            send_message(
                cfg,
                "⚠️ فایل ZIP به چند قسمت تقسیم شد. برای بازسازی پس از دانلود همه قسمت‌ها، آن‌ها را به ترتیب شماره کنار هم قرار بده و اجرا کن:\n"
                f"cat {zip_file.name}.part* > {zip_file.name}"
            )
        for index, part in enumerate(parts, 1):
            caption = (
                "✅ بکاپ دیتابیس مرزبان\n"
                f"Database: {database}\n"
                f"Date: {stamp}\n"
                f"ZIP: {zip_size / 1048576:.2f} MB\n"
                f"Part: {index}/{total}"
            )
            log(f"ارسال پارت {index}/{total} ({part.stat().st_size / 1048576:.2f} MB)")
            send_document(cfg["bot_token"], owner, part, caption)

        completed = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        cfg["last_backup_epoch"] = int(time.time())
        cfg["last_backup_at"] = completed
        cfg["last_result"] = f"موفق ✅ | {zip_size / 1048576:.2f} MB | {total} فایل"
        write_config(cfg)
        log(f"بکاپ با موفقیت ارسال شد؛ دیتابیس={database} ZIP={zip_size} bytes parts={total}")
    except Exception as exc:
        cfg["last_result"] = "ناموفق ❌ | " + str(exc)[:700]
        write_config(cfg)
        log("خطای بکاپ: " + str(exc))
        try:
            send_message(cfg, "❌ بکاپ ناموفق بود:\n" + str(exc)[:3000])
        except Exception as send_exc:
            log("ارسال پیام خطا به تلگرام ناموفق بود: " + str(send_exc))
    finally:
        cfg["backup_running"] = False
        write_config(cfg)
        if work:
            shutil.rmtree(work, ignore_errors=True)


def answer_callback(cfg, callback_id, text=""):
    try:
        telegram_api(cfg["bot_token"], "answerCallbackQuery", {"callback_query_id": callback_id, "text": text[:180]})
    except Exception as exc:
        log("پاسخ callback ناموفق بود: " + str(exc))


def handle_message(cfg, message):
    sender = message.get("from") or {}
    sender_id = sender.get("id")
    chat_id = (message.get("chat") or {}).get("id")
    text = (message.get("text") or "").strip()
    if not text or not sender_id:
        return

    # Pairing is intentionally restricted to a private chat.
    is_private = (message.get("chat") or {}).get("type") == "private"
    if not cfg.get("owner_id"):
        match = re.match(r"^/pair\s+(\S+)\s*$", text)
        if match and is_private:
            supplied = match.group(1)
            expected = cfg.get("pair_code") or ""
            import hmac
            if expected and hmac.compare_digest(supplied, expected):
                cfg["owner_id"] = int(sender_id)
                cfg["pair_code"] = None
                cfg["last_backup_epoch"] = 0  # first backup is due immediately after pairing
                cfg["last_attempt_epoch"] = 0
                write_config(cfg)
                send_message(cfg, "✅ ربات با موفقیت به حساب شما متصل شد.\nاولین بکاپ را همین الان شروع می‌کنم.", main_keyboard(cfg), chat_id)
                do_backup(cfg, notify=False)
                return
            send_message(cfg, "❌ کد اتصال اشتباه است یا قبلاً استفاده شده.", chat_id=chat_id)
            return
        send_message(cfg, "برای اتصال امن، کد یک‌بارمصرفی را که هنگام نصب روی سرور نمایش داده شد بفرست:\n/pair YOUR_CODE", chat_id=chat_id)
        return

    if int(sender_id) != int(cfg["owner_id"]):
        send_message(cfg, "⛔ این ربات به مدیر دیگری متصل است.", chat_id=chat_id)
        return

    command = text.split()[0].split("@", 1)[0].lower()
    if command in ("/start", "/menu"):
        send_message(cfg, "پنل مدیریت بکاپ دیتابیس مرزبان 👇", main_keyboard(cfg), chat_id)
    elif command == "/help":
        send_message(cfg, help_text(), main_keyboard(cfg), chat_id)
    elif command == "/status":
        send_message(cfg, status_text(cfg), main_keyboard(cfg), chat_id)
    elif command in ("/run", "/backup"):
        do_backup(cfg)
    elif command == "/interval":
        send_message(cfg, "فاصله ارسال خودکار بکاپ را انتخاب کن:", interval_keyboard(), chat_id)
    elif command == "/pause":
        cfg["enabled"] = False
        write_config(cfg)
        send_message(cfg, "⏸ زمان‌بندی خودکار متوقف شد.", main_keyboard(cfg), chat_id)
    elif command == "/resume":
        cfg["enabled"] = True
        cfg["last_backup_epoch"] = int(time.time())
        cfg["last_attempt_epoch"] = int(time.time())
        write_config(cfg)
        send_message(cfg, "▶️ زمان‌بندی خودکار فعال شد.", main_keyboard(cfg), chat_id)
    elif command == "/setinterval":
        parts = text.split()
        if len(parts) != 2 or not parts[1].isdigit() or not 1 <= int(parts[1]) <= 168:
            send_message(cfg, "عدد فاصله را بین ۱ تا ۱۶۸ ساعت وارد کن. مثال: /setinterval 6", chat_id=chat_id)
        else:
            cfg["interval_hours"] = int(parts[1])
            cfg["last_backup_epoch"] = int(time.time())
            cfg["last_attempt_epoch"] = int(time.time())
            write_config(cfg)
            send_message(cfg, f"✅ فاصله بکاپ روی هر {parts[1]} ساعت تنظیم شد.", main_keyboard(cfg), chat_id)
    else:
        send_message(cfg, "دستور را نشناختم. از منوی زیر استفاده کن:", main_keyboard(cfg), chat_id)


def handle_callback(cfg, callback):
    sender_id = (callback.get("from") or {}).get("id")
    callback_id = callback.get("id")
    data = callback.get("data", "")
    message = callback.get("message") or {}
    chat_id = (message.get("chat") or {}).get("id")
    if not cfg.get("owner_id") or int(sender_id or 0) != int(cfg.get("owner_id") or 0):
        answer_callback(cfg, callback_id, "دسترسی ندارید")
        return

    answer_callback(cfg, callback_id)
    if data == "backup_now":
        send_message(cfg, "⏳ درخواست بکاپ فوری ثبت شد.", chat_id=chat_id)
        do_backup(cfg, notify=False)
    elif data == "interval_menu":
        send_message(cfg, "فاصله زمانی را انتخاب کن:", interval_keyboard(), chat_id)
    elif data.startswith("interval:"):
        try:
            hours = int(data.split(":", 1)[1])
        except ValueError:
            return
        if hours not in ALLOWED_INTERVALS:
            return
        cfg["interval_hours"] = hours
        cfg["last_backup_epoch"] = int(time.time())
        cfg["last_attempt_epoch"] = int(time.time())
        cfg["enabled"] = True
        write_config(cfg)
        send_message(cfg, f"✅ زمان‌بندی تنظیم شد: هر {hours} ساعت یک بکاپ.", main_keyboard(cfg), chat_id)
    elif data == "toggle_schedule":
        cfg["enabled"] = not cfg.get("enabled", True)
        if cfg["enabled"]:
            cfg["last_backup_epoch"] = int(time.time())
        write_config(cfg)
        label = "فعال شد ▶️" if cfg["enabled"] else "متوقف شد ⏸"
        send_message(cfg, "زمان‌بندی " + label, main_keyboard(cfg), chat_id)
    elif data == "status":
        send_message(cfg, status_text(cfg), main_keyboard(cfg), chat_id)
    elif data == "help":
        send_message(cfg, help_text(), main_keyboard(cfg), chat_id)
    elif data == "menu":
        send_message(cfg, "پنل مدیریت بکاپ مرزبان:", main_keyboard(cfg), chat_id)


def bot_loop():
    cfg = read_config()
    # Recover cleanly if the process was killed during a previous backup.
    if cfg.get("backup_running"):
        cfg["backup_running"] = False
        write_config(cfg)
    token = cfg["bot_token"]
    me = telegram_api(token, "getMe")
    log(f"ربات @{me.get('username', 'unknown')} شروع شد.")
    # Long polling requires webhooks to be disabled.
    telegram_api(token, "deleteWebhook", {"drop_pending_updates": "false"})
    offset = None

    while True:
        try:
            cfg = read_config()
            # Run the scheduled backup when due. Failed attempts are also spaced by the selected interval.
            if cfg.get("owner_id") and cfg.get("enabled", True) and not cfg.get("backup_running"):
                last_attempt = int(cfg.get("last_attempt_epoch") or 0)
                due_after = int(cfg.get("interval_hours", 6)) * 3600
                if last_attempt == 0 or time.time() - last_attempt >= due_after:
                    do_backup(cfg)
                    cfg = read_config()

            params = {"timeout": POLL_TIMEOUT, "allowed_updates": json.dumps(["message", "callback_query"])}
            if offset is not None:
                params["offset"] = offset
            updates = telegram_api(token, "getUpdates", params, timeout=POLL_TIMEOUT + 10) or []
            for update in updates:
                offset = int(update["update_id"]) + 1
                cfg = read_config()
                if "message" in update:
                    handle_message(cfg, update["message"])
                elif "callback_query" in update:
                    handle_callback(cfg, update["callback_query"])
        except KeyboardInterrupt:
            raise
        except Exception as exc:
            log("خطای حلقه ربات: " + str(exc))
            time.sleep(5)


def install():
    if os.geteuid() != 0:
        raise SystemExit("نصب را با root اجرا کن.")
    if not MARZBAN_ENV.is_file():
        raise SystemExit(f"فایل {MARZBAN_ENV} پیدا نشد؛ مسیر فعلی برای نصب مرزبان شما تنظیم شده است.")
    if shutil.which("docker") is None:
        raise SystemExit("Docker نصب نیست یا در PATH نیست.")
    if shutil.which("systemctl") is None:
        raise SystemExit("systemd/systemctl روی این سرور پیدا نشد.")

    existing = {}
    if CONFIG_FILE.exists():
        try:
            existing = read_config()
        except Exception:
            existing = {}

    token = existing.get("bot_token")
    if not token:
        legacy = Path("/root/.marzban-db-telegram.conf")
        if legacy.is_file():
            try:
                for line in legacy.read_text(encoding="utf-8", errors="replace").splitlines():
                    if line.startswith("BOT_TOKEN="):
                        token = shlex.split(line.split("=", 1)[1], posix=True)[0]
                        break
            except Exception:
                token = None
    if not token:
        token = getpass.getpass("توکن ربات تلگرام (از BotFather) را وارد کن: ").strip()
    if not token or ":" not in token:
        raise SystemExit("توکن ربات معتبر به نظر نمی‌رسد.")

    try:
        me = telegram_api(token, "getMe")
    except Exception as exc:
        raise SystemExit("اعتبارسنجی توکن ناموفق بود: " + str(exc))

    pair_code = existing.get("pair_code") or secrets.token_urlsafe(8)
    cfg = {
        "bot_token": token,
        "owner_id": existing.get("owner_id"),
        "pair_code": pair_code if not existing.get("owner_id") else None,
        "interval_hours": int(existing.get("interval_hours", 6)),
        "enabled": bool(existing.get("enabled", True)),
        "last_backup_epoch": int(existing.get("last_backup_epoch", int(time.time()))),
        "last_attempt_epoch": int(existing.get("last_attempt_epoch", 0)),
        "last_backup_at": existing.get("last_backup_at"),
        "last_result": existing.get("last_result", "هنوز اجرا نشده"),
        "backup_running": False,
    }

    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve()
    if source != INSTALLED_SCRIPT.resolve():
        shutil.copy2(source, INSTALLED_SCRIPT)
    os.chmod(INSTALLED_SCRIPT, 0o700)
    write_config(cfg)

    unit = f"""[Unit]
Description=Marzban Telegram Database Backup Bot
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
WorkingDirectory={INSTALL_DIR}
ExecStart=/usr/bin/python3 {INSTALLED_SCRIPT} --run
Restart=always
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadOnlyPaths=/opt/marzban/.env

[Install]
WantedBy=multi-user.target
"""
    SERVICE_FILE.write_text(unit, encoding="utf-8")
    os.chmod(SERVICE_FILE, 0o644)

    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "--now", APP_NAME], check=True)
    subprocess.run(["systemctl", "restart", APP_NAME], check=True)

    print("\n✅ نصب سرویس انجام شد.")
    print(f"🤖 ربات: @{me.get('username', 'unknown')}")
    if not cfg.get("owner_id"):
        print("\n🔐 کد اتصال یک‌بارمصرف شما (این کد را فقط در گفت‌وگوی خصوصی ربات بفرست):")
        print(f"/pair {pair_code}")
    print("\nدر تلگرام ربات را باز کن و /start بزن.")
    print("وضعیت سرویس: systemctl status marzban-telegram-backup")
    print("گزارش سرویس: journalctl -u marzban-telegram-backup -f")


def main():
    parser = argparse.ArgumentParser(description="Marzban Telegram ZIP database backup bot")
    parser.add_argument("--install", action="store_true", help="install/update systemd service")
    parser.add_argument("--run", action="store_true", help="run bot polling loop")
    args = parser.parse_args()
    if args.install:
        install()
    elif args.run:
        bot_loop()
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
