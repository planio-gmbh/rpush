module Rpush
  module Client
    module ActiveModel
      module Mozilla
        module Notification

          def self.included(base)
            base.instance_eval do
              validates :registration_ids, presence: true

              # TODO check how encryption affects payload size
              validates_with Rpush::Client::ActiveModel::PayloadDataSizeValidator, limit: 4096
              validates_with Rpush::Client::ActiveModel::RegistrationIdsCountValidator, limit: 1000
            end
          end

          # Default TTL in seconds (4 weeks)
          DEFAULT_TTL = 2419200
          def ttl
            expiry || DEFAULT_TTL
          end

          def each_endpoint
            registration_ids.each do |device|
              yield device[:endpoint], encrypt_payload(device[:key])
            end
          end

          def endpoints
            registration_ids.map{|device| device[:endpoint]}
          end

          def encrypt_payload(key)
            # TODO
          end

        end
      end
    end
  end
end

