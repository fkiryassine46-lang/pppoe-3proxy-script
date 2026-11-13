#!/usr/bin/env python3
import os
import json
import datetime
import subprocess
from functools import wraps
from io import BytesIO

import requests
from flask import (
    Flask,
    request,
    redirect,
    url_for,
    render_template_string,
    session,
    send_file,
    jsonify,
    abort,
)
from werkzeug.security import generate_password_hash, check_password_hash

# -----------------------------
# Configuration de base
# -----------------------------

APP_TITLE = "Proxy Panel"

PROXY_SOURCE_FILE = "/root/proxies.txt"
DB_FILE = "/root/proxy_panel_db.json"
CONFIG_FILE = "/root/proxy_panel_config.json"

CHECK_TEST_URL = "https://www.google.com"
CHECK_TIMEOUT = 20  # secondes

# --- Re-Generate (régénération des proxies depuis le dashboard) ---
REGEN_SCRIPT = "/root/pppoe_macvlan_3proxy.sh"
REGEN_STATUS_FILE = "/root/regen_status.json"
REGEN_LOG_FILE = "/root/regen_run.log"
REGEN_COUNT = 36  # maximum stable de la ligne (18 MAC x 2 BRAS)

app = Flask(__name__)
app.secret_key = "change-me-if-you-want"  # pour la session Flask


# =============================
# Utilitaires fichiers
# =============================

def load_json(path, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, data):
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp_path, path)


# =============================
# Config admin (login / pass)
# =============================

def ensure_config():
    cfg = load_json(CONFIG_FILE, {})
    changed = False
    if "admin_username" not in cfg:
        cfg["admin_username"] = "admin"
        changed = True
    if "password_hash" not in cfg:
        cfg["password_hash"] = generate_password_hash("lolopolo")
        changed = True
    if changed:
        save_json(CONFIG_FILE, cfg)
    return cfg


def get_config():
    return ensure_config()


def set_admin_password(new_username, new_password):
    cfg = get_config()
    if new_username:
        cfg["admin_username"] = new_username
    if new_password:
        cfg["password_hash"] = generate_password_hash(new_password)
    save_json(CONFIG_FILE, cfg)


# =============================
# DB clients / proxies
# =============================

def ensure_db():
    db = load_json(DB_FILE, {})
    changed = False
    if "clients" not in db:
        db["clients"] = []
        changed = True
    if "assigned_proxies" not in db:
        db["assigned_proxies"] = {}  # proxy_line -> client_id
        changed = True
    if changed:
        save_json(DB_FILE, db)
    return db


def get_db():
    return ensure_db()


def save_db(db):
    save_json(DB_FILE, db)


def next_client_id(db):
    if not db["clients"]:
        return 1
    return max(c["id"] for c in db["clients"]) + 1


# =============================
# Proxies: chargement + stats
# =============================

