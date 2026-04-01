# tasks for out of band user management
#
unless Rake::Task.task_defined?(:ensure_config)
  task :ensure_config do
    require 'bundler/setup'
    # Configure the process for the current cron configuration.
    require_relative '../lib/ncbo_cron'
    config_exists = File.exist?(File.expand_path('../../config/config.rb', __FILE__))
    abort('Please create a config/config.rb file using the config/config.rb.sample as a template') unless config_exists
    require_relative '../config/config'
  end
end

desc 'User Administration'
namespace :user do
  require 'securerandom'

  desc 'Add administrator role to the user'
  task :adminify, [:username] => :ensure_config do |t, args|
    username = args.username
    user = LinkedData::Models::User.find(username).first
    abort("FAILED: The user #{args.username} does not exist") if user.nil?
    user.bring_remaining
    user.valid?
    # Get an instance of the administrator role
    role = LinkedData::Models::Users::Role.find('ADMINISTRATOR').first.bring_remaining
    # Sanity check that you have a valid role
    role.valid?
    # Add the administrative role to the user's list of roles
    user_roles = user.role
    user_roles = user_roles.dup
    user_roles << role
    user.role = user_roles
    # Sanity check to make sure role was added properly
    user.valid?
    user.save
  end

  desc 'Reset all roles to LIBRARIAN for the user'
  task :resetroles, [:username] => :ensure_config do |t, args|
    username = args.username
    user = LinkedData::Models::User.find(username).first
    abort("FAILED: user #{args.username} does not exist") if user.nil?
    user.bring_remaining
    user.valid?
    # Get an instance of the administrator role
    role = LinkedData::Models::Users::Role.find('LIBRARIAN').first.bring_remaining
    # Sanity check that you have a valid role
    role.valid?
    user.role = [role]
    # Sanity check to make sure role was added properly
    user.valid?
    user.save
  end

  desc 'Reset password to a random value for the user'
  task :resetpassword, [:username] => :ensure_config do |t, args|
    username = args.username
    newpassword = SecureRandom.base64(15)
    user = LinkedData::Models::User.find(username).first
    abort("FAILED: user #{args.username} does not exist") if user.nil?
    user.bring_remaining
    user.password = newpassword
    user.valid?
    user.save
    puts "password for the user #{username} is reset to #{newpassword}"
  end

  desc 'Create a new user'
  task :create, [:username, :email, :password] => :ensure_config do |t, args|
    args.with_defaults(password: nil)
    password = args.password
    args.password.nil? && password = SecureRandom.base64(15)
    checkuser = LinkedData::Models::User.find(args.username).first
    abort("FAILED: The user #{args.username} already exists") unless checkuser.nil?
    user = LinkedData::Models::User.new
    role = LinkedData::Models::Users::Role.find('LIBRARIAN').first.bring_remaining
    user.username = args.username
    user.email = args.email
    user.password = password
    user.role = [role]
    if user.valid?
      user.save
    else
      puts 'FAILED: create new user'
    end
  end

  namespace :apikey do
    desc 'get APIKEY for the user'
    task :get, [:username] => :ensure_config do |t, args|
      user = LinkedData::Models::User.find(args.username).first
      abort("FAILED: The user #{args.username} does not exist") if user.nil?
      user.bring_remaining
      puts user.apikey
    end
    desc 'reset APIKEY for the user to random value or to specified value if API key is provided'
    task :reset, [:username, :apikey] => :ensure_config do |t, args|
      user = LinkedData::Models::User.find(args.username).first
      abort("FAILED: The user #{args.username} does not exist") if user.nil?
      user.bring_remaining
      apikey = if args.apikey.nil?
                 SecureRandom.uuid
               else
                 args.apikey
               end
      user.apikey = apikey
      if user.valid?
        user.save
      else
        puts 'FAILED: reset api key'
      end
    end
  end

  desc 'Show all artifacts administrered by the user'
  task :artifacts, [:username] => :ensure_config do |t, args|
    # most of the code is copied from /bin/ncbo_spam_deletion
    username = args.username

    user = LinkedData::Models::User.find(username).include(:username).first
    abort("FAILED: user #{args.username} does not exist") if user.nil?
    # next if user.nil?

    projects = LinkedData::Models::Project.where(creator: user.id).include(:acronym).all
    notes = LinkedData::Models::Note.where(creator: user.id).include(:subject).all
    reviews = LinkedData::Models::Review.where(creator: user.id).include(:body).all
    ontologies = LinkedData::Models::Ontology.where(administeredBy: user.id).include(:acronym).all
    prov_classes = LinkedData::Models::ProvisionalClass.where(creator: user.id).include(:label).all

    puts "User #{user.username} artifacts:"
    puts '--------------------------------'

    pr = projects.map {|p| p.acronym}.join(", ")
    pr = "none" if pr.empty?
    puts ("Projects: #{pr}")
    n = notes.map {|n| n.subject}.join(", ")
    n = "none" if n.empty?
    puts ("Notes: #{n}")

    rv = reviews.map {|r| r.body}.join(", ")
    rv = "none" if rv.empty?
    puts ("Reviews: #{rv}")

    ont = ontologies.map {|o| o.acronym}.join(", ")
    ont = "none" if ont.empty?
    puts ("Ontologies: #{ont}")

    pc = prov_classes.map {|p| p.label}.join(", ")
    pc = "none" if pc.empty?
    puts ("Provisional Classes: #{pc}")
    puts ("--------------------------------\n")
  end
end
