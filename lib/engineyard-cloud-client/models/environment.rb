require 'engineyard-cloud-client/models'
require 'engineyard-cloud-client/collections'
require 'engineyard-cloud-client/errors'

module EY
  class CloudClient
    class Environment < ApiStruct.new(:id, :name, :framework_env, :instances_count,
                                      :username, :app_server_stack_name, :deployment_configurations,
                                      :load_balancer_ip_address)

      attr_accessor :ignore_bad_master, :apps, :account, :instances, :app_master

      def initialize(api, attrs)
        super
        @apps = App.from_array(api, attrs['apps']) if attrs['apps']
        @account = Account.from_hash(api, attrs['account']) if attrs['account']
        @instances = Instance.from_array(api, attrs['instances'], 'environment' => self) if attrs['instances']
        @app_master = Instance.from_hash(api, attrs['app_master'].merge('environment' => self)) if attrs['app_master']
      end

      def self.from_array(*)
        Collections::Environments.new(super)
      end


      def create_for_app(app)
        # require name, framework_env [production], app_server_stack_name [nginx_passenger3]
        params = {
          "environment" => {
            "name" => name,
            "framework_env" => framework_env || "production",
            "app_server_stack_name" => app_server_stack_name || "nginx_passenger3"
          }
        }
        response = api.request("/environments", :method => :post, :params => params)
      end

      def account_name
        account && account.name
      end

      def ssh_username=(user)
        self.username = user
      end

      def logs
        Log.from_array(api, api.request("/environments/#{id}/logs", :method => :get)["logs"])
      end

      def app_master!
        master = app_master
        if master.nil?
          raise NoAppMasterError.new(name)
        elsif !ignore_bad_master && master.status != "running"
          raise BadAppMasterStatusError.new(master.status)
        end
        master
      end

      alias bridge! app_master!

      def rebuild
        api.request("/environments/#{id}/update_instances", :method => :put)
      end

      def run_custom_recipes
        api.request("/environments/#{id}/run_custom_recipes", :method => :put)
      end

      def download_recipes
        if File.exist?('cookbooks')
          raise EY::CloudClient::Error, "Could not download, cookbooks already exists"
        end

        require 'tempfile'
        tmp = Tempfile.new("recipes")
        tmp.write(api.request("/environments/#{id}/recipes"))
        tmp.flush
        tmp.close

        cmd = "tar xzf '#{tmp.path}' cookbooks"

        unless system(cmd)
          raise EY::CloudClient::Error, "Could not unarchive recipes.\nCommand `#{cmd}` exited with an error."
        end
      end

      def upload_recipes_at_path(recipes_path)
        recipes_path = Pathname.new(recipes_path)
        if recipes_path.exist?
          upload_recipes recipes_path.open('rb')
        else
          raise EY::CloudClient::Error, "Recipes file not found: #{recipes_path}"
        end
      end

      def tar_and_upload_recipes_in_cookbooks_dir
        require 'tempfile'
        unless File.exist?("cookbooks")
          raise EY::CloudClient::Error, "Could not find chef recipes. Please run from the root of your recipes repo."
        end

        recipes_file = Tempfile.new("recipes")
        cmd = "tar czf '#{recipes_file.path}' cookbooks/"

        unless system(cmd)
          raise EY::CloudClient::Error, "Could not archive recipes.\nCommand `#{cmd}` exited with an error."
        end

        upload_recipes(recipes_file)
      end

      def upload_recipes(file_to_upload)
        api.request("/environments/#{id}/recipes", {
          :method => :post,
          :params => {:file => file_to_upload}
        })
      end

      def shorten_name_for(app)
        name.gsub(/^#{Regexp.quote(app.name)}_/, '')
      end

      def launch
        Launchy.open(app_master!.hostname_url)
      end

      private

      def no_migrate?(deploy_options)
        deploy_options.key?('migrate') && deploy_options['migrate'] == false
      end
    end
  end
end
