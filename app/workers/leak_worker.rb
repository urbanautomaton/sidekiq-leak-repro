require 'objspace'

class LeakWorker
  include Sidekiq::Worker

  def perform(label, disable_cache=false)
    puts "OUTSIDE: #{caching}"
    disable_cache(disable_cache) do
      puts "INSIDE: #{caching}"
      ObjectSpace.trace_object_allocations do
        User.find_in_batches(batch_size: 200) { nil }

        5.times { GC.start }
        File.open("gc.#{label}.log", 'w') { |gc| gc.puts(GC.stat.to_json) }
        File.open("heap.#{label}.log", 'w') { |heap| ObjectSpace.dump_all(output: heap) }
      end
    end
  end

  private

  def disable_cache(disable, &block)
    if disable
      ActiveRecord::Base.uncached(&block)
    else
      yield
    end
  end

  def caching
    if ActiveRecord::Base.connection.query_cache_enabled
      "cache enabled"
    else
      "cache not enabled"
    end
  end
end
