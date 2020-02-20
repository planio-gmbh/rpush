module Rpush
  module Client
    module ActiveModel
      module Webpush
        module Notification

          def self.included(base)
            base.instance_eval do
              validates :registration_ids, presence: true
              validates_with Rpush::Client::ActiveModel::PayloadDataSizeValidator, limit: 4096
              validates_with Rpush::Client::ActiveModel::RegistrationIdsCountValidator, limit: 1000
            end
          end

          # Default TTL in seconds (4 weeks)
          DEFAULT_TTL = 2419200
          def ttl
            expiry || DEFAULT_TTL
          end

          def subscriptions
            @subscriptions ||= registration_ids.map do |subsc|
              {
                endpoint: subsc[:endpoint],
                keys: subsc[:keys].symbolize_keys
              }
            end
          end

          def endpoints
            subscriptions.map{|s|s[:endpoint]}
          end

          def message
            if data
              title = data['title'].presence
              msg = data['message'].presence
              [title, msg].compact.join("\n")
            end
          end

        end
      end
    end
  end
end

