require 'json'
require 'erb'
require 'pathname'
require 'base64'
require 'ostruct'

require 'report_builder/core-ext/hash'

module ReportBuilder
  ##
  # ReportBuilder Main class
  #
  class Builder

    attr_accessor :options

    ##
    # ReportBuilder Main method
    #
    def build_report(opts = nil)
      options = self.options || default_options.marshal_dump
      options.merge! opts if opts.is_a? Hash

      fail 'Error:: Invalid report_types. Use: [:json, :html]' unless options[:report_types].is_a? Array
      options[:report_types].map!(&:to_s).map!(&:upcase)

      options[:input_path] ||= options[:json_path] || Dir.pwd
      groups = get_groups options[:input_path]

      json_report_path = options[:json_report_path] || options[:report_path]
      File.open(json_report_path + '.json', 'w') do |file|
        file.write JSON.pretty_generate(groups.size > 1 ? groups : groups.first['features'])
      end if options[:report_types].include? 'JSON'

      if options[:additional_css] and Pathname.new(options[:additional_css]).file?
        options[:additional_css] = File.read(options[:additional_css])
      end

      if options[:additional_js] and Pathname.new(options[:additional_js]).file?
        options[:additional_js] = File.read(options[:additional_js])
      end

      html_report_path = options[:html_report_path] || options[:report_path]
      File.open(html_report_path + '.html', 'w') do |file|
        file.write get(groups.size > 1 ? 'group_report' : 'report').result(binding).gsub('  ', '').gsub("\n\n", '')
      end if options[:report_types].include? 'HTML'

      retry_report_path = options[:retry_report_path] || options[:report_path]
      File.open(retry_report_path + '.retry', 'w') do |file|
        groups.each do |group|
          group['features'].each do |feature|
            if feature['status'] == 'broken'
              feature['elements'].each {|scenario| file.puts "#{feature['uri']}:#{scenario['line']}" if scenario['status'] == 'failed'}
            end
          end
        end
      end if options[:report_types].include? 'RETRY'
      [json_report_path, html_report_path, retry_report_path]
    end

    ##
    # ReportBuilder default configuration
    #
    def default_options
      OpenStruct.new(json_path: nil,
                     input_path: nil,
                     report_types: [:html],
                     report_title: 'Test Results',
                     include_images: true,
                     additional_info: {},
                     report_path: 'test_report',
                     json_report_path: nil,
                     html_report_path: nil,
                     retry_report_path: nil,
                     additional_css: nil,
                     additional_js: nil
      )
    end

    private

    def get(template)
      @erb ||= {}
      @erb[template] ||= ERB.new(File.read(File.dirname(__FILE__) + '/../../template/' + template + '.erb'), nil, nil, '_' + template)
    end

    def get_groups(input_path)
      groups = []
      if input_path.is_a? Hash
        input_path.each do |group_name, group_path|
          files = get_files group_path
          puts "Error:: No file(s) found at #{group_path}" if files.empty?
          groups << {'name' => group_name, 'features' => get_features(files)} rescue next
        end
        fail 'Error:: Invalid Input File(s). Please provide valid cucumber JSON output file(s)' if groups.empty?
      else
        files = get_files input_path
        fail "Error:: No file(s) found at #{input_path}" if files.empty?
        groups << {'features' => get_features(files)} rescue fail('Error:: Invalid Input File(s). Please provide valid cucumber JSON output file(s)')
      end
      groups
    end

    def get_files(path)
      if path.is_a?(String) and Pathname.new(path).exist?
        if Pathname.new(path).directory?
          Dir.glob("#{path}/*.json")
        else
          [path]
        end
      elsif path.is_a? Array
        path.map do |file|
          if Pathname.new(file).exist?
            if Pathname.new(file).directory?
              Dir.glob("#{file}/*.json")
            else
              file
            end
          else
            []
          end
        end.flatten
      else
        []
      end.uniq
    end

    def get_features(files)
      files.each_with_object([]) {|file, features|
        data = File.read(file)
        next if data.empty?
        features << JSON.parse(data) rescue next
      }.flatten.group_by {|feature|
        feature['uri']+feature['id']+feature['line'].to_s
      }.values.each_with_object([]) {|group, features|
        features << group.first.except('elements').merge('elements' => group.map {|feature| feature['elements']}.flatten)
      }.sort_by! {|feature| feature['name']}.each {|feature|
        if feature['elements'][0]['type'] == 'background'
          (0..feature['elements'].size-1).step(2) do |i|
            feature['elements'][i]['steps'] ||= []
            feature['elements'][i]['steps'].each {|step| step['name']+=(' ('+feature['elements'][i]['keyword']+')')}
            if feature['elements'][i+1]
              feature['elements'][i+1]['steps'] = feature['elements'][i]['steps'] + feature['elements'][i+1]['steps']
              feature['elements'][i+1]['before'] = feature['elements'][i]['before'] if feature['elements'][i]['before']
            end
          end
          feature['elements'].reject! {|element| element['type'] == 'background'}
        end
        feature['elements'].each {|scenario|
          scenario['before'] ||= []
          scenario['before'].each {|before|
            before['result']['duration'] ||= 0
            before.merge! 'status' => before['result']['status'], 'duration' => before['result']['duration']
          }
          scenario['steps'] ||= []
          scenario['steps'].each {|step|
            step['result']['duration'] ||= 0
            duration = step['result']['duration']
            status = step['result']['status']
            step['after'].each {|after|
              after['result']['duration'] ||= 0
              duration += after['result']['duration']
              status = 'failed' if after['result']['status'] == 'failed'
              after['embeddings'].map! { |embedding|
                decode_embedding(embedding)
              } if after['embeddings']
              after.merge! 'status' => after['result']['status'], 'duration' => after['result']['duration']
            } if step['after']
            step['embeddings'].map! { |embedding|
              decode_embedding(embedding)
            } if step['embeddings']
            step.merge! 'status' => status, 'duration' => duration
          }
          scenario['after'] ||= []
          scenario['after'].each {|after|
            after['result']['duration'] ||= 0
            after['embeddings'].map! { |embedding|
              decode_embedding(embedding)
            } if after['embeddings']
            after.merge! 'status' => after['result']['status'], 'duration' => after['result']['duration']
          }
          scenario.merge! 'status' => scenario_status(scenario), 'duration' => total_time(scenario['before']) + total_time(scenario['steps']) + total_time(scenario['after'])
        }
        feature.merge! 'status' => feature_status(feature), 'duration' => total_time(feature['elements'])
      }
    end

    def feature_status(feature)
      feature_status = 'working'
      feature['elements'].each do |scenario|
        status = scenario['status']
        return 'broken' if status == 'failed'
        feature_status = 'incomplete' if %w(undefined pending).include?(status)
      end
      feature_status
    end

    def scenario_status(scenario)
      (scenario['before'] + scenario['steps'] + scenario['after']).each do |step|
        status = step['status']
        return status unless status == 'passed'
      end
      'passed'
    end

    def decode_image(data)
      base64 = /^([A-Za-z0-9+\/]{4})*([A-Za-z0-9+\/]{4}|[A-Za-z0-9+\/]{3}=|[A-Za-z0-9+\/]{2}==)$/
      if data =~ base64
        data_base64 = Base64.decode64(data).gsub(/^data:image\/(png|gif|jpg|jpeg)\;base64,/, '')
        if data_base64 =~ base64
          data_base64
        else
          data
        end
      else
        ''
      end
    end

    def decode_text(data)
      Base64.decode64 data
    end

    def decode_embedding(embedding)
      if embedding['mime_type'] =~ /^image\/(png|gif|jpg|jpeg)/
        embedding['data'] = decode_image(embedding['data'])
      elsif embedding['mime_type'] =~ /^text\/plain/
        embedding['data'] = decode_text(embedding['data'])
      end
      embedding
    end

    def total_time(data)
      total_time = 0
      data.each {|item| total_time += item['duration']}
      total_time
    end

    def duration(ms)
      s = ms.to_f/1000000000
      m, s = s.divmod(60)
      if m > 59
        h, m = m.divmod(60)
        "#{h}h #{m}m #{'%.2f' % s}s"
      elsif m > 0
        "#{m}m #{'%.2f' % s}s"
      else
        "#{'%.3f' % s}s"
      end
    end
  end
end
