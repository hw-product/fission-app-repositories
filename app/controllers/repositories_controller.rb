class RepositoriesController < ApplicationController

  before_action :set_product

  def list
    respond_to do |format|
      format.js do
        flash[:error] = 'Unsupported request!'
        javascript_redirect_to repository_listing_endpoint
      end
      format.html do
        begin
          @all_repositories = github(:user).org_repos(@account.name)
        rescue
          @all_repositories = github(:user).repos
        end
        @all_repositories = @all_repositories.map do |remote_repo|
          [remote_repo.full_name, remote_repo.id]
        end.sort_by(&:first)
        @enabled_repositories = @base.repositories_dataset.where(:account_id => @account.id).all.map do |local_repo|
          [local_repo.name, local_repo.id]
        end.sort_by(&:first)
        @disabled_repositories = @all_repositories.dup
        @disabled_repositories.delete_if do |r|
          @enabled_repositories.map(&:first).include?(r.first)
        end
      end
    end
  end

  def enable
    respond_to do |format|
      format.js do
        repo = github(:user).repo(params[:repository_name]).to_hash
        local_repo = @account.repositories_dataset.where(
          :remote_id => repo[:id].to_s
        ).first
        unless(local_repo)
          local_repo = Repository.new(
            :account_id => @account.id,
            :remote_id => repo[:id].to_s
          )
        end
        local_repo.name = repo[:full_name]
        local_repo.private = repo[:private]
        local_repo.url = repo[:git_url]
        local_repo.clone_url = repo[:clone_url]
        local_repo.save
        @base.add_repository(local_repo)
        enable_bot_access(repo[:full_name])
        configure_hooks(repo[:full_name])
        javascript_redirect_to repository_listing_endpoint
      end
      format.html do
        flash[:error] = 'Unsupported request!'
        redirect_to repository_listing_endpoint
      end
    end
  end

  def disable
    respond_to do |format|
      format.js do
        local_repo = @base.repositories_dataset.where(
          :id => params[:repository_id]
        ).first
        if(local_repo)
          disable_bot_access(local_repo.name)
          unconfigure_hooks(local_repo.name)
          @base.remove_repository(local_repo)
          flash[:success] = "Repository has been disabled (#{local_repo.name})"
        else
          flash[:error] = 'Requested repository not enabled!'
        end
        javascript_redirect_to repository_listing_endpoint
      end
      format.html do
        flash[:error] = 'Unsupported request!'
        redirect_to repository_listing_endpoint
      end
    end
  end

  def reload
    respond_to do |format|
      format.js do
      end
      format.html do
        flash[:error] = 'Unsupported request!'
        redirect_to repository_listing_endpoint
      end
    end
  end

  def validate
    respond_to do |format|
      format.js do
      end
      format.html do
        flash[:error] = 'Unsupported request!'
        redirect_to repository_listing_endpoint
      end
    end
  end

  protected

  def repository_listing_endpoint
    send("#{@namespace}_repositories_path")
  end

  def bot_team
    team = github(:user).org_teams()
  end

  def enable_bot_access(repo)
    if(github(:user).user.login == @account.name)
      collaborator_enable(repo)
    else
      team = org_team
      org_add_membership(team)
      org_add_repository(repo, team)
    end
  end

  def disable_bot_access(repo)
    if(github(:user).user.login == @account.name)
      collaborator_disable(repo)
    else
      team = org_team
      org_remove_repository(repo, team)
      org_remove_team(team)
    end
  end

  def org_remove_team(team)
    if(github(:user).team_repositories(team.id).count < 1)
      github(:user).delete_team(team.id)
    end
  end

  def org_remove_repository(repo, team)
    github(:user).remove_team_repository(team.id, repo)
  end

  def bot_username
    Rails.application.config.settings.fetch(:github, :username, 'd2obot')
  end

  def org_team_name
    Rails.application.config.settings.fetch(:github, :team_name, 'd2obot')
  end

  def org_team
    team = github(:user).org_teams(@account.name).detect do |t|
      t.name == org_team_name
    end
    unless(team)
      github(:user).create_team(
        @account.name,
        :name => org_team_name,
        :permission => 'push'
      )
    else
      team
    end
  end

  def org_add_repository(repo, team)
    github(:user).add_team_repository(team.id, repo)
  end

  def org_add_membership(team)
    team_add_result = github(:user).add_team_membership(team.id, bot_username)
    if(team_add_result[:state] != 'active')
      github(:bot).update_organization_membership(@account.name, :state => 'active')
    end
  end

  def collaborator_enable(repo)
    github(:user).add_collaborator(repo, bot_username)
  end

  def collaborator_disable(repo)
    github(:user).remove_collaborator(repo, bot_username)
  end

  def configure_hooks(repo)
    url = commit_hook_url
    hook = github(:user).hooks(repo).detect do |h|
      h.config[:fission] == hook_identifier
    end

    if(url)
      if(hook)
        unless(hook.config[:url] == url)
          Rails.logger.info "Updating existing hook on repo #{repo} for #{@base.name}"
          github(:user).edit_hook(
            repo, hook.id, 'web', hook.config.to_hash.merge(:url => url),
            :events => ['*'],
            :active => true
          )
        end
      else
        Rails.logger.info "Creating new hook on repo #{repo} for #{@base.name}"
        github(:user).create_hook(
          repo, 'web', {:url => url, :fission => hook_identifier, :content_type => 'json'},
          :events => ['*'],
          :active => true
        )
      end
    else
      if(hook)
        Rails.logger.warn "No hook in register for #{@base.name}. Removing existing hook on #{repo}!"
        github(:user).remote_hook(repo, hook.id)
      end
    end
  end

  def unconfigure_hooks(repo)
    hook = github(:user).hooks(repo).detect do |h|
      h.config[:fission] == hook_identifier
    end
    if(hook)
      Rails.logger.info "Removing hook from repo #{repo} for #{@base.name}"
      github(:user).remove_hook(repo, hook.id)
    else
      Rails.logger.warn "Failed to locate repo hook for removal! Repository: #{repo} Namespace: #{@base.name}"
    end
  end

  def commit_hook_url
    if(FissionApp::Repositories.hook_register.get(params[:namespace]))
      File.join(
        Rails.application.config.settings.get(:fission, :rest_endpoint_ssl),
        FissionApp::Repositories.hook_register.get(params[:namespace])
      )
    end
  end

  def load_account_repositories(force=false)
    unless(current_user.session.get(:github_repos, @account.name))
      repos = []
      count = 0
      result = nil
      if(github(:user).user.login == @account.name)
        until((result = c.repos(:per_page => 50, :page => count += 1)).count < 50)
          repos += result
        end
        repos += result
      else
        until((result = c.org_repos(@account.name, :per_page => 50, :page => count += 1)).count < 50)
          repos += result
        end
        repos += result
      end
      current_user.session.set(:github_repos, @account.name, repos)
    end
    current_user.session.get(:github_repos, @account.name)
  end

  def hook_identifier
    if(@hook_identifier.blank?)
      raise 'No hook identifier has been defined!'
    end
    if(Rails.env.to_s == 'production')
      @hook_identifier.to_s
    else
      "#{ENV.fetch('USER', 'testing')}-#{@hook_identifier}"
    end
  end

  def set_product
    @product = Product.find_by_internal_name(params[:namespace])
    unless(@product)
      raise 'Failed to determine product scoping!'
    end
    @source = Source.find_or_create(:name => 'github')
    unless(@account)
      raise 'Failed to load requested account'
    end
    @base = @product
    @namespace = @product.internal_name
    @hook_identifier = @namespace
  end

end
