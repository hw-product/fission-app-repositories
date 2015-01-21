module FissionApp
  module Repositories
    class Engine < ::Rails::Engine
    end

    # @return [Smash]
    def self.hook_register
      @hook_register ||= Smash.new
    end

    # Provide proc for dynamic route injections. Register
    # optional hook path.
    #
    # @param hook_path [String] path for commit hook
    # @return [Proc] block for injecting routes
    def self.repositories_routes(hook_path=nil)
      Proc.new do |namespace, hook_path=nil|
        if(hook_path)
          FissionApp::Repositories.hook_register[namespace] = hook_path
        end
        get(
          "#{namespace}/repositories",
          :as => "#{namespace}_repositories",
          :to => 'repositories#list',
          :defaults => {
            :namespace => namespace
          }
        )
        post(
          "#{namespace}/repositories/:repository_id",
          :as => "#{namespace}_repository_enable",
          :to => 'repositories#enable',
          :defaults => {
            :namespace => namespace
          }
        )
        delete(
          "#{namespace}/repositories/:repository_id",
          :as => "#{namespace}_repository_disable",
          :to => 'repositories#disable',
          :defaults => {
            :namespace => namespace
          }
        )
        get(
          "#{namespace}/repositories/validate/:repository_id",
          :as => "#{namespace}_repository_validate",
          :to => 'repositories#validate',
          :defaults => {
            :namespace => namespace
          }
        )
        get(
          "#{namespace}/repositories/reload",
          :as => "#{namespace}_repositories_reload",
          :to => 'repositories#reload',
          :defaults => {
            :namespace => namespace
          }
        )
      end
    end

  end
end
