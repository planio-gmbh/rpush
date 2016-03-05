module Rpush
  module Daemon
    module Mozilla
      class Delivery < Rpush::Daemon::Delivery

        def initialize(app, http, notification, batch)
          @app = app
          @http = http
          @notification = notification
          @batch = batch
          @successes = []
          @failures = {}
        end

        def perform
          ttl = @notification.ttl
          @notification.each_endpoint do |endpoint, payload|
            response = do_post endpoint, payload, ttl
            handle_response endpoint, response
          end
          handle_results
        rescue StandardError => error
          mark_failed(error)
          raise
        ensure
          @batch.notification_processed
        end

        protected

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
          when 404
            msg = "endpoint doesn't exist"
            permanent_failure endpoint, msg
            log_warn "Mozilla responded with 404 - #{msg}"
          when 413
            fail Rpush::DeliveryError.new(413, @notification.id, 'Payload was too large (should be less than 4k)')
          when 429
            mark_for_retry endpoint, response
            log_warn "Mozilla responded with a Too Many Requests Error. " + retry_message(endpoint)
          when 500
            mark_for_retry endpoint, response
            log_warn "Mozilla responded with an Internal Error. " + retry_message(endpoint)
          when 503
            mark_for_retry endpoint, response
            log_warn "Mozilla responded with an Service Unavailable Error. " + retry_message(endpoint)
          else
            msg = "#{response.code} #{response.message}"
            permanent_failure endpoint, msg
            log_warn "Mozilla responded with an unknown error: #{msg}"
          end
        end

        def mark_for_retry(endpoint, response)
          (@failures[:retry] ||= []) << [endpoint, deliver_after_header(response)]
        end

        def permanent_failure(endpoint, message)
          (@failures[:failed] ||= []) << [endpoint, message]
        end


        #
        # Result processing
        # reschedule notifications to not permanently failed endpoints
        #

        def handle_results
          handle_successes @successes
          if @failures.any?
            handle_failures @failures
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
          message = ''
          retrials = failures[:retry] || []
          if retrials.count == @notification.registration_ids.size
            retry_delivery(@notification, response)
            message = "All endpoints failed. #{retry_message}"
            log_warn message
          else
            if retrials.any?
              new_notification = create_new_notification(retrials)
              message = "Endpoints #{retrials.join(', ')} will be retried as notification #{new_notification.id}."
            end
            if error = handle_errors(failures[:failed])
              message << "\n" unless message.blank?
              message << error
            end
            fail Rpush::DeliveryError.new(nil, @notification.id, message)
          end
        end

        def handle_errors(failed_endpoints)
          if failed_endpoints and failed_endpoints.any?
            failed_endpoints.each do |failed_endpoint|
              reflect(:mozilla_failed_to_recipient, @notification, failed_endpoint)
            end
            return failed_endpoints.join("\n")
          end
        end

        DEFAULT_DELAY = 10.minutes

        def create_new_notification(failed_endpoints)
          endpoints, deliver_afters = failed_endpoints.transpose
          deliver_after = deliver_afters.compact.max || DEFAULT_DELAY.from_now
          attrs = {
            'app_id' => @notification.app_id,
            'collapse_key' => @notification.collapse_key,
            'delay_while_idle' => @notification.delay_while_idle
          }
          registration_ids = @notification.registration_ids.select{|device| endpoints.include? device[:endpoint]}
          Rpush::Daemon.store.create_mozilla_notification(attrs,
                                                          @notification.data,
                                                          registration_ids,
                                                          deliver_after,
                                                          @notification.app)
        end

        # retry delivery to all endpoints
        def retry_delivery
          if time = deliver_after_header
            mark_retryable(@notification, time)
          else
            mark_retryable_exponential(@notification)
          end
        end

        def retry_message(endpoint = nil)
          "Notification #{@notification.id}#{' to '+endpoint if endpoint} will be retried#{' after '+ @retry_delivery_after.strftime('%Y-%m-%d %H:%M:%S') if @retry_delivery_after} (retry #{@notification.retries})."
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

        rescue SocketError => error
          mark_retryable(endpoint, Time.now + 10.seconds, error)
          raise
        end

        def deliver_after_header(response)
          Rpush::Daemon::RetryHeaderParser.parse(response.header['retry-after'])
        end

      end

    end
  end
end