def load_proxy_list():
    if not os.path.exists(PROXY_SOURCE_FILE):
        return []
    proxies = []
    with open(PROXY_SOURCE_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            proxies.append(line)
    return proxies


def compute_stats():
    db = get_db()
    all_proxies = load_proxy_list()
    assigned = set(db["assigned_proxies"].keys())
    total = len(all_proxies)
    assigned_count = len(assigned & set(all_proxies))
    available_count = total - assigned_count
    clients_count = len(db["clients"])
    return {
        "total_proxies": total,
        "assigned_proxies": assigned_count,
        "available_proxies": available_count,
        "clients_count": clients_count,
        "proxy_source": PROXY_SOURCE_FILE,
        "db_file": DB_FILE,
    }


# =============================
# Login / sessions
# =============================

def login_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login", next=request.path))
        return f(*args, **kwargs)
    return wrapper


# =============================
# Parsing / check des proxies
# =============================

def parse_proxy_line(line: str):
    """
    Accepte :
      IP:PORT
      IP:PORT:USER:PASS
    Retourne dict ou None si invalide.
    """
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    parts = line.split(":")
    if len(parts) == 2:
        host, port = parts
        user = password = None
    elif len(parts) == 4:
        host, port, user, password = parts
    else:
        return None
    try:
        port = int(port)
    except ValueError:
        return None
    return {
        "host": host,
        "port": port,
        "user": user,
        "password": password,
    }


def build_proxy_url(info: dict) -> str:
    if info["user"] and info["password"]:
        return f"http://{info['user']}:{info['password']}@{info['host']}:{info['port']}"
    else:
        return f"http://{info['host']}:{info['port']}"


def check_proxy(proxy_line: str, timeout: float = CHECK_TIMEOUT) -> bool:
    """
    Test via HTTPS sur Google.
    True = OK, False = FAIL.
    """
    info = parse_proxy_line(proxy_line)
    if not info:
        return False

    proxy_url = build_proxy_url(info)
    proxies = {"http": proxy_url, "https": proxy_url}

    try:
        r = requests.get(CHECK_TEST_URL, proxies=proxies, timeout=timeout)
        return 200 <= r.status_code < 400
    except Exception:
        return False


# =============================
# Templates
# =============================

# ---- LOGIN : même structure, couleurs néon + photo de proxy ----
LOGIN_TEMPLATE = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{{ title }} - Login</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <style>
    * { box-sizing:border-box; }
    body {
      margin: 0;
      font-family: system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
      /* Photo de datacenter + overlay sombre néon */
      background-image:
        radial-gradient(circle at top left, rgba(0, 245, 255, 0.25), transparent 55%),
        radial-gradient(circle at bottom right, rgba(255, 45, 251, 0.22), transparent 55%),
        linear-gradient(160deg, rgba(3,7,18,0.96), rgba(3,7,18,0.98)),
        url("https://images.pexels.com/photos/4219643/pexels-photo-4219643.jpeg?auto=compress&cs=tinysrgb&w=1600");
      background-size: cover;
      background-position: center;
      background-attachment: fixed;
      color: #e5e7eb;
      height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .card {
      width: 380px;
      border-radius: 20px;
      padding: 28px 30px 26px;
      background:
        radial-gradient(circle at top left, rgba(0,245,255,0.09), transparent 60%),
        radial-gradient(circle at bottom right, rgba(255,45,251,0.10), transparent 60%),
        rgba(15,23,42,0.96);
      border: 1px solid rgba(59,130,246,0.6);
      box-shadow:
        0 0 30px rgba(0,245,255,0.4),
        0 30px 80px rgba(0,0,0,0.9);
      backdrop-filter: blur(6px);
    }
    .badge {
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: .16em;
      color: #a5b4fc;
      margin-bottom: 8px;
    }
    .logo {
      font-weight: 700;
      letter-spacing: .24em;
      font-size: 12px;
      text-transform: uppercase;
      color: #e5e7eb;
      margin-bottom: 14px;
    }
    .logo span {
      background: linear-gradient(135deg,#0ea5e9,#22c55e,#f97316,#ec4899);
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
    }
    h1 {
      margin: 0 0 6px;
      font-size: 22px;
    }
    .subtitle {
      font-size: 13px;
      color: #9ca3af;
      margin-bottom: 18px;
    }
    label {
      display: block;
      font-size: 13px;
      color: #e5e7eb;
      margin-bottom: 5px;
    }
    input {
      width: 100%;
      border-radius: 999px;
      border: 1px solid rgba(30,64,175,0.9);
      background: rgba(2,6,23,0.95);
      color: #e5e7eb;
      font-size: 14px;
      padding: 9px 12px;
      outline: none;
    }
    input:focus {
      border-color: #0ea5e9;
      box-shadow: 0 0 0 1px rgba(14,165,233,0.6), 0 0 12px rgba(56,189,248,0.7);
    }
    .field {
      margin-bottom: 14px;
    }
    .btn {
      margin-top: 6px;
      width: 100%;
      border-radius: 999px;
      border: none;
      padding: 10px 0;
      font-size: 14px;
      font-weight: 600;
      letter-spacing: .06em;
      text-transform: uppercase;
      cursor: pointer;
      color: #0b1120;
      background: linear-gradient(135deg,#22c55e,#0ea5e9,#a855f7);
      box-shadow:
        0 0 25px rgba(34,197,94,0.8),
        0 0 40px rgba(14,165,233,0.7);
    }
    .btn:hover { filter: brightness(1.08); }
    .error {
      margin-top: 10px;
      font-size: 13px;
      color: #fb7185;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="badge">Admin console</div>
    <div class="logo"><span>{{ title }}</span></div>
    <h1>Sign in</h1>
    <div class="subtitle">Secure access to your proxy management dashboard.</div>

    <form method="post">
      <div class="field">
        <label>Username</label>
        <input type="text" name="username" value="{{ default_user }}">
      </div>
      <div class="field">
        <label>Password</label>
        <input type="password" name="password">
      </div>
      <button class="btn" type="submit">Sign in</button>
    </form>

    {% if error %}
      <div class="error">{{ error }}</div>
    {% endif %}
  </div>
</body>
</html>
"""

# ---- LAYOUT : même structure, néon + même “check proxies” ----
LAYOUT_TEMPLATE = """
{% macro nav_link(href, label, active_name) -%}
  <a href="{{ href }}" class="nav-link {{ 'active' if active == active_name else '' }}">{{ label }}</a>
{%- endmacro %}

<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{{ title }} - {{ page_title }}</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <style>
    :root {
      --bg-main: #020617;
      --text-main: #e5e7eb;
      --text-muted: #9ca3af;
      --accent-primary: #0ea5e9;   /* cyan */
      --accent-secondary: #a855f7; /* violet */
      --accent-tertiary: #22c55e;  /* vert néon */
      --accent-ok: #22c55e;
      --accent-fail: #fb923c;
      --accent-warn: #eab308;
    }
    * { box-sizing:border-box; }
    body {
      margin:0;
      font-family: system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
      /* même photo de fond que login */
      background-image:
        radial-gradient(circle at 0% 0%, rgba(14,165,233,0.20), transparent 60%),
        radial-gradient(circle at 100% 0%, rgba(168,85,247,0.18), transparent 60%),
        linear-gradient(180deg, rgba(3,7,18,0.96), rgba(3,7,18,0.98)),
        url("https://images.pexels.com/photos/4219643/pexels-photo-4219643.jpeg?auto=compress&cs=tinysrgb&w=1600");
      background-size: cover;
      background-position: center;
      background-attachment: fixed;
      color:var(--text-main);
      min-height:100vh;
    }
    .shell {
      max-width: 1280px;
      margin: 0 auto;
      padding: 18px 20px 30px;
    }
    header {
      display:flex;
      align-items:center;
      justify-content:space-between;
      margin-bottom:18px;
    }
    .brand {
      display:flex;
      flex-direction:column;
      gap:2px;
    }
    .brand-title {
      font-weight:700;
      letter-spacing:.2em;
      font-size:12px;
      text-transform:uppercase;
    }
    .brand-title span {
      background: linear-gradient(135deg,#0ea5e9,#22c55e,#f97316,#ec4899);
      -webkit-background-clip:text;
      background-clip:text;
      color:transparent;
    }
    .brand-sub {
      font-size:11px;
      color:var(--text-muted);
    }
    nav {
      display:flex;
      gap:10px;
      align-items:center;
    }
    .nav-link {
      font-size:13px;
      padding:7px 14px;
      border-radius:999px;
      color:#e5e7eb;
      text-decoration:none;
      border:1px solid rgba(148,163,184,0.45);
      background:rgba(15,23,42,0.86);
      box-shadow:0 0 0 1px rgba(15,23,42,0.9);
    }
    .nav-link:hover {
      border-color:var(--accent-primary);
      box-shadow:0 0 14px rgba(14,165,233,0.7);
    }
    .nav-link.active {
      color:#0b1120;
      background:linear-gradient(135deg,var(--accent-primary),var(--accent-secondary));
      border-color:transparent;
      box-shadow:
        0 0 18px rgba(14,165,233,0.9),
        0 0 28px rgba(168,85,247,0.7);
    }
    .logout-link {
      font-size:12px;
      padding:7px 11px;
      border-radius:999px;
      border:1px solid rgba(148,163,184,0.45);
      background:rgba(15,23,42,0.9);
      color:var(--text-muted);
      text-decoration:none;
    }
    .logout-link:hover {
      border-color:var(--accent-secondary);
      color:#f9fafb;
      box-shadow:0 0 14px rgba(168,85,247,0.7);
    }

    h2 {
      margin:0 0 14px;
      font-size:20px;
    }

    .grid {
      display:grid;
      grid-template-columns:repeat(auto-fit,minmax(240px,1fr));
      gap:14px;
      margin-bottom:18px;
    }
    .card {
      background:
        radial-gradient(circle at top left, rgba(14,165,233,0.20), transparent 55%),
        radial-gradient(circle at bottom right, rgba(168,85,247,0.18), transparent 55%),
        rgba(15,23,42,0.92);
      border-radius:18px;
      padding:16px 18px;
      border:1px solid rgba(59,130,246,0.6);
      box-shadow:
        0 0 26px rgba(14,165,233,0.45),
        0 24px 70px rgba(0,0,0,0.9);
      backdrop-filter: blur(4px);
    }
    .card h3 {
      margin:0 0 6px;
      font-size:14px;
      color:#e5e7eb;
    }
    .card .big {
      font-size:28px;
      font-weight:600;
    }
    .muted {
      font-size:12px;
      color:var(--text-muted);
    }

    table {
      width:100%;
      border-collapse:collapse;
      font-size:13px;
    }
    th, td {
      padding:8px 10px;
      text-align:left;
      border-bottom:1px solid rgba(31,41,55,0.9);
    }
    th {
      font-size:11px;
      text-transform:uppercase;
      letter-spacing:.08em;
      color:var(--text-muted);
    }
    tr:hover td {
      background:rgba(15,23,42,0.9);
    }

    .pill {
      display:inline-block;
      padding:3px 8px;
      border-radius:999px;
      font-size:11px;
      border:1px solid rgba(148,163,184,0.6);
      color:#e5e7eb;
      background:rgba(15,23,42,0.96);
    }

    .btn {
      display:inline-flex;
      align-items:center;
      justify-content:center;
      padding:7px 15px;
      border-radius:999px;
      border:none;
      cursor:pointer;
      font-size:13px;
      color:#020617;
      background:linear-gradient(135deg,var(--accent-primary),var(--accent-secondary),var(--accent-tertiary));
      box-shadow:
        0 0 22px rgba(14,165,233,0.9),
        0 0 32px rgba(168,85,247,0.7);
    }
    .btn:hover { filter:brightness(1.06); }

    .btn-secondary {
      background:rgba(15,23,42,0.96);
      border:1px solid rgba(148,163,184,0.7);
      color:var(--text-main);
      box-shadow:none;
    }
    .btn-secondary:hover {
      border-color:var(--accent-primary);
      box-shadow:0 0 16px rgba(14,165,233,0.7);
    }

    .status-badge {
      padding:3px 9px;
      border-radius:999px;
      font-size:11px;
      font-weight:500;
      border:1px solid transparent;
    }
    .status-ok {
      background:rgba(34,197,94,0.16);
      color:#bbf7d0;
      border-color:rgba(34,197,94,0.8);
      box-shadow:0 0 10px rgba(34,197,94,0.7);
    }
    .status-fail {
      background:rgba(248,113,113,0.16);
      color:#fed7aa;
      border-color:rgba(248,113,113,0.9);
      box-shadow:0 0 10px rgba(248,113,113,0.7);
    }
    .status-unknown {
      background:rgba(148,163,184,0.18);
      color:#e5e7eb;
      border-color:rgba(148,163,184,0.9);
    }
    .status-checking {
      background:rgba(234,179,8,0.18);
      color:#facc15;
      border-color:rgba(234,179,8,0.9);
      box-shadow:0 0 10px rgba(250,204,21,0.7);
    }

    .form-row {
      display:flex;
      flex-wrap:wrap;
      gap:12px;
      margin-bottom:12px;
    }
    .form-row label {
      font-size:12px;
      color:var(--text-muted);
      display:block;
      margin-bottom:3px;
    }
    .form-row input {
      border-radius:999px;
      border:1px solid rgba(51,65,85,0.9);
      background:rgba(2,6,23,0.96);
      color:#e5e7eb;
      padding:7px 12px;
      min-width:140px;
      font-size:13px;
    }
    .form-row input:focus {
      outline:none;
      border-color:var(--accent-primary);
      box-shadow:0 0 0 1px rgba(14,165,233,0.6);
    }

    .error-msg {
      color:#fb7185;
      font-size:12px;
      margin-top:4px;
    }

    .footer-note {
      margin-top:18px;
      font-size:11px;
      color:var(--text-muted);
      text-align:center;
      text-shadow:0 0 10px rgba(15,23,42,0.9);
    }

    .progress-wrapper {
      margin-top:10px;
      font-size:12px;
      color:var(--text-muted);
    }
    .progress-bar-outer {
      width:100%;
      height:7px;
      border-radius:999px;
      background:rgba(15,23,42,0.96);
      overflow:hidden;
      margin-top:6px;
      border:1px solid rgba(31,41,55,0.9);
      box-shadow:0 0 14px rgba(14,165,233,0.6);
    }
    .progress-bar-inner {
      height:100%;
      width:0%;
      border-radius:999px;
      background:linear-gradient(90deg,#22c55e,#0ea5e9,#a855f7,#ec4899);
      transition:width .18s ease-out;
    }

    @media (max-width: 680px) {
      header { flex-direction:column; align-items:flex-start; gap:10px; }
      .shell { padding:14px 14px 24px; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <header>
      <div class="brand">
        <div class="brand-title"><span>{{ title }}</span></div>
        <div class="brand-sub">Internal proxy management console</div>
      </div>
      <nav>
        {{ nav_link(url_for('dashboard'), 'Dashboard', 'dashboard') }}
        {{ nav_link(url_for('clients'), 'Clients', 'clients') }}
        {{ nav_link(url_for('proxies'), 'Proxies', 'proxies') }}
        {{ nav_link(url_for('settings'), 'Settings', 'settings') }}
        <a class="logout-link" href="{{ url_for('logout') }}">Logout</a>
      </nav>
    </header>

    {{ body|safe }}

    <div class="footer-note">
      Local-only admin panel · Proxy source: {{ stats.proxy_source }} · DB: {{ stats.db_file }}
    </div>
  </div>
</body>
</html>
"""


# =============================
# Routes
# =============================

@app.route("/login", methods=["GET", "POST"])
def login():
    cfg = get_config()
    error = None
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        if username == cfg["admin_username"] and check_password_hash(cfg["password_hash"], password):
            session["logged_in"] = True
            next_url = request.args.get("next") or url_for("dashboard")
            return redirect(next_url)
        else:
            error = "Invalid username or password."
    return render_template_string(
        LOGIN_TEMPLATE,
        title=APP_TITLE,
        error=error,
        default_user=cfg["admin_username"],
    )


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
@login_required
def root():
    return redirect(url_for("dashboard"))


@app.route("/dashboard")
@login_required
def dashboard():
    stats = compute_stats()
    body = render_template_string("""
      <h2>Overview</h2>
      <div class="grid">
        <div class="card">
          <h3>Proxies</h3>
          <div class="big">{{ stats.total_proxies }}</div>
          <div class="muted">Total proxies in pool</div>
          <div class="muted" style="margin-top:6px;">
            <span style="color:#bbf7d0;">Available: {{ stats.available_proxies }}</span>
            &nbsp;·&nbsp;
            <span style="color:#fed7aa;">Assigned: {{ stats.assigned_proxies }}</span>
          </div>
        </div>
        <div class="card">
          <h3>Clients</h3>
          <div class="big">{{ stats.clients_count }}</div>
          <div class="muted">Each client download has its own text file.</div>
        </div>
        <div class="card">
          <h3>Pool status</h3>
          <div class="muted">Master proxy file:<br><code>{{ stats.proxy_source }}</code></div>
          <div class="muted" style="margin-top:6px;">Database file:<br><code>{{ stats.db_file }}</code></div>
        </div>
      </div>
    """, stats=stats)
    return render_template_string(
        LAYOUT_TEMPLATE,
        title=APP_TITLE,
        page_title="Dashboard",
        body=body,
        active="dashboard",
        stats=stats,
    )


@app.route("/clients", methods=["GET", "POST"])
@login_required
def clients():
    stats = compute_stats()
    db = get_db()
    error = None

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        count_str = request.form.get("count", "").strip()
        try:
            count = int(count_str)
        except ValueError:
            count = 0

        if not name:
            error = "Client name is required."
        elif count <= 0:
            error = "Number of proxies must be a positive integer."
        else:
            all_proxies = load_proxy_list()
            assigned = set(db["assigned_proxies"].keys())
            available = [p for p in all_proxies if p not in assigned]

            if len(available) < count:
                error = f"Not enough available proxies. Requested {count}, only {len(available)} left."
            else:
                selected = available[:count]
                client_id = next_client_id(db)
                created_at = datetime.datetime.now().isoformat(timespec="seconds")
                client = {
                    "id": client_id,
                    "name": name,
                    "count": count,
                    "proxies": selected,
                    "created_at": created_at,
                }
                db["clients"].append(client)
                for p in selected:
                    db["assigned_proxies"][p] = client_id
                save_db(db)

                filename = f"{name}_{count}proxies.txt"
                content = "\n".join(selected) + "\n"
                mem = BytesIO(content.encode("utf-8"))
                mem.seek(0)
                return send_file(
                    mem,
                    as_attachment=True,
                    download_name=filename,
                    mimetype="text/plain",
                )

    db = get_db()
    clients_list = sorted(db["clients"], key=lambda c: c["id"])

    body = render_template_string("""
      <h2>Clients</h2>
      <div class="grid">
        <div class="card">
          <h3>Create new client</h3>
          <form method="post">
            <div class="form-row">
              <div>
                <label>Client name</label>
                <input type="text" name="name" placeholder="e.g. Mohamed">
              </div>
              <div>
                <label>Number of proxies</label>
                <input type="number" name="count" min="1" placeholder="10">
              </div>
            </div>
            {% if error %}
              <div class="error-msg">{{ error }}</div>
            {% endif %}
            <button class="btn" type="submit">Create & download .txt</button>
            <div class="muted" style="margin-top:8px;">
              Available proxies: <strong>{{ stats.available_proxies }}</strong>
            </div>
          </form>
        </div>

        <div class="card">
          <h3>Summary</h3>
          <div class="muted">
            Total clients: <strong>{{ stats.clients_count }}</strong><br>
            Total proxies: <strong>{{ stats.total_proxies }}</strong><br>
            Assigned: <span style="color:#fed7aa;">{{ stats.assigned_proxies }}</span><br>
            Available: <span style="color:#bbf7d0;">{{ stats.available_proxies }}</span>
          </div>
        </div>
      </div>

      <div class="card" style="margin-top:16px;">
        <h3>Existing clients</h3>
        {% if not clients %}
          <div class="muted">No clients yet.</div>
        {% else %}
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Name</th>
                <th>Proxies</th>
                <th>Created</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {% for c in clients %}
                <tr>
                  <td>#{{ c.id }}</td>
                  <td>{{ c.name }}</td>
                  <td>{{ c.count }}</td>
                  <td>{{ c.created_at }}</td>
                  <td>
                    <a class="btn-secondary" href="{{ url_for('download_client', client_id=c.id) }}">Download</a>
                    <form method="post" action="{{ url_for('delete_client', client_id=c.id) }}" style="display:inline;" onsubmit="return confirm('Delete this client and free its proxies?');">
                      <button class="btn-secondary" type="submit" style="margin-left:6px;">Delete</button>
                    </form>
                  </td>
                </tr>
              {% endfor %}
            </tbody>
          </table>
        {% endif %}
      </div>
    """, stats=stats, clients=clients_list, error=error)
    return render_template_string(
        LAYOUT_TEMPLATE,
        title=APP_TITLE,
        page_title="Clients",
        body=body,
        active="clients",
        stats=stats,
    )


@app.route("/clients/<int:client_id>/download")
@login_required
def download_client(client_id):
    db = get_db()
    client = next((c for c in db["clients"] if c["id"] == client_id), None)
    if not client:
        abort(404)
    filename = f"{client['name']}_{client['count']}proxies.txt"
    content = "\n".join(client["proxies"]) + "\n"
    mem = BytesIO(content.encode("utf-8"))
    mem.seek(0)
    return send_file(
        mem,
        as_attachment=True,
        download_name=filename,
        mimetype="text/plain",
    )


@app.route("/clients/<int:client_id>/delete", methods=["POST"])
@login_required
def delete_client(client_id):
    db = get_db()
    new_clients = []
    removed_proxies = []
    for c in db["clients"]:
        if c["id"] == client_id:
            removed_proxies.extend(c.get("proxies", []))
        else:
            new_clients.append(c)
    db["clients"] = new_clients
    for p in removed_proxies:
        db["assigned_proxies"].pop(p, None)
    save_db(db)
    return redirect(url_for("clients"))


@app.route("/proxies")
@login_required
def proxies():
    stats = compute_stats()
    all_proxies = load_proxy_list()
    db = get_db()
    assigned_map = db["assigned_proxies"]

    table_data = []
    for p in all_proxies:
        client_id = assigned_map.get(p)
        table_data.append({
            "proxy": p,
            "client_id": client_id,
        })

    body = render_template_string("""
      <h2>Proxies</h2>
      <div class="card" style="margin-bottom:16px;">
        <div style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;">
          <div class="muted">
            Total: <strong>{{ stats.total_proxies }}</strong> ·
            Available: <span style="color:#bbf7d0;">{{ stats.available_proxies }}</span> ·
            Assigned: <span style="color:#fed7aa;">{{ stats.assigned_proxies }}</span>
          </div>
          <div style="display:flex;gap:10px;flex-wrap:wrap;">
            <button class="btn" id="check-all-btn">Check ALL Proxies</button>
            <button class="btn" id="regen-btn" style="background:linear-gradient(135deg,#f97316,#ec4899,#a855f7);box-shadow:0 0 22px rgba(236,72,153,.8),0 0 32px rgba(168,85,247,.7);">&#8635; Re-Generate</button>
            <button class="btn" id="copy-all-btn" style="background:linear-gradient(135deg,#22c55e,#0ea5e9);box-shadow:0 0 18px rgba(34,197,94,.7);">&#128203; Copy all</button>
          </div>
        </div>
        <div class="muted" style="margin-top:4px;font-size:11px;">
          Performs an HTTPS request to Google using each proxy (timeout {{ timeout }}s).
        </div>

        <div id="progress-wrapper" class="progress-wrapper" style="display:none;">
          <div>
            <span id="progress-label">0%</span>
            &nbsp;·&nbsp;
            <span id="progress-detail">Waiting…</span>
          </div>
          <div class="progress-bar-outer">
            <div class="progress-bar-inner" id="progress-bar"></div>
          </div>
        </div>

        <div id="check-summary" class="muted" style="margin-top:8px;font-size:12px;display:none;">
          Last check:
          <span id="sum-ok" style="color:#bbf7d0;">0 OK</span>
          &nbsp;·&nbsp;
          <span id="sum-fail" style="color:#fed7aa;">0 Failed</span>
        </div>
      </div>

      <div class="card" style="max-height:480px;overflow:auto;">
        <table id="proxy-table">
          <thead>
            <tr>
              <th>Proxy</th>
              <th>Assigned to</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {% for row in rows %}
              <tr data-proxy="{{ row.proxy }}">
                <td class="proxy-cell"><code>{{ row.proxy }}</code></td>
                <td>
                  {% if row.client_id %}
                    <span class="pill">Client #{{ row.client_id }}</span>
                  {% else %}
                    <span class="muted">Unassigned</span>
                  {% endif %}
                </td>
                <td class="status-cell">
                  <span class="status-badge status-unknown">UNKNOWN</span>
                </td>
              </tr>
            {% endfor %}
          </tbody>
        </table>
      </div>

      <!-- ===== Re-Generate modal ===== -->
      <style>
        #regen-overlay{position:fixed;inset:0;z-index:9999;display:none;align-items:center;justify-content:center;background:radial-gradient(circle at 50% 18%,rgba(14,165,233,.16),transparent 60%),rgba(2,6,23,.86);backdrop-filter:blur(8px);}
        #regen-overlay.show{display:flex;}
        .regen-card{position:relative;width:min(92vw,520px);border-radius:24px;padding:28px 30px 24px;background:radial-gradient(circle at top left,rgba(14,165,233,.14),transparent 55%),radial-gradient(circle at bottom right,rgba(168,85,247,.16),transparent 55%),rgba(15,23,42,.97);border:1px solid rgba(59,130,246,.6);box-shadow:0 0 40px rgba(14,165,233,.5),0 30px 90px rgba(0,0,0,.9);overflow:hidden;}
        .regen-card::before{content:"";position:absolute;inset:-2px;border-radius:24px;padding:2px;background:conic-gradient(from 0deg,#22c55e,#0ea5e9,#a855f7,#ec4899,#22c55e);-webkit-mask:linear-gradient(#000 0 0) content-box,linear-gradient(#000 0 0);-webkit-mask-composite:xor;mask-composite:exclude;animation:regen-spin 4s linear infinite;opacity:.55;pointer-events:none;}
        @keyframes regen-spin{to{transform:rotate(360deg);}}
        .regen-title{font-size:20px;font-weight:700;margin-bottom:4px;position:relative;}
        .regen-sub{font-size:12px;color:#9ca3af;margin-bottom:20px;position:relative;}
        .regen-steps{display:flex;justify-content:space-between;gap:6px;margin-bottom:18px;position:relative;}
        .regen-step{flex:1;text-align:center;}
        .regen-step .dot{width:30px;height:30px;border-radius:50%;margin:0 auto 6px;display:flex;align-items:center;justify-content:center;border:1px solid rgba(148,163,184,.5);background:rgba(2,6,23,.9);font-size:13px;color:#64748b;transition:all .3s;}
        .regen-step .lbl{font-size:10px;color:#64748b;letter-spacing:.04em;}
        .regen-step.active .dot{border-color:#0ea5e9;color:#e0f2fe;box-shadow:0 0 16px rgba(14,165,233,.85);animation:regen-pulse 1.2s ease-in-out infinite;}
        .regen-step.done .dot{border-color:#22c55e;background:rgba(34,197,94,.22);color:#bbf7d0;box-shadow:0 0 12px rgba(34,197,94,.7);}
        .regen-step.active .lbl,.regen-step.done .lbl{color:#e5e7eb;}
        @keyframes regen-pulse{0%,100%{transform:scale(1);}50%{transform:scale(1.14);}}
        .regen-pct{font-size:30px;font-weight:700;text-align:center;margin:4px 0;background:linear-gradient(135deg,#0ea5e9,#22c55e,#ec4899);-webkit-background-clip:text;background-clip:text;color:transparent;position:relative;}
        .regen-bar-outer{height:10px;border-radius:999px;background:rgba(2,6,23,.9);overflow:hidden;border:1px solid rgba(31,41,55,.9);box-shadow:inset 0 0 10px rgba(0,0,0,.6);position:relative;}
        .regen-bar-inner{height:100%;width:0%;border-radius:999px;background:linear-gradient(90deg,#22c55e,#0ea5e9,#a855f7,#ec4899);background-size:200% 100%;animation:regen-flow 2s linear infinite;transition:width .45s ease-out;}
        @keyframes regen-flow{to{background-position:200% 0;}}
        .regen-meta{display:flex;justify-content:space-between;margin-top:12px;font-size:12px;color:#9ca3af;position:relative;}
        .regen-detail{text-align:center;font-size:13px;color:#cbd5e1;min-height:18px;margin-top:8px;position:relative;}
        .regen-bigicon{font-size:42px;text-align:center;margin:2px 0;display:none;position:relative;}
        .regen-actions{margin-top:16px;text-align:center;position:relative;}
        #regen-close{display:none;}
      </style>
      <div id="regen-overlay">
        <div class="regen-card">
          <div class="regen-title">Regenerating proxies</div>
          <div class="regen-sub">Stopping current sessions and creating fresh public IPs…</div>
          <div class="regen-bigicon" id="regen-done-icon">&#9989;</div>
          <div class="regen-bigicon" id="regen-err-icon">&#9888;</div>
          <div class="regen-steps">
            <div class="regen-step" data-step="0"><div class="dot">&#9632;</div><div class="lbl">STOP</div></div>
            <div class="regen-step" data-step="1"><div class="dot">&#9671;</div><div class="lbl">PROBE</div></div>
            <div class="regen-step" data-step="2"><div class="dot">&#9889;</div><div class="lbl">CREATE</div></div>
            <div class="regen-step" data-step="3"><div class="dot">&#8593;</div><div class="lbl">CONNECT</div></div>
            <div class="regen-step" data-step="4"><div class="dot">&#10003;</div><div class="lbl">VERIFY</div></div>
          </div>
          <div class="regen-pct" id="regen-pct">0%</div>
          <div class="regen-bar-outer"><div class="regen-bar-inner" id="regen-bar"></div></div>
          <div class="regen-meta"><span id="regen-phase">Starting…</span><span id="regen-count">0 / {{ regen_count }}</span></div>
          <div class="regen-detail" id="regen-detail"></div>
          <div class="regen-actions"><button class="btn-secondary" id="regen-close">Close</button></div>
        </div>
      </div>

      <script>
        const checkBtn = document.getElementById('check-all-btn');
        const table = document.getElementById('proxy-table');
        const summaryDiv = document.getElementById('check-summary');
        const sumOkSpan = document.getElementById('sum-ok');
        const sumFailSpan = document.getElementById('sum-fail');
        const progressWrapper = document.getElementById('progress-wrapper');
        const progressBar = document.getElementById('progress-bar');
        const progressLabel = document.getElementById('progress-label');
        const progressDetail = document.getElementById('progress-detail');

        function setStatus(proxy, status) {
          const row = table.querySelector('tr[data-proxy="' + proxy.replace(/"/g,'&quot;') + '"]');
          if (!row) return;
          const cell = row.querySelector('.status-cell');
          if (!cell) return;

          let label = '';
          let cls = 'status-badge ';

          if (status === 'checking') {
            label = 'CHECKING';
            cls += 'status-checking';
          } else if (status === 'ok') {
            label = 'STATUS OK';
            cls += 'status-ok';
          } else if (status === 'fail') {
            label = 'STATUS FAIL';
            cls += 'status-fail';
          } else {
            label = 'UNKNOWN';
            cls += 'status-unknown';
          }
          cell.innerHTML = '<span class="' + cls + '">' + label + '</span>';
        }

        async function runCheckAll() {
          const rows = Array.from(table.querySelectorAll('tbody tr'));
          const total = rows.length;
          if (!total) return;

          let okCount = 0;
          let failCount = 0;

          progressWrapper.style.display = 'block';
          summaryDiv.style.display = 'none';
          progressBar.style.width = '0%';
          progressLabel.textContent = '0%';
          progressDetail.textContent = 'Starting...';

          rows.forEach(row => {
            const proxy = row.getAttribute('data-proxy');
            setStatus(proxy, 'checking');
          });

          for (let i = 0; i < total; i++) {
            const row = rows[i];
            const proxy = row.getAttribute('data-proxy');
            progressDetail.textContent = 'Checking ' + (i + 1) + ' / ' + total;

            try {
              const resp = await fetch('{{ url_for("proxies_check_one") }}', {
                method: 'POST',
                headers: {
                  'Content-Type': 'application/json',
                  'X-Requested-With': 'XMLHttpRequest'
                },
                body: JSON.stringify({ proxy: proxy })
              });
              const data = await resp.json();
              const status = (data && data.status === 'ok') ? 'ok' : 'fail';
              if (status === 'ok') okCount++; else failCount++;
              setStatus(proxy, status);
            } catch (e) {
              failCount++;
              setStatus(proxy, 'fail');
            }

            const pct = Math.round(((i + 1) / total) * 100);
            progressBar.style.width = pct + '%';
            progressLabel.textContent = pct + '%';
          }

          progressDetail.textContent = 'Completed';
          summaryDiv.style.display = 'block';
          sumOkSpan.textContent = okCount + ' OK';
          sumFailSpan.textContent = failCount + ' Failed';
        }

        if (checkBtn) {
          checkBtn.addEventListener('click', () => {
            runCheckAll();
          });
        }

        // ===== Re-Generate logic =====
        const regenBtn = document.getElementById('regen-btn');
        const regenOverlay = document.getElementById('regen-overlay');
        const regenPct = document.getElementById('regen-pct');
        const regenBar = document.getElementById('regen-bar');
        const regenPhase = document.getElementById('regen-phase');
        const regenDetail = document.getElementById('regen-detail');
        const regenCount = document.getElementById('regen-count');
        const regenClose = document.getElementById('regen-close');
        const regenSteps = Array.from(document.querySelectorAll('.regen-step'));
        const regenDoneIcon = document.getElementById('regen-done-icon');
        const regenErrIcon = document.getElementById('regen-err-icon');
        const REGEN_TOTAL = {{ regen_count }};
        let regenTimer = null;

        function regenStepIndex(pct){
          if (pct >= 100) return 5;
          if (pct >= 80) return 4;
          if (pct >= 55) return 3;
          if (pct >= 15) return 2;
          if (pct >= 10) return 1;
          return 0;
        }
        function regenPaint(active){
          regenSteps.forEach((el, i) => {
            el.classList.remove('active','done');
            if (i < active) el.classList.add('done');
            else if (i === active) el.classList.add('active');
          });
        }
        function regenShow(){
          regenOverlay.classList.add('show');
          regenClose.style.display = 'none';
          regenDoneIcon.style.display = 'none';
          regenErrIcon.style.display = 'none';
        }
        function regenHide(){ regenOverlay.classList.remove('show'); }

        async function regenPoll(){
          try {
            const r = await fetch('{{ url_for("proxies_regenerate_status") }}');
            const s = await r.json();
            const pct = Math.max(0, Math.min(100, s.pct || 0));
            regenBar.style.width = pct + '%';
            regenPct.textContent = pct + '%';
            regenPhase.textContent = s.phase || '';
            regenDetail.textContent = s.detail || '';
            regenCount.textContent = (s.ok || 0) + ' / ' + (s.total || REGEN_TOTAL);
            regenPaint(regenStepIndex(pct));
            if (s.state === 'done') {
              if (regenTimer) { clearInterval(regenTimer); regenTimer = null; }
              regenPaint(5);
              regenDoneIcon.style.display = 'block';
              regenPhase.textContent = 'Completed';
              regenPct.textContent = '100%';
              regenBar.style.width = '100%';
              regenDetail.textContent = (s.ok || 0) + ' new proxies ready. Reloading…';
              setTimeout(() => { window.location.reload(); }, 1800);
            } else if (s.state === 'error') {
              if (regenTimer) { clearInterval(regenTimer); regenTimer = null; }
              regenErrIcon.style.display = 'block';
              regenPhase.textContent = 'Error';
              regenDetail.textContent = s.detail || 'Regeneration failed.';
              regenClose.style.display = 'inline-flex';
            }
          } catch (e) { /* keep polling */ }
        }

        async function regenStart(){
          if (!confirm('Stop the current proxies and generate new ones with fresh IPs? This takes about 1-2 minutes.')) return;
          regenShow();
          regenPaint(0);
          regenPct.textContent = '0%';
          regenBar.style.width = '0%';
          regenPhase.textContent = 'Starting…';
          regenDetail.textContent = '';
          regenCount.textContent = '0 / ' + REGEN_TOTAL;
          try {
            await fetch('{{ url_for("proxies_regenerate") }}', {
              method: 'POST',
              headers: { 'X-Requested-With': 'XMLHttpRequest' }
            });
          } catch (e) {}
          if (regenTimer) clearInterval(regenTimer);
          regenTimer = setInterval(regenPoll, 1200);
          regenPoll();
        }

        if (regenBtn) regenBtn.addEventListener('click', regenStart);
        if (regenClose) regenClose.addEventListener('click', regenHide);

        // Reprendre l'affichage si une régénération tourne déjà au chargement
        (async function(){
          try {
            const r = await fetch('{{ url_for("proxies_regenerate_status") }}');
            const s = await r.json();
            if (s.state === 'running') {
              regenShow();
              if (regenTimer) clearInterval(regenTimer);
              regenTimer = setInterval(regenPoll, 1200);
              regenPoll();
            }
          } catch (e) {}
        })();

        // ===== Copy all proxies =====
        const copyBtn = document.getElementById('copy-all-btn');
        function collectAllProxies(){
          const rows = Array.from(table.querySelectorAll('tbody tr'));
          return rows.map(r => r.getAttribute('data-proxy')).filter(Boolean);
        }
        function copyTextCompat(text){
          if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
          }
          return new Promise((resolve, reject) => {
            try {
              const ta = document.createElement('textarea');
              ta.value = text;
              ta.style.position = 'fixed';
              ta.style.top = '-1000px';
              ta.setAttribute('readonly', '');
              document.body.appendChild(ta);
              ta.focus(); ta.select();
              const ok = document.execCommand('copy');
              document.body.removeChild(ta);
              ok ? resolve() : reject(new Error('execCommand failed'));
            } catch (e) { reject(e); }
          });
        }
        if (copyBtn) {
          copyBtn.addEventListener('click', async () => {
            const list = collectAllProxies();
            if (!list.length) {
              copyBtn.textContent = 'No proxies';
              setTimeout(() => { copyBtn.innerHTML = '&#128203; Copy all'; }, 1500);
              return;
            }
            const text = list.join(String.fromCharCode(10));
            try {
              await copyTextCompat(text);
              copyBtn.textContent = 'Copied ' + list.length + '!';
            } catch (e) {
              copyBtn.textContent = 'Copy failed';
            }
            setTimeout(() => { copyBtn.innerHTML = '&#128203; Copy all'; }, 1800);
          });
        }
      </script>
    """, stats=stats, rows=table_data, timeout=CHECK_TIMEOUT, regen_count=REGEN_COUNT)
    return render_template_string(
        LAYOUT_TEMPLATE,
        title=APP_TITLE,
        page_title="Proxies",
        body=body,
        active="proxies",
        stats=stats,
    )


@app.route("/proxies/check-one", methods=["POST"])
@login_required
def proxies_check_one():
    """
    Vérifie un seul proxy (appelé en boucle par le JS).
    """
    data = request.get_json(silent=True) or {}
    proxy_line = (data.get("proxy") or "").strip()
    if not proxy_line:
        return jsonify({"status": "fail", "error": "no proxy"}), 400

    ok = check_proxy(proxy_line)
    return jsonify({"status": "ok" if ok else "fail"})


# =============================
# Re-Generate: régénération des proxies
# =============================

def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def _regen_is_running():
    st = load_json(REGEN_STATUS_FILE, {})
    return bool(st.get("state") == "running" and st.get("pid") and _pid_alive(st.get("pid")))


def _pppd_running():
    try:
        return subprocess.run(
            ["pgrep", "-x", "pppd"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
    except Exception:
        return False


def _launch_regen():
    """Lance la régénération headless (36 proxies). Retourne (ok, info)."""
    if _regen_is_running():
        return False, "already_running"

    now = datetime.datetime.now().isoformat(timespec="seconds")
    init = {
        "state": "running", "phase": "Starting", "pct": 0,
        "detail": "Launching regeneration...", "ok": 0, "total": REGEN_COUNT,
        "pid": None, "ts": now,
    }
    save_json(REGEN_STATUS_FILE, init)

    env = os.environ.copy()
    env["REGEN_STATUS_FILE"] = REGEN_STATUS_FILE
    env["PROXY_COUNT"] = str(REGEN_COUNT)

    try:
        logf = open(REGEN_LOG_FILE, "ab")
        proc = subprocess.Popen(
            ["/bin/bash", REGEN_SCRIPT],
            cwd="/root",
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=logf,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except Exception as e:
        err = {
            "state": "error", "phase": "Failed", "pct": 100,
            "detail": "Could not start: %s" % e, "ok": 0, "total": REGEN_COUNT,
            "pid": None, "ts": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        save_json(REGEN_STATUS_FILE, err)
        return False, "launch_error:%s" % e

    init["pid"] = proc.pid
    save_json(REGEN_STATUS_FILE, init)
    return True, proc.pid


@app.route("/proxies/regenerate", methods=["POST"])
@login_required
def proxies_regenerate():
    if _regen_is_running():
        st = load_json(REGEN_STATUS_FILE, {})
        return jsonify({"started": False, "reason": "already_running", "status": st})
    ok, info = _launch_regen()
    if not ok:
        if info == "already_running":
            return jsonify({"started": False, "reason": "already_running"})
        return jsonify({"started": False, "reason": "launch_error", "error": str(info)}), 500
    return jsonify({"started": True, "pid": info})


@app.route("/proxies/regenerate/status")
@login_required
def proxies_regenerate_status():
    st = load_json(REGEN_STATUS_FILE, None)
    if not st:
        return jsonify({
            "state": "idle", "pct": 0, "phase": "Idle",
            "detail": "", "ok": 0, "total": REGEN_COUNT,
        })
    # Auto-réparation : "running" mais process mort sans "done" => erreur
    if st.get("state") == "running":
        pid = st.get("pid")
        if pid and not _pid_alive(pid):
            st = dict(st)
            st["state"] = "error"
            st["phase"] = "Stopped"
            st["detail"] = "Process ended unexpectedly."
            save_json(REGEN_STATUS_FILE, st)
    return jsonify(st)


@app.route("/settings", methods=["GET", "POST"])
@login_required
def settings():
    stats = compute_stats()
    cfg = get_config()
    msg = None
    error = None

    if request.method == "POST":
        new_user = request.form.get("username", "").strip()
        new_pass = request.form.get("password", "")
        confirm = request.form.get("confirm", "")
        if new_pass and new_pass != confirm:
            error = "Password confirmation does not match."
        else:
            set_admin_password(new_user or cfg["admin_username"], new_pass or None)
            msg = "Settings updated."
            cfg = get_config()

    body = render_template_string("""
      <h2>Settings</h2>
      <div class="card">
        <h3>Admin account</h3>
        <form method="post">
          <div class="form-row">
            <div>
              <label>Username</label>
              <input type="text" name="username" value="{{ cfg.admin_username }}">
            </div>
          </div>
          <div class="form-row">
            <div>
              <label>New password (optional)</label>
              <input type="password" name="password" placeholder="Leave blank to keep current">
            </div>
            <div>
              <label>Confirm password</label>
              <input type="password" name="confirm" placeholder="Repeat new password">
            </div>
          </div>
          {% if error %}
            <div class="error-msg">{{ error }}</div>
          {% endif %}
          {% if msg %}
            <div class="muted" style="color:#bbf7d0;margin-top:4px;">{{ msg }}</div>
          {% endif %}
          <button class="btn" type="submit" style="margin-top:8px;">Save settings</button>
        </form>
      </div>
    """, cfg=cfg, msg=msg, error=error)
    return render_template_string(
        LAYOUT_TEMPLATE,
        title=APP_TITLE,
        page_title="Settings",
        body=body,
        active="settings",
        stats=stats,
    )


# =============================
# Lancement
# =============================

def main():
    import argparse

    parser = argparse.ArgumentParser(description="Simple proxy management panel")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=1991)
    args = parser.parse_args()

    ensure_config()
    ensure_db()

    app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()