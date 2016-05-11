module Rpush
  module Daemon
    module Mozilla

      class Failures
        attr_reader :temporary, :permanent

        PERMANENT_ERRORS = {
          404 => 'endpoint doesn\'t exist'
        }
        TEMPORARY_ERRORS = {
          429 => 'too many requests',
          500 => 'internal server error',
          503 => 'service unavailable'
        }

        def initialize(notification)
          @notification = notification
          @permanent = []
          @temporary = []
        end

        def all
          @temporary + @permanent
        end

        def any?
          @temporary.any? || @permanent.any?
        end

        def all_failed?
          @notification.endpoints.size == all.size
        end

        def add(endpoint, response)
          code = response.code.to_i
          failure = {
            endpoint: endpoint,
            code: code,
          }
          if msg = TEMPORARY_ERRORS[code]
            failure[:error] = msg
            failure[:retry_after] = determine_retry_after(response)
            @temporary << failure
          else
            failure[:error] = PERMANENT_ERRORS[code] || 'unknown error'
            @permanent << failure
          end
        end

        def description
          @description ||=
            describe(temporary, 'had temporary failures and will be retried') +
            describe(permanent, 'failed permanently')
        end

        private

        def describe(failures, message)
          ''.tap do |result|
            if failures.any?
              result << "#{failures.count} recipient(s) #{message}:\n"
              result << failures.map{|f| "#{f[:endpoint]} - #{f[:error]}"}.join("\n")
            end
          end
        end

        def determine_retry_after(response)
          unless t = Rpush::Daemon::RetryHeaderParser.parse(response.header['retry-after'])
            retries = @notification.retries || 0
            t = Time.now + 2**(retries + 1)
          end
          return t
        end
      end

      class Results
        attr_reader :successes, :failures

        def initialize(notification)
          @notification = notification
          @endpoints = notification.endpoints
          @successes = []
          @failures = Failures.new notification
        end

        def failures?
          @failures.any?
        end

        #
        # Response handling
        #
        # Remember which endpoints succeeded and which didn't
        # Schedules failed endpoints for retry but fails hard in case of
        # unrecoverable errors
        #
        def handle_response(endpoint, response)
          case response.code.to_i
          when 200, 201
            @successes << endpoint
          when 400
            fail Rpush::DeliveryError.new(400, @notification.id, 'Mozilla failed to process the request. Possibly an Rpush bug, please open an issue.')
          when 413
            fail Rpush::DeliveryError.new(413, @notification.id, 'Payload was too large (should be less than 4k)')
          else
            @failures.add endpoint, response
          end
        end
      end

      class Delivery < Rpush::Daemon::Delivery

        def initialize(app, http, notification, batch)
          @app = app
          @http = http
          @notification = notification
          @batch = batch
        end

        def perform
          results = Results.new @notification
          ttl = @notification.ttl
          @notification.each_endpoint do |endpoint, payload|
            response = do_post endpoint, payload, ttl
            results.handle_response endpoint, response
          end
          handle_results results
        rescue SocketError => error
          mark_retryable(@notification, Time.now + 10.seconds, error)
          raise
        rescue StandardError => error
          mark_failed(error)
          raise
        ensure
          @batch.notification_processed
        end

        protected


        #
        # Result processing
        # reschedule notifications to not permanently failed endpoints
        #

        def handle_results(results)
          handle_successes results.successes
          if results.failures?
            handle_failures results.failures
            fail Rpush::DeliveryError.new(nil,
                                          @notification.id,
                                          results.failures.description)
          else
            mark_delivered
            log_info "#{@notification.id} sent to #{@notification.endpoints.join(', ')}"
          end
        end

        def handle_successes(successes)
          successes.each do |endpoint|
            reflect :mozilla_delivered_to_recipient, @notification, endpoint
          end
        end

        def handle_failures(failures)
          if failures.temporary.any?
            new_notification = create_new_notification(failures.temporary)
            log_info "#{failure.temporary.count} endpoints will be retried as notification #{new_notification.id}."
          end

          failures.permanent.each do |failure|
            reflect(:mozilla_failed_to_recipient,
                    @notification, failure[:error], failure[:endpoint])
            if failure[:code] == 404
              reflect(:mozilla_invalid_endpoint,
                      @app, failure[:error], failure[:endpoint])
            end
          end
        end

        DEFAULT_DELAY = 10.minutes
        def create_new_notification(temporary_failures)
          endpoints = temporary_failures.map{|f| f[:endpoint]}
          deliver_after = temporary_failures.map do |failure|
            failure[:retry_after]
          end.compact.max || DEFAULT_DELAY.from_now

          attrs = {
            'app_id' => @notification.app_id,
            'collapse_key' => @notification.collapse_key,
            'delay_while_idle' => @notification.delay_while_idle,
            'retries' => ((@notification.retries || 0) + 1)
          }
          registration_ids = @notification.registration_ids.select do |device|
            endpoints.include? device[:endpoint]
          end
          Rpush::Daemon.store.create_mozilla_notification(attrs,
                                                          @notification.data,
                                                          registration_ids,
                                                          deliver_after,
                                                          @notification.app)
        end

        def do_post(endpoint, payload, ttl)
          uri = URI.parse endpoint
          headers = {
            'TTL' => ttl.to_s,
            'Content-Length' => '0'
          }
          body = nil
          if payload
            body = payload[:ciphertext]
            headers.update(
              'Content-Type' => 'application/octet-stream',
              'Content-Length' => body.length.to_s,
              'Encryption-Key' => payload[:local_public_key],
              'Encryption' => payload[:encryption],
              'Content-Encoding' => payload[:encoding]
            )
          end
          post = Net::HTTP::Post.new uri.path, headers
          post.body = body
          @http.request(uri, post)

        end

      end

    end
  end
end

