# Sidekiq / ActiveRecord Query Cache memory leak

## Summary

In Sidekiq with Rails 5.0+, the ActiveRecord query cache is
automatically enabled during jobs, even if you remove the sidekiq
ActiveRecordCache middleware.

For jobs that batch operations over a large number of records, this will
very likely lead to large memory leaks, as the cache lives for the
duration of the job. This means that objects allocated to it can survive
enough GC cycles that they become uncollectible.

## Why is the query cache enabled even without the middleware?

In Rails 5, Sidekiq [runs its jobs via Rails' reloader
mechanism](https://github.com/mperham/sidekiq/blob/eca6acc0ce201125a45a5af75fd08c6ce985df5a/lib/sidekiq/processor.rb#L130-L141),
which, loosely speaking, defines a "unit of work".

However, the ActiveRecord query cache [registers itself with this
reloader/executor
system](https://github.com/rails/rails/blob/450889d1464431a04ef5c8a0f6a45b877aafe506/activerecord/lib/active_record/railtie.rb#L160-L164),
with the result that any task run via the reloader will have the query
cache [automatically
enabled](https://github.com/rails/rails/blob/450889d1464431a04ef5c8a0f6a45b877aafe506/activerecord/lib/active_record/query_cache.rb#L30-L34).

To prevent caching being performed you must explicitly disable it in
your jobs with `ActiveRecord::Base.uncached { ... }`.

## To reproduce

This is a repro app that runs [an example
job](app/workers/leak_worker.rb) that batches reads over 10k
ActiveRecord instances, performing no other work. Once finished it runs
several GC cycles, then dumps the heap and GC stats for inspection.

I've deliberately disabled the `ActiveRecordCache` middleware per
instructions on
[mperham/sidekiq#3718](https://github.com/mperham/sidekiq/pull/3718#issuecomment-357317801).

This was tested with the following versions installed:

* Rails 5.0.6
* Sidekiq 5.1.1
* Ruby 2.4.3

All GC tuning variables were left at their defaults.

I recommend running these commands with `RAILS_ENV=production` set in
your environment.

Setup:

    $ bundle install
    $ bundle exec rake db:create
    $ rake seed
    $ bundle exec sidekiq

In another terminal:

    # Run job via rails runner, without touching the query cache settings
    $ bundle exec rails runner "LeakWorker.new.perform('rails_runner')"
    OUTSIDE: cache not enabled
    INSIDE: cache not enabled

    # Run job via sidekiq, without touching the query cache settings
    $ bundle exec rails runner "LeakWorker.perform_async('sidekiq_cached')"
    [output in sidekiq terminal:
    OUTSIDE: cache enabled
    INSIDE: cache enabled]

    # Run job via sidekiq, explicitly disabling the query cache
    $ bundle exec rails runner "LeakWorker.perform_async('sidekiq_uncached', true)"
    [output in sidekiq terminal:
    OUTSIDE: cache enabled
    INSIDE: cache not enabled]

## Results

By inspecting the last line of the `gc.*.log` files you can see a marked
difference in object allocations at the end of the job:

                         heap_live_slots   old_objects
    -------------------+-----------------+-------------
    rails_runner       |       341k      |    338k
    sidekiq_uncached   |       348k      |    345k
    sidekiq_cached     |       388k      |    385k

About 40k more objects are still live at the end of the run with caching
enabled, and almost all of these are "old", i.e. have survived several
GC cycles (which AIUI makes them unlikely to be collected in future).

Using [jq](https://stedolan.github.io/jq/) on the heap dumps you can see
where these extra old objects were allocated (file paths trimmed for
clarity):

    $ grep uncollectible heap.rails_runner.log | jq '[.file, .line] | map(tostring) | join(":")' | sort | uniq -c | sort -n | tail -5
    200 "activerecord-5.0.6/lib/active_record/core.rb:135"
    200 "activerecord-5.0.6/lib/active_record/core.rb:546"
    205 "activerecord-5.0.6/lib/active_record/result.rb:123"
    625 "sqlite3-1.3.13/lib/sqlite3/statement.rb:108"
    335835 "null:null"

    $ grep uncollectible heap.sidekiq_uncached.log | jq '[.file, .line] | map(tostring) | join(":")' | sort | uniq -c | sort -n | tail -5
    202 "activerecord-5.0.6/lib/active_record/associations.rb:268"
    202 "activerecord-5.0.6/lib/active_record/core.rb:546"
    205 "activerecord-5.0.6/lib/active_record/attribute.rb:5"
    633 "sqlite3-1.3.13/lib/sqlite3/statement.rb:108"
    342990 "null:null"

    $ grep uncollectible heap.sidekiq_cached.log | jq '[.file, .line] | map(tostring) | join(":")' | sort | uniq -c | sort -n | tail -5
    205 "activerecord-5.0.6/lib/active_record/attribute.rb:5"
    206 "activerecord-5.0.6/lib/active_record/result.rb:123"
    261 "sqlite3-1.3.13/lib/sqlite3/statement.rb:137"
    40025 "sqlite3-1.3.13/lib/sqlite3/statement.rb:108"
    343065 "null:null"

This demonstrates that the extra old objects when the query cache is
enabled are almost entirely SQL query result objects. Tracing the object
references in the heap dump shows that these objects are all ultimately
held by the ActiveRecord query cache.
