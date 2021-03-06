shared_examples 'a running pupperware cluster' do
  require 'timeout'
  require 'json'
  require 'rspec/core'
  require 'net/http'

  def get_container_status(container)
    status = %x(docker inspect "#{container}" --format '{{.State.Health.Status}}').chomp
    STDOUT.puts "queried health status of #{container}: #{status}"
    return status
  end

  def get_service_container(service, timeout = 120)
    container = %x(docker-compose --no-ansi ps --quiet #{service}).chomp
    Timeout::timeout(timeout) do
      while container.empty?
        sleep(1)
        container = %x(docker-compose --no-ansi ps --quiet #{service}).chomp
      end
    end

    STDOUT.puts("service named '#{service}' is hosted in container: '#{container}'")
    return container
  rescue Timeout::Error
    STDOUT.puts("docker-compose never started a service named '#{service}'")
    return ''
  end

  def get_service_base_uri(service, port)
    @mapped_ports["#{service}:#{port}"] ||= begin
      service_ip_port = %x(docker-compose --no-ansi port #{service} #{port}).chomp
      uri = URI("http://#{service_ip_port}")
      uri.host = 'localhost' if uri.host == '0.0.0.0'
      STDOUT.puts "determined #{service} endpoint for port #{port}: #{uri}"
      uri
    end
    @mapped_ports["#{service}:#{port}"]
  end

  def get_puppetdb_state
    pdb_uri = URI::join(get_service_base_uri('puppetdb', 8080), '/status/v1/services/puppetdb-status')
    status = Net::HTTP.get_response(pdb_uri).body
    STDOUT.puts "retrieved raw puppetdb status: #{status}"
    return JSON.parse(status)['state'] unless status.empty?
  rescue
    STDOUT.puts "Failure querying #{pdb_uri}: #{$!}"
    return ''
  end

  def start_puppetserver
    container = get_service_container('puppet')
    status = get_container_status(container)
    # puppetserver has a healthcheck, we can let that deal with timeouts
    while (status == 'starting' || status == "'starting'")
      sleep(1)
      status = get_container_status(container)
    end

    # work around SERVER-2354
    %x(docker-compose --no-ansi exec puppet puppet config set server puppet)

    return status
  end

  def get_postgres_extensions
    extensions = %x(docker-compose --no-ansi exec -T postgres psql --username=puppetdb --command="SELECT * FROM pg_extension").chomp
    STDOUT.puts("retrieved extensions: #{extensions}")
    extensions
  end

  def run_agent(agent_name)
    # lack of TTY here causes Windows to not show output of container download / start :(
    tty = File::ALT_SEPARATOR.nil? ? '--tty' : ''
    %x(docker run --rm --interactive #{tty} --network pupperware_default --name #{agent_name} --hostname #{agent_name} puppet/puppet-agent-alpine)
    return $?
  end

  def check_report(agent_name)
    pdb_uri = URI::join(get_service_base_uri('puppetdb', 8080), '/pdb/query/v4')
    domain = %x(docker-compose --no-ansi exec -T puppet facter domain).chomp
    body = "{ \"query\": \"nodes { certname = \\\"#{agent_name}.#{domain}\\\" } \" }"

    out = ''
    Timeout::timeout(120) do
      Net::HTTP.start(pdb_uri.hostname, pdb_uri.port) do |http|
        while out.empty?
          req = Net::HTTP::Post.new(pdb_uri)
          req.content_type = 'application/json'
          req.body = body
          res =  http.request(req)
          out = res.body if res.code == '200' && !res.body.empty?
          STDOUT.puts "retrieved agent #{agent_name} report info from #{req.uri}: HTTP #{res.code} /  #{res.body}"
          sleep(1) if out.empty?
        end
        return JSON.parse(out).first['report_timestamp']
      end
    end
  rescue Timeout::Error
    STDOUT.puts("failed to retrieve report for #{agent_name} due to timeout")
    return ''
  rescue
    STDOUT.puts("failed to retrieve report for #{agent_name}: #{$!}")
    return ''
  end

  def clean_certificate(agent_name)
    domain = %x(docker-compose --no-ansi exec -T puppet facter domain).chomp
    STDOUT.puts "cleaning cert for #{agent_name}.#{domain}"
    %x(docker-compose --no-ansi exec -T puppet puppetserver ca clean --certname #{agent_name}.#{domain})
    return $?
  end

  def start_puppetdb
    status = get_puppetdb_state
    # since pdb doesn't have a proper healthcheck yet, this could spin forever
    # add a timeout so it eventually returns.
    Timeout::timeout(240) do
      while status != 'running'
        sleep(1)
        status = get_puppetdb_state
      end
    end
  rescue Timeout::Error
    STDOUT.puts('puppetdb never entered running state')
    return ''
  else
    return status
  end

  it 'should start all of the cluster services' do
    %x(docker-compose --no-ansi up --detach)
    ps = %x(docker-compose --no-ansi ps puppet)
    expect($?).to eq(0), "service puppet not found: #{ps}"

    ps = %x(docker-compose --no-ansi ps puppetdb)
    expect($?).to eq(0), "service puppetdb not found: #{ps}"

    ps = %x(docker-compose --no-ansi ps postgres)
    expect($?).to eq(0), "service postgres not found: #{ps}"
  end

  it 'should start puppetserver' do
    status = start_puppetserver
    expect(status).to match(/\'?healthy\'?/)
  end

  it 'should start puppetdb' do
    status = start_puppetdb
    expect(status).to eq('running')
  end

  it 'should include postgres extensions' do
    installed_extensions = get_postgres_extensions
    expect(installed_extensions).to match(/^\s+pg_trgm\s+/)
    expect(installed_extensions).to match(/^\s+pgcrypto\s+/)
  end

  it 'should be able to run an agent' do
    status = run_agent(@test_agent)
    expect(status).to eq(0)
  end

  it 'should have a report in puppetdb' do
    timestamp = check_report(@test_agent)
    expect(timestamp).not_to eq('')
    @timestamps << timestamp
  end

  it 'should be able to clean a certificate' do
    status = clean_certificate(@test_agent)
    expect(status).to eq(0)
  end
end
