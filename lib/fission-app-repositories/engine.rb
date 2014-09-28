module FissionApp
  module Repositories
    class Engine < ::Rails::Engine
    end

    def self.repositories_routes
      lambda do |namespace|
        get "#{namespace}/:account_id/repositories", :as => "#{namespace}_repositories", :to => 'repositories#list', :defaults => {:namespace => namespace}
        post "#{namespace}/:account_id/repositories/:repository_id", :as => "#{namespace}_repository_enable", :to => 'repositories#enable', :defaults => {:namespace => namespace}
        delete "#{namespace}/:account_id/repositories/:repository_id", :as => "#{namespace}_repository_disable", :to => 'repositories#disable', :defaults => {:namespace => namespace}
        get "#{namespace}/:account_id/repositories/validate/:repository_id", :as => "#{namespace}_repository_validate", :to => 'repositories#validate', :defaults => {:namespace => namespace}
        get "#{namespace}/:account_id/repositories/reload", :as => "#{namespace}_repositories_reload", :to => 'repositories#reload', :defaults => {:namespace => namespace}
      end
    end

  end
end
