class User < Sequel::Model(:user)
  include ASModel
  corresponds_to JSONModel(:user)

  set_model_scope :global

  @@unlisted_user_ids = nil


  def self.create_from_json(json, opts = {})
    # These users are part of the software
    if json.username == self.SEARCH_USERNAME || json.username == self.PUBLIC_USERNAME

      opts['agent_record_type'] = :agent_software
      opts['agent_record_id'] = 1
    else
      agent = JSONModel(:agent_person).from_hash(
                :publish => false,
                :names => [{
                  :primary_name => json.name,
                  :source => 'local',
                  :rules => 'local',
                  :name_order => 'direct',
                  :sort_name_auto_generate => true
              }])
      agent_obj = AgentPerson.create_from_json(agent, :system_generated => true)

      opts['agent_record_type'] = :agent_person
      opts['agent_record_id'] = agent_obj.id
    end

    super(json, opts)
  end


  def self.sequel_to_jsonmodel(obj, opts = {})
    json = super

    if obj.agent_record_id
      json['agent_record'] = {'ref' => uri_for(obj.agent_record_type, obj.agent_record_id)}
    end

    json
  end


  def self.broadcast_changes
    Notifications.notify("REFRESH_ACLS")
  end


  def self.ADMIN_USERNAME
    "admin"
  end


  def self.SEARCH_USERNAME
    AppConfig[:search_username]
  end


  def self.PUBLIC_USERNAME
    AppConfig[:public_username]
  end


  def self.STAFF_USERNAME
    AppConfig[:staff_username]
  end


  def self.unlisted_user_ids
    @@unlisted_user_ids if not @@unlisted_user_ids.nil?

    @@unlisted_user_ids = Array(User[:username => [User.SEARCH_USERNAME, User.PUBLIC_USERNAME, User.STAFF_USERNAME]]).collect {|user| user.id}

    @@unlisted_user_ids
  end


  def before_save
    super

    self.username = self.username.downcase
  end


  def validate
    validates_unique(:username,
                     :message => "Username '#{self.username}' is already in use")
  end


  def anonymous?
    false
  end


  def derived_permissions
    derived = {
      'update_archival_record' => ['update_subject_record',
                                   'update_agent_record',
                                   'update_vocabulary_record'],
      'delete_archival_record' => ['delete_subject_record',
                                   'delete_agent_record',
                                   'delete_vocabulary_record'],
      'merge_agents_and_subjects' => ['merge_subject_record',
                                      'merge_agent_record']
    }

    actual_permissions =
      self.class.db[:group].
           join(:group_user, :group_id => :id).
           join(:group_permission, :group_id => :group_id).
           join(:permission, :id => :permission_id).
           filter(:user_id => self.id,
                  :permission_code => derived.keys).
           select(:permission_code).map {|row| row[:permission_code]}


    actual_permissions.map {|p| derived[p]}.flatten
  end


  # True if a user has access to perform 'permission' in 'repo_id'
  def can?(permission_code, opts = {})
    if derived_permissions.include?(permission_code.to_s)
      return true
    end

    permission = Permission[:permission_code => permission_code.to_s]
    global_repo = Repository[:repo_code => Group.GLOBAL]

    raise "The permission '#{permission_code}' doesn't exist" if permission.nil?

    if permission[:level] == "repository" && self.class.active_repository.nil?
      raise("Problem when checking permission: #{permission.permission_code} " +
            "is a repository-level permission, but no repository was set")
    end

    !permission.nil? && ((self.class.db[:group].
                          join(:group_user, :group_id => :id).
                          join(:group_permission, :group_id => :group_id).
                          filter(:user_id => self.id,
                                 :permission_id => permission.id,
                                 :repo_id => [self.class.active_repository, global_repo.id].reject(&:nil?)).
                          count) >= 1)
  end


  def permissions
    result = {}

    derived = derived_permissions


    # Crikey...
    ds = self.class.db[:group].
      join(:group_user, :group_id => :id).
      join(:group_permission, :group_id => :group_id).
      join(:permission, :id => :permission_id).
      join(:repository, :id => :group__repo_id).
      filter(:user_id => self.id).
      distinct.
      select(Sequel.qualify(:repository, :id).as(:repo_id), :permission_code)

    ds.each do |row|
      repository_uri = JSONModel(:repository).uri_for(row[:repo_id])
      result[repository_uri] ||= derived.clone
      result[repository_uri] << row[:permission_code]
    end

    result
  end


  def add_to_groups(groups, delete_all_for_repo_id = false)

    if delete_all_for_repo_id
      groups_ids = self.class.db[:group].where(:repo_id => delete_all_for_repo_id).select(:id)
      self.class.db[:group_user].where(:user_id => self.id, :group_id => groups_ids).delete
    end

    Array(groups).each do |group|
      group.add_user(self)
    end

    self.class.broadcast_changes
  end


  def delete
    raise AccessDeniedException.new("Can't delete system user") if self.is_system_user == 1

    DBAuth.delete_user(self.username)

    self.remove_all_group

    super

    if self.agent_record_id
      AgentPerson[self.agent_record_id].delete
    end
  end


  many_to_many :group, :join_table => "group_user"
end