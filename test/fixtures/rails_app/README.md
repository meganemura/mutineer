# Rails dogfood fixture app

A deliberately tiny but **real** Rails app used to exercise Mutineer's `--rails`
boot mode against the genuine article: a booted `config/environment`, Zeitwerk
autoloading, ActiveRecord on SQLite, and transactional fixtures. The gem's own
test suite is intentionally Rails-free; this app fills that gap.

It has its **own isolated bundle** (`Gemfile` here) so Rails never leaks into
Mutineer's zero-dependency gem bundle. Only the dedicated `rails-integration` CI
job — and developers who opt in — install it.

## Run it locally

```sh
cd test/fixtures/rails_app
bundle install
bin/dogfood          # asserts the strong/weak/baseline gates return the right exit codes
```

Or drive Mutineer directly:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails            # 100% — exit 0
RAILS_ENV=test bundle exec mutineer run app/models/order.rb \
  --test test/models/order_weak_test.rb --rails --threshold 90                 # survivors — exit 1
```

`Order` (`app/models/order.rb`) is pure business logic so every mutant's fate is
decided solely by the test assertions. `order_test.rb` is a strong suite (kills
everything); `order_weak_test.rb` covers the same lines but asserts almost
nothing (the "coverage theater" Mutineer is built to expose).

## Run it on PostgreSQL

`config/database.yml` uses PostgreSQL when `MUTINEER_FIXTURE_DB=postgres` is set.
The database name ends in `TEST_ENV_NUMBER`, the same convention the
`parallel_tests` gem uses, so each `--daemon --jobs N` worker gets its own
database. Worker 0 uses `mutineer_app_test`, the next worker `mutineer_app_test2`,
and so on. `--jobs` defaults to the number of CPUs, so a run needs one database
per worker: pass `--jobs N` and create N databases. `bin/dogfood-postgres` passes
`--jobs 2`, so it needs the first two. Create them first; the suite loads the
schema itself.

```sh
export PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres
export PGGSSENCMODE=disable   # macOS only; see the README
createdb mutineer_app_test && createdb mutineer_app_test2
bin/dogfood-postgres
```
