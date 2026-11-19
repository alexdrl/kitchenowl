# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

KitchenOwl is a self-hosted grocery list / recipe / meal-plan / expense manager. This monorepo has three parts:

- `backend/`: Flask REST API + Socket.IO server (Python, managed with `uv`)
- `kitchenowl/`: Flutter client for mobile, web and desktop
- `docs/`: user docs built with zensical (`docs/mkdocs.yml`)

`flutter/` is a git submodule of the Flutter SDK (stable). The root `Dockerfile` builds the all-in-one image: the Flutter web build is served by the backend's uWSGI.

## This fork (alexdrl/kitchenowl)

This checkout is a fork of [TomBursch/kitchenowl](https://github.com/TomBursch/kitchenowl). Remotes: `origin` = upstream, `fork` = alexdrl/kitchenowl. The private half of the deployment (registry, cluster, ArgoCD) is in `CLAUDE.local.md`, which is not committed. Read it before building or deploying anything.

**Branches.** Each change that should go upstream gets its own branch, created from `origin/main` and holding that change only. A new fix never goes into an existing feature branch.

| Branch | Upstream PR | What |
| --- | --- | --- |
| `feat/planner-meal` | not yet | meals (breakfast/lunch/dinner) in the planner, weekly view, text meals |
| `feat/android-widget` | not yet (needs `feat/planner-meal`, branched from it) | Android home screen widget: today's menu, or the current week when made big (tablets); refreshed by the background fetch task |
| `feat/planner-ics` | not yet (needs `feat/planner-meal`, branched from it) | iCalendar feed of the meal plan (secret link per household) and "Subscribe to calendar" in the planner |
| `feat/wear-shopping-list` | not yet | Wear OS watch app (`android/wear/`) to tick off the shopping list; the phone relays everything over the Data Layer, the watch has no network or token |
| `fix/web-base-uri` | TomBursch/kitchenowl#1236 | web API base from `<base href>`, not the page URL (deep links broke) |
| `fix/zero-yields-scale` | TomBursch/kitchenowl#1237 | recipes with 0 servings no longer throw when scaled |
| `feat/mcp-item-categories` | TomBursch/kitchenowl#1233 | MCP tools to edit items and manage categories |
| `fix/delete-category-by-name` | TomBursch/kitchenowl#1234 | delete a category by name |
| `fork/claude-md` | never | this file and `fork/` (fork-only tooling) |

- `deploy` = `origin/main` plus a `--no-ff` merge of every branch above. Every image and APK is built from `deploy`, and nothing is committed on it directly.
- Once upstream merges a PR, or `main` moves, rebuild `deploy`: `git checkout -B deploy origin/main`, then merge the live branches again (`rerere` is on). This needs a force push of `deploy`, which the user runs.
- Keep `CLAUDE.md` and `fork/` out of upstream PR branches. They live only on `fork/claude-md`.
- When a branch, PR or tag changes, update this table and the "Running a fork" section of the deployment README (see `CLAUDE.local.md`).

**Images.** The web and backend images are built from a `deploy` commit, using the GitHub URL as the build context, never this Windows checkout (`core.autocrlf=true` turns `entrypoint.sh` into CRLF):
`docker build --platform linux/amd64 -t <registry>/kitchenowl-web:meal-N "https://github.com/alexdrl/kitchenowl.git#<sha>:kitchenowl"` (`:backend` for the backend image). Always push a new tag: the pull policy is `IfNotPresent`. Web and backend tags are numbered independently.

**Android APK.** The build is `fork/build-apk.sh`, which runs in Docker; the private half has the exact command. It builds arm64 only and caps the Gradle heap at 3 GB: `gradle.properties` asks for 8 GB, more than the Docker Desktop VM has, and the first build was OOM-killed. Rules:
- The `applicationId` stays `com.tombursch.kitchenowl`. The fork replaces the official app, which has to be uninstalled first because its signature is different.
- APKs are signed with the fork's own release key, which is never in the repo (`key.properties` and `*.jks` are gitignored). Android refuses an update signed with any other key.
- Build number = upstream build × 100 + fork build, e.g. `0.8.1-fork.1` / `12601` on upstream `0.8.1+126`. The next upstream release then still counts as newer. `MIN_FRONTEND_VERSION` only compares against this number, so a large value is harmless.
- The checkout used by the build lives in the `ko-src` volume. Later builds are incremental and take about 5 minutes; the first one takes about 25.
- To try an APK on the x86_64 emulator, install it with `adb install --abi arm64-v8a`: the APK has `x86_64` plugin libraries but no `libflutter.so` for it. A widget layout may only use classes RemoteViews allows (no plain `View`); if one fails, the launcher shows "Can't load widget" and logcat names the class.
- `fork/build-apk.sh` also builds the Wear OS app (`kitchenowl-wear-<version>.apk`) when the ref has `android/wear/`. It shares the phone app's `applicationId` and key (the Data Layer requires both) and is sideloaded with `adb`: a phone APK that bundles a wear APK no longer installs it on the watch since Wear OS 2.0. Keep it out of the folder Obtainium reads, or Obtainium may pick it for the phone.
- `kitchenowl/fonts/Items.ttf` is built from the Icons8 icons, and their licence forbids redistribution. Do not publish the APK anywhere public.

## Commands

### Backend (run from `backend/`)

`pyproject.toml` requires Python >= 3.14 (`.python-version` is 3.14). The READMEs still say 3.12+, which is out of date.

```bash
uv sync                      # install deps (CI uses: uv sync --all-extras --dev)
uv run pre-commit install    # ruff lint + ruff-format hooks (migrations/ and tests/ are excluded)
uv run python -c "import nltk; nltk.download('averaged_perceptron_tagger_eng', download_dir='.venv/nltk_data')"
uv run flask db upgrade      # create/upgrade the SQLite DB (defaults to backend/database.db)
uv run wsgi.py               # dev server on localhost:5000 (add --host=0.0.0.0 to expose)
uv run manage.py             # interactive admin CLI (create users, run jobs, etc.); see --help
```

- Never start the server with `flask run`. Sockets only initialise properly through `wsgi.py` (gevent monkey-patching + `socketio.run`). The "WebSocket transport not available" warning in debug mode is expected and harmless.
- Tests: `uv run pytest`. For one file or test: `uv run pytest tests/api/test_api_recipe.py -k test_name`. CI runs `uv run pytest --cov=./ --cov-report=term`.
- Schema changes need an Alembic migration: `uv run flask db migrate -m "..."`, then review the generated file in `migrations/versions/`. The container entrypoint runs `flask db upgrade` on every start.

### Frontend (run from `kitchenowl/`)

```bash
flutter packages get
flutter run                  # -d <DEVICE_ID> to pick a target
flutter analyze              # CI gate
flutter test                 # single file: flutter test test/models/item.dart
```

Localisation is generated: `l10n.yaml` turns the ARB files in `lib/l10n/` into `lib/gen/l10n/` (gitignored, created by `flutter pub get` / `flutter gen-l10n`). Add new strings to `app_en.arb` only. The other languages come from Weblate.

### Docs (run from `docs/`)

`pip install -r requirements.txt`, then `zensical serve`.

## Backend architecture

- **`app/config.py` is the composition root.** It creates the Flask `app`, `db` (SQLAlchemy), `jwt`, `socketio`, `api_spec`, and either an APScheduler `scheduler` or a Celery `celery_app`. All configuration comes from environment variables read here (`DB_DRIVER`/`DB_*`, `STORAGE_PATH`, `MESSAGE_BROKER`, `OPEN_REGISTRATION`, OIDC/Google/Apple secrets, and so on). `app/__init__.py` just imports config → controllers → sockets → jobs → `api` (route registration), so import order matters.
- **Background jobs:** if `MESSAGE_BROKER` is unset, jobs in `app/jobs/jobs.py` run in-process via APScheduler. If it is set, they run as Celery tasks and Socket.IO uses the broker as its message queue (the multi-container setup in `docker-compose-rabbitmq.yml`). Jobs compute item ordering, item and recipe suggestions, shopping clustering, and cleanup.
- **Routing:** each `app/controller/<domain>/` package has `*_controller.py` and `schemas.py` and exports two blueprints: a global one (e.g. `recipe` → `/api/recipe/<id>`) and a household-scoped one (e.g. `recipeHousehold` → `/api/household/<household_id>/recipe`). All the wiring lives in `app/api/register_controller.py`; a new blueprint must be registered there and re-exported from `app/controller/__init__.py`. The MCP endpoint (`/mcp`) is only registered when `KITCHENOWL_MCP_ENABLED=true` or when testing. An OpenAPI spec is built from all routes at startup.
- **Endpoint decorator stack** (order matters): `@bp.route` → `@jwt_required()` → `@authorize_household(RequiredRights.MEMBER|ADMIN|ADMIN_OR_SELF)` → `@validate_args(MarshmallowSchema)`. `validate_args` loads query args for GET and the JSON body otherwise, and passes the result as the first positional `args` parameter.
- **Authorization:** household-scoped routes use `authorize_household` (needs a `household_id` URL kwarg). Global routes that load an object by ID must call `obj.checkAuthorized()` (from `DbModelAuthorizeMixin`) themselves. Search and list queries must filter by household membership or public visibility; access-control fixes have landed here before.
- **Models** (`app/models/`) extend `DbModelBase` (declarative base with a fixed constraint naming convention + timestamp mixin). They provide `.save()`, `.delete()`, `.obj_to_dict()`, `Model.find_by_id()`, `all_from_household()`, etc. Controllers return `jsonify(model.obj_to_dict())`. Raise errors from `app/errors` (`NotFoundRequest`, `InvalidUsage`, `ForbiddenRequest`, …) rather than returning error responses by hand.
- **Real-time sync:** controllers emit Socket.IO events after mutations, e.g. `socketio.emit("shoppinglist:add", ..., to="household/<id>")`. Clients join `household/<id>` rooms in `app/sockets/`. Socket handlers use `socket_jwt_required` / `validate_socket_args`.
- **Services** (`app/service/`) hold heavier logic: recipe scraping (`recipe-scrapers`), ingredient parsing, LLM recipe generation (`litellm`), import/export, mail, and balance recalculation.
- **Tests** (`tests/api/conftest.py`): the `client` fixture runs `db.create_all()` / `drop_all()` per test, and fixtures build up users, households and auth headers. Tests use the configured DB (SQLite by default).

## Frontend architecture

- **State:** `flutter_bloc` Cubits in `lib/cubits/` (one per page or feature), Equatable models in `lib/models/`, pages in `lib/pages/`, routing with `go_router` in `lib/router.dart`.
- **API layer:** `ApiService` (`lib/services/api/api_service.dart`) is a singleton holding the HTTP client, tokens and the Socket.IO connection. Each domain adds methods through a Dart `extension XxxApi on ApiService` in `lib/services/api/<domain>.dart`.
- **Offline support:** cubits don't call the API directly for syncable data. They wrap calls in `Transaction` subclasses (`lib/services/transactions/`) and run them through `TransactionHandler.runTransaction`. Each transaction has `runOnline()` and an offline fallback. Failed transactions are persisted (`TransactionStorage`) and replayed by `runOpenTransactions()` on reconnect (discarded after 3 days).

## Versioning / compatibility

Frontend and backend have to agree on versions in three places:
- `backend/app/config.py`: `BACKEND_VERSION` (matches the `+build` number in `kitchenowl/pubspec.yaml`) and `MIN_FRONTEND_VERSION`
- `kitchenowl/lib/config.dart`: `MIN_BACKEND_VERSION`, which the client checks against the `version` field returned by `/api/health/<token>` (the fixed token path is hardcoded on both sides)

Bump these together when the API changes in a breaking way.

## Contribution conventions

- Conventional commits (`fix:`, `feat:`, `chore:`, `docs(scope):` …), with branches named `<type>/<description>`. One PR per fix or feature, rebased and squashed.
- Open an issue before any new feature or API change.
