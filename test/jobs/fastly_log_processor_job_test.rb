require "test_helper"

class FastlyLogProcessorJobTest < ActiveJob::TestCase
  include SearchKickHelper

  setup do
    @sample_log = Rails.root.join("test", "sample_logs", "fastly-fake.log").read

    @sample_log_counts = {
      "bundler-1.10.6" => {
        Time.utc(2015, 11, 30, 21, 0, 0) => 2
      },
      "json-1.8.3-java" => {
        Time.utc(2015, 11, 30, 21, 0, 0) => 2
      },
      "json-1.8.3" => {
        Time.utc(2015, 11, 30, 21, 0, 0) => 1
      },
      "json-1.8.2" => {
        Time.utc(2015, 11, 29, 21, 0, 0) => 1,
        Time.utc(2015, 11, 30, 21, 0, 0) => 1,
        Time.utc(2015, 11, 30, 21, 30, 0) => 1,
        Time.utc(2015, 12, 30, 21, 0, 0) => 1
      },
      "no-such-gem-1.2.3" => {
        Time.utc(2015, 11, 30, 21, 0, 0) => 1
      }
    }
    @log_ticket = LogTicket.create!(backend: "s3", directory: "test-bucket", key: "fastly-fake.log", status: "pending")

    Aws.config[:s3] = {
      stub_responses: { get_object: { body: @sample_log } }
    }
    @processor = FastlyLogProcessor.new("test-bucket", "fastly-fake.log")
    @job = FastlyLogProcessorJob.new(bucket: "test-bucket", key: "fastly-fake.log")
    create(:gem_download)
    import_and_refresh
  end

  teardown do
    # Remove stubbed response
    Aws.config.delete(:s3)
  end

  context "#download_counts" do
    should "process file from s3" do
      assert_equal @sample_log_counts, @processor.download_counts(@log_ticket)
    end

    should "process file from local fs" do
      @log_ticket.update(backend: "local", directory: "test/sample_logs")

      assert_equal @sample_log_counts, @processor.download_counts(@log_ticket)
    end

    should "fail if dont find the file" do
      @log_ticket.update(backend: "local", directory: "foobar")
      assert_raises FastlyLogProcessor::LogFileNotFoundError do
        @processor.download_counts(@log_ticket)
      end
    end
  end

  context "with gem data" do
    setup do
      # Create some gems to match the values in the sample log
      bundler = create(:rubygem, name: "bundler")
      json = create(:rubygem, name: "json")

      create(:version, rubygem: bundler, number: "1.10.6")
      create(:version, rubygem: json, number: "1.8.3", platform: "java")
      create(:version, rubygem: json, number: "1.8.3")
      create(:version, rubygem: json, number: "1.8.2")

      import_and_refresh
    end

    context "#perform" do
      should "not double count" do
        json = Rubygem.find_by_name("json")

        assert_equal 0, GemDownload.count_for_rubygem(json.id)
        3.times { @job.perform_now }

        assert_equal 7, es_downloads(json.id)
        assert_equal 7, GemDownload.count_for_rubygem(json.id)
      end

      should "update download counts" do
        @job.perform_now
        @sample_log_counts
          .each do |name, expected_count|
          version = Version.find_by(full_name: name)
          next unless version
          count = GemDownload.find_by(rubygem_id: version.rubygem.id, version_id: version.id).count

          assert_equal expected_count.each_value.sum, count, "invalid value for #{name}"
        end

        json = Rubygem.find_by_name("json")

        assert_equal 7, GemDownload.count_for_rubygem(json.id)
        assert_equal 7, es_downloads(json.id)
        assert_equal "processed", @log_ticket.reload.status
      end

      should "update download counts in timescale" do
        requires_timescale

        @job.perform_now

        downloads = Download.all.map do |download|
          version = Version.find(download.version_id)
          { version.full_name => { download.occurred_at.utc => download.downloads } }
        end.reduce({}, &:deep_merge)

        assert_equal @sample_log_counts.except("no-such-gem-1.2.3"), downloads

        json = Rubygem.find_by_name("json")

        assert_equal 7, es_downloads(json.id)
        assert_equal "processed", @log_ticket.reload.status
      end

      context "all the timescale subclasses" do
        {
          Download::P1D => [
            { rubygem: "bundler", version: "1.10.6", downloads: 2, occurred_at: "2015-11-30 00:00:00 UTC" },
            { rubygem: "json", version: "1.8.3", downloads: 2, occurred_at: "2015-11-30 00:00:00 UTC" },
            { rubygem: "json", version: "1.8.3", downloads: 1, occurred_at: "2015-11-30 00:00:00 UTC" },
            { rubygem: "json", version: "1.8.2", downloads: 1, occurred_at: "2015-11-29 00:00:00 UTC" },
            { rubygem: "json", version: "1.8.2", downloads: 2, occurred_at: "2015-11-30 00:00:00 UTC" },
            { rubygem: "json", version: "1.8.2", downloads: 1, occurred_at: "2015-12-30 00:00:00 UTC" }
          ],
          Download::P1DAllVersion => [
            { rubygem: "bundler", downloads: 2, occurred_at: "2015-11-30 00:00:00 UTC" },
            { rubygem: "json", downloads: 1, occurred_at: "2015-11-29 00:00:00 UTC" },
            { rubygem: "json", downloads: 5, occurred_at: "2015-11-30 00:00:00 UTC" },
            { rubygem: "json", downloads: 1, occurred_at: "2015-12-30 00:00:00 UTC" }
          ],
          Download::P1DAllGem => [
            { downloads: 1, occurred_at: "2015-11-29 00:00:00 UTC" },
            { downloads: 7, occurred_at: "2015-11-30 00:00:00 UTC" },
            { downloads: 1, occurred_at: "2015-12-30 00:00:00 UTC" }
          ]
          # Download::P1M => [],
          # Download::P1MAllVersion => [],
          # Download::P1MAllGem => [],
          # Download::P1Y => [],
          # Download::P1YAllVersion => [],
          # Download::P1YAllGem => []
        }.each do |klass, expected|
          should "return the correct objects for #{klass}" do
            requires_timescale

            @job.perform_now

            includes = { # rubocop:disable Performance/CollectionLiteralInLoop
              rubygem: :name,
              version: :number
            }.slice(*klass.columns_hash.keys.map { _1.sub(/_id/, "").to_sym })
            order = %w[rubygem_id version_id occurred_at] & klass.columns_hash.keys # rubocop:disable Performance/CollectionLiteralInLoop
            actual = klass.order(order).includes(includes.keys)
            actual = actual.map do |download|
              includes.to_h { |k, v| [k, download.send(k).send(v)] }
                .merge(downloads: download.downloads, occurred_at: download.occurred_at.to_s)
            end

            assert_equal expected, actual
          end
        end
      end

      should "not run if already processed" do
        json = Rubygem.find_by_name("json")

        assert_equal 0, json.downloads
        assert_equal 0, es_downloads(json.id)
        @log_ticket.update(status: "processed")
        @job.perform_now

        assert_equal 0, es_downloads(json.id)
        assert_equal 0, json.downloads
      end

      should "not mark as processed if anything fails" do
        @processor.class.any_instance.stubs(:download_counts).raises("woops")

        assert_kind_of RuntimeError, @job.perform_now

        refute_equal "processed", @log_ticket.reload.status
        assert_equal "failed", @log_ticket.reload.status
      end

      should "not re-process if it failed" do
        @processor.class.any_instance.stubs(:download_counts).raises("woops")

        assert_kind_of RuntimeError, @job.perform_now

        @job.perform_now
        json = Rubygem.find_by_name("json")

        assert_equal 0, json.downloads
        assert_equal 0, es_downloads(json.id)
      end

      should "only process the right file" do
        ticket = LogTicket.create!(backend: "s3", directory: "test-bucket", key: "fastly-fake.2.log", status: "pending")

        @job.perform_now

        assert_equal "pending", ticket.reload.status
        assert_equal "processed", @log_ticket.reload.status
      end

      should "update the processed count" do
        @job.perform_now

        assert_equal 10, @log_ticket.reload.processed_count
      end

      should "update the total gem count" do
        assert_equal 0, GemDownload.total_count
        @job.perform_now

        assert_equal 9, GemDownload.total_count
      end
    end
  end
end
