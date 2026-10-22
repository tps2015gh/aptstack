# aptstack

Portable **PHP + MariaDB + app-version manager** for Windows. No installer, no registry —
one folder you can copy to a server, run as a **Windows Service**, and switch versions with one command.

Inspired by [Laragon](https://laragon.org/) / XAMPP, and by the `devstack` tool — but adds two things
devstack does not have: **app-version switching** and **Windows Service install**.

> **ภาษาไทย:** [README-TH.md](README-TH.md) · คู่มือใช้งาน [docs/คู่มือ.md](docs/คู่มือ.md) ·
> [docs/คู่มือ.html](docs/คู่มือ.html) · เทียบกับ devstack [docs/เปรียบเทียบ-devstack.md](docs/เปรียบเทียบ-devstack.md)

---

## Why

- **Copy-to-deploy.** Every absolute path inside the bundle is regenerated at start
  → copy the folder to another machine and it just works.
- **Switch versions safely.** App code lives in `versions\<ver>` and the live docroot is a junction.
  Switching = repoint the junction + restart. Old version stays on disk → instant rollback.
- **Security by default.** `aptstack doctor` checks against the PHP RCE advisory
  (`8.5.12 / 8.4.27 / 8.3.36 / 8.2.35` minimum; `≤8.1` is EOL) and confirms hardening is applied.

## Quick start

```cmd
cd /d D:\aptstack
aptstack list            :: what's installed
aptstack start           :: MariaDB + web
aptstack doctor          :: security / health check
```

Open <http://127.0.0.1:8077/app/>

```cmd
:: add + switch app version
aptstack add app C:\deploy\myapp-1.2.0.zip
aptstack use 1.2.0
aptstack use -            :: rollback

:: add + switch PHP
aptstack add php C:\Downloads\php-8.3.36-Win32-vs16-x64.zip
aptstack use php 8.3.36

:: run as a Windows Service (needs admin)
aptstack service install
aptstack service start
```

## Layout

```
aptstack\
├── aptstack.cmd / as.cmd     entry points
├── aptstack.ps1              all logic
├── setup.ps1                 first-run wizard
├── service.ps1               Windows Service install/uninstall
├── service\AptStackService.cs  service host source (compiled by service.ps1)
├── templates\                <- EDIT THESE (php.ini, my.ini, extensions, hardening)
├── config\                   <- ONE config folder (gitignored)
│   ├── stack.json              version + port selection (the file you edit)
│   ├── php.ini / my.ini        generated — do not edit
│   ├── pids\, tmp\, stop.flag
├── stack\                    binaries (gitignored)
│   ├── php\8.3.36\, php\8.1.34\
│   └── mysql\mariadb-11.4.13-winx64\
├── versions\                 app source code (gitignored)  versions\1.0.0\, 1.1.0\
├── data\                     database (gitignored)  datadir per engine + dumps\
├── www\                      docroot: router.php + phpmyadmin + junction -> versions\<active>
├── logs\  downloads\  bin\
└── docs\                     manuals
```

**Rule of thumb:** `templates\` = permanent source · `config\` = generated values ·
`stack\` = binaries · `versions\` = code · `data\` = database.

Only `templates\`, scripts and docs are committed to git — binaries, app code and database dumps
are ignored on purpose (this repo is public).

## Commands

| Command | What it does |
|---|---|
| `aptstack init` | create folder structure |
| `aptstack add app <folder\|zip>` | add app version → `versions\<name>` |
| `aptstack add php <zip\|url>` | add PHP → `stack\php\<ver>` |
| `aptstack list` | installed versions + active one |
| `aptstack use <ver>` | switch app version (+ auto restart) |
| `aptstack use php <ver>` | switch PHP (+ auto restart) |
| `aptstack use` | menu (pick by number) |
| `aptstack use -` | rollback to previous version |
| `aptstack next` / `prev` | cycle app versions |
| `aptstack start` / `stop` / `restart` | stack lifecycle |
| `aptstack status` | running? which version? |
| `aptstack doctor` | security + health check |
| `aptstack backup [file]` | dump all databases → `data\dumps\` |
| `aptstack service install` | Windows Service (admin) |

## Ports

| Service | Default | Change in |
|---|---|---|
| Web (PHP built-in server) | `8077` | `config\stack.json` → `httpPort` |
| MariaDB | `3307` | `config\stack.json` → `dbPort` |

Want to keep using **XAMPP's MySQL** instead of the bundled MariaDB?
Set `"dbMode": "external"` and `"dbPort": 3306` in `config\stack.json` — aptstack will neither
start nor stop that MySQL (see [คู่มือ.md](docs/คู่มือ.md)).

## Security

See [SECURITY.md](SECURITY.md). Short version:

- Active PHP must be **8.5.12+ / 8.4.27+ / 8.3.36+ / 8.2.35+**.
- `aptstack doctor` fails if it isn't, and checks `session.upload_progress`, `expose_php`,
  `allow_url_include`, `display_errors`, DB bind address and that no DB dump is tracked by git.
- Bundled MariaDB listens on `127.0.0.1` only.

## License

MIT
