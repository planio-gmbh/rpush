module Rpush
  module Client
    module ActiveRecord
      module Mozilla
        class Notification < Rpush::Client::ActiveRecord::Notification
          include Rpush::Client::ActiveModel::Mozilla::Notification
        end
      end
    end
  end
end

