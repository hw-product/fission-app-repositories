class RepositoriesController < ApplicationController

  before_action do
    @product = Product.find_by_internal_name(params[:namespace])
    unless(@product)
      raise 'Failed to determine product scoping!'
    end
    @source = Source.find_or_create_by_name('github')
    @account = [
      current_user.owned_accounts,
      current_user.managed_accounts
    ].flatten.uniq.detect do |act|
      act.id.to_i == params[:account_id].to_i &&
        act.source_id == @source.id
    end
    unless(@account)
      raise 'Failed to load requested account'
    end
  end

  def list
    respond_to do |format|
      format.js do
        flash[:error] = 'Unsupported request!'
        javascript_redirect_to packager_dashboard_path
      end
      format.html do
        begin
          @all_repositories = github(:user).org_repos(@account.name)
        rescue
          @all_repositories = github(:user).repos
        end
        @enabled_repositories = @product.repositories.where(:account_id => @account.id).all
      end
    end
  end

  def enable
    respond_to do |format|
      format.js do
        repo = github(:user).repo(params[:repository_id]).to_hash
        local_repo = @account.repositories_dataset.where(
          :remote_id => repo[:id]
        ).first
        unless(local_repo)
          local_repo = Repository.new(
            :account_id => @account.id,
            :remote_id => repo[:id]
          )
        end
        local_repo.name = repo[:full_name]
        local_repo.private = repo[:private]
        local_repo.url = repo[:git_url]
        local_repo.clone_url = repo[:clone_url]
        local_repo.save
        @product.add_repository(local_repo)
        enable_bot_access(repo[:full_name])
        configure_hooks(repo[:full_name])
      end
      format.html do
        flash[:error] = 'Unsupported request!'
        redirect_to packager_dashboard_path
      end
    end
  end

  def disable
    respond_to do |format|
      format.js do
        local_repo = @product.repositories_dataset.where(
          :remote_id => params[:repository_id]
        ).first
        if(local_repo)
          disable_bot_access(local_repo.name)
          unconfigure_hooks(local_repo.name)
          @product.remove_repository(local_repo)
          flash[:success] = "Repository has been disabled (#{local_repo.name})"
        else
          flash[:error] = 'Requested repository not enabled!'
        end
        javascript_redirect_to packager_dashboard
      end
      format.html do
        flash[:error] = 'Unsupported request!'
        redirect_to packager_dashboard_path
      end
    end
  end

  def reload
    respond_to do |format|
      format.js do
      end
      format.html do
        flash[:error] = 'Unsupported request!'
        redirect_to packager_dashboard_path
      end
    end
  end

  def validate
    respond_to do |format|
      format.js do
      end
      format.html do
        flash[:error] = 'Unsupported request!'
        redirect_to packager_dashboard_path
      end
    end
  end

  protected

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
    github(:user).add_team_membership(team.id, bot_username)
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
      h.config[:fission] == params[:namespace]
    end
    if(url)
      if(hook)
        unless(h.config[:url] == url)
          Rails.logger.info "Updating existing hook on repo #{repo} for #{params[:namespace]}"
          github(:user).edit_hook(
            repo, h.id, 'web', h.config.to_hash.merge(:url => url),
            :events => [:push],
            :active => true
          )
        end
      else
        Rails.logger.info "Creating new hook on repo #{repo} for #{params[:namespace]}"
        github(:user).create_hook(
          repo, 'web', {:url => url, :fission => params[:namespace], :content_type => 'json'},
          :events => [:push],
          :active => true
        )
      end
    else
      if(hook)
        Rails.logger.warn "No hook in register for #{params[:namespace]}. Removing existing hook on #{repo}!"
        github(:user).remote_hook(repo, hook.id)
      end
    end
  end

  def unconfigure_hooks(repo)
    hook = github(:user).hooks.detect do |h|
      h.config[:fission] == params[:namespace]
    end
    if(hook)
      Rails.logger.info "Removing hook from repo #{repo} for #{params[:namespace]}"
      github(:user).remote_hook(repo, hook.id)
    end
  end

  def commit_hook_url
    if(FissionApp::Respositories.hook_register(params[:namespace]))
      File.join(
        Rails.application.config.settings.get(:fission, :rest_endpoint_ssl),
        FissionApp::Respositories.hook_register(params[:namespace])
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

end
