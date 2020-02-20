module Rpush
  module Client
    module ActiveModel
      module Webpush
        module App
          def service_name
            'webpush'
          end

          def vapid
            unless defined?(@vapid)
              @vapid = parse_vapid.symbolize_keys
            end
            @vapid
          end

          private

          # we store they VAPID key pair in the certificate field.
          def parse_vapid
            JSON.parse certificate if certificate
          end
        end
      end
    end
  end
end

