class ShardReader

  def initialize(stream_name:,
                 tracker_prefix:,
                 shard_id:,
                 batch_size:,
                 logger:,
                 client:)
    @stream_name = stream_name
    @tracker_prefix = tracker_prefix
    @shard_id = shard_id
    @batch_size = batch_size
    @logger = logger.dup.tap { |l| l.progname = "ShardReader[#{@stream_name},#{@shard_id}]" }
    @client = client
    @stop_processing = false

    key_prefix = [ @stream_name,
                   @tracker_prefix,
                   shard_id ].compact.join('-')
    @tracker = SequenceNumberTracker.new(key_prefix: key_prefix)
  end

  def run(&block)
    @thread = Thread.new do
      @logger.info "Spawned shard reader thread"
      loop do
        break if @stop_processing
        begin
          iterator_opts = { stream_name: @stream_name,
                            shard_id: @shard_id }
          if seq = @tracker.last_sequence_number
            iterator_opts[:shard_iterator_type] = 'AFTER_SEQUENCE_NUMBER'
            iterator_opts[:starting_sequence_number] = seq
          else
            iterator_opts[:shard_iterator_type] = 'TRIM_HORIZON'
          end
          @logger.info "Getting shard iterator for seq #{seq}"

          resp = @client.get_shard_iterator(iterator_opts)
          shard_iterator = resp.shard_iterator
          exit_thread if shard_iterator.nil?
          last_fetch = Time.now

          # Iterate!
          loop do
            break if @stop_processing
            # Back off for 1 sec if we're fetching too quickly
            sleep 1 if (Time.now - last_fetch) < 1.0
            resp = @client.get_records(shard_iterator: shard_iterator,
                                       limit: @batch_size)
            @logger.info "Got batch of #{resp.records.size} records, #{resp.millis_behind_latest}ms behind latest"
            last_fetch = Time.now

            resp.records.each do |record|
              process_record(record, resp, &block)
            end
            shard_iterator = resp.next_shard_iterator
            exit_thread if shard_iterator.nil?
          end

        rescue Aws::Kinesis::Errors::ExpiredIteratorException
          @logger.debug "Iterator expired! Fetching a new one."
        end
      end
      @logger.info "Shard reader thread exiting"
    end
  end

  def join
    @thread.join if @thread
  end

  def stop_processing!
    @stop_processing = true
  end

  private

  def exit_thread
    @logger.info "A shard split or merge has occured and this shard is now in a CLOSED state.
                            All available data records have been read. Exiting!"
    @thread.exit
  end

  def process_record(record, resp, &block)
    instrument_opts = {
      stream_name: @stream_name,
      prefix: @tracker_prefix,
      shard_id: @shard_id,
      ms_behind: resp.millis_behind_latest
    }
    ActiveSupport::Notifications.instrument('stream_reader.process_record',
                                            instrument_opts) do
      AvroParser.new(record.data, record.sequence_number, @shard_id).each_with_schema_name(&block)
      @tracker.last_sequence_number = record.sequence_number
    end
  end
end
