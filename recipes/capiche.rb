namespace :capiche do
  namespace :deploy do
    desc "Change the application's file permissions before restart"
    task :chmod_application, :roles => :app do
      puts "Chmoddin' the application for world readable"
      run "chmod -R 755 #{current_release}"
    end
    
    desc "Links up all of the shared files and directories in an Apis Networks way"
    task :create_relative_symlinks, :roles => :app do
      puts "Creating relative symlinks"
      run <<-CMD
        cd #{deploy_to}/current &&
        rm -rf #{release_path}/public/images/shared &&
        ln -nfs ../../../../../#{application}/shared/images/shared public/images/shared &&
        ln -nfs ../../../../#{application}/shared/config/database.yml config/database.yml
      CMD

      # Custom file uploads from the user
      unless uploads_custom_files.nil?
        dir = custom_dir || "custom"
        run <<-CMD
          cd #{deploy_to}/current/public &&
          rm -rf #{dir} &&
          ln -nfs ../../../../#{application}/shared/#{dir}
        CMD
      end
    end
    
    desc "Cleans out large template files used by our developers, not for production"
    task :scrap_large_files, :roles => :app do
      puts "Removing Carbon Media asset folders (psd/flash/ai)"
      run <<-CMD
        cd #{deploy_to}/current &&
        rm -rf assets/
      CMD
    end
  
    desc "Creates a symbolic link to the shared database.yml file"
    task :symlink_db_file, :roles => :app do
      run <<-CMD
        cd #{deploy_to}/current &&
        ln -nfs ../../../shared/config/database.yml releases/#{release_name}/config/database.yml
      CMD
    end
    
    desc "Chmod's the app and symlinks all necessary shared directories"
    task :prep_for_restart, :roles => :app do
      chmod_application
      create_relative_symlinks
    end
    
    desc "Runs a few cleanup command, application status poll moved to a deploy.rb after filter"
    task :post_live, :roles => :app do
      scrap_large_files
      puts "Done."
    end
    
  end
  
  namespace :setup do
      
    desc "Creates/Recreates a dynamic database.yml file based on the supplied user/pass"
    task :create_database_file, :roles => :app do
      template = File.read( "vendor/plugins/capiche/recipes/templates/database.template" )
      result   = ERB.new( template ).result( binding )
      put( result, "#{shared_path}/config/database.yml", { :mode => 0755, :via => :scp } )
    end
    
    desc "Runs a mkdir for a few more helpful directories to share between releases"
    task :create_extra_shared_directories, :roles => :app do
      run <<-CMD
        mkdir -p -m 775 #{shared_path}/images/shared &&
        mkdir -p -m 775 #{shared_path}/config
      CMD
      
      unless uploads_custom_files.nil?
        dir = custom_dir || "custom"
        run "mkdir -p -m 775 #{shared_path}/#{dir}"
      end
    end
    
    desc "Seeds the DB with the production records"
    task :seed_db, :roles => :app do
      run "rake db:seed RAILS_ENV=production"
    end
    
    desc "Creates shared directories, a dynamic database.yml file and installs gems"
    task :post, :roles => :app do
      #seed_db
      create_extra_shared_directories
      create_database_file
    end
  end
  
  namespace :db do
    task :backup_name, :roles => :db, :only => { :primary => true } do
      now = Time.now
      run "mkdir -p #{shared_path}/db_backups"
      backup_time = [now.year,now.month,now.day,now.hour,now.min,now.sec].join('')
      #set :backup_file, "#{shared_path}/db_backups/#{rails_env}-snapshot-#{backup_time}.sql"
      set :backup_file, "#{shared_path}/db_backups/production-snapshot-#{backup_time}.sql"
    end

    desc "Backup your MySQL database to shared_path/db_backups"
    task :dump, :roles => :db, :only => { :primary => true } do
      backup_name
      run("cat #{shared_path}/config/database.yml") {|channel, stream, data| @environment_info = YAML.load(data)['production'] }
      run "mysqldump --add-drop-table -u #{@environment_info['username']} -p #{@environment_info['database']} | bzip2 -c > #{backup_file}.bz2" do |ch, stream, out |
         ch.send_data "#{@environment_info['password']}\n" if out=~ /^Enter password:/
      end
    end

    desc "Sync your production database to your local workstation"
    task :mirror, :roles => :db, :only => { :primary => true } do
      backup_name
      dump
      system "rm db/#{application}.sql" if File.exists?( "db/#{application}.sql" )
      get "#{backup_file}.bz2", "db/#{application}.sql.bz2"
      system "bzip2 -d db/#{application}.sql.bz2"
    end
    
    desc "Drop the newly sync'd production copy into the local dev copy"
    task :import, :roles => :db, :only => { :primary => true } do
      @environment_info = YAML.load_file( "config/database.yml" )['development']
      system( "mysql -BNe \"show tables\" #{@environment_info['database']} | tr '\n' ',' | sed -e 's/,$//' | awk '{print \"SET FOREIGN_KEY_CHECKS = 0;DROP TABLE IF EXISTS \" $1\";SET FOREIGN_KEY_CHECKS = 1;\"}' | mysql #{@environment_info['database']}" )
      system( "mysql #{@environment_info['database']} < db/#{application}.sql" )
    end
    
    desc "Seeds the DB with the production records"
    task :seed, :roles => :app do
      run "cd #{deploy_to}/current && rake db:seed RAILS_ENV=production"
    end
  end
  
end