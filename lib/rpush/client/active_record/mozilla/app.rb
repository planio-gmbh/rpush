module Rpush
  module Client
    module ActiveRecord
      module Mozilla
        class App < Rpush::Client::ActiveRecord::App
          include Rpush::Client::ActiveModel::Mozilla::App
        end
      end
    end
  end
end


