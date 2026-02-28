# frozen_string_literal: true

require 'sketchup.rb'
require 'csv'
require 'json'
require 'securerandom'

module MyExtensions
  module ElectricalCalculator
    
    # Calculate the root directory of the extension (up one level from 'core')
    EXTENSION_ROOT = File.dirname(File.dirname(__FILE__))

    # --- [ API Access Control ] ---
    API_URL = 'https://system.sketchupthai.com/samrtobj/demotime.php'.freeze
    EXNAME = 'SKHElectrical'.freeze
    SKEY = 'SKHElectrical'.freeze
    PREFS_DICT = 'MyExtensions::ElectricalCalculator'.freeze
    USERNAME_KEY = 'username'.freeze

    class EndSessionObserver < Sketchup::AppObserver
      def onQuit
        MyExtensions::ElectricalCalculator.send_end_time
      end
    end

    def self.current_time_text
      Time.now.strftime('%Y-%m-%d %H:%M:%S')
    end

    def self.client_username
      username = Sketchup.read_default(PREFS_DICT, USERNAME_KEY, nil)
      return username if username && username != ''

      username = "u_#{SecureRandom.hex(8)}"
      Sketchup.write_default(PREFS_DICT, USERNAME_KEY, username)
      username
    end

    def self.check_access(&block)
      request = Sketchup::Http::Request.new(API_URL, "POST")
      request.headers = { "Content-Type" => "application/json" }
      
      body = {
        "exname" => EXNAME,
        "skey" => SKEY,
        "start_time" => current_time_text,
        "username" => client_username
      }
      
      request.body = body.to_json
      
      request.start do |req, res|
        begin
          if res.status_code == 200
            json_response = JSON.parse(res.body)
            if json_response["status"] == "success"
              block.call if block
            else
              UI.messagebox("Access Denied: หมดอายุการใช้งานทดลองติดต่อผู้พัฒนา")
            end
          else
            UI.messagebox("Connection Failed: #{res.status_code}")
          end
        rescue => e
          UI.messagebox("Error checking access: #{e.message}")
        end
      end
    rescue => e
      UI.messagebox("Request Error: #{e.message}")
    end

    def self.send_end_time
      request = Sketchup::Http::Request.new(API_URL, 'POST')
      request.headers = { 'Content-Type' => 'application/json' }

      body = {
        'action' => 'update_end',
        'exname' => EXNAME,
        'skey' => SKEY,
        'end_time' => current_time_text,
        'username' => client_username
      }

      request.body = body.to_json

      request.start do |_req, _res|
      end
    rescue => e
      UI.messagebox("Request Error (end): #{e.message}")
    end

    # --- [ CORE: StandardsDatabase ] ---
    module StandardsDatabase
      BREAKER_SIZES_AT = [10, 16, 20, 25, 32, 40, 50, 63, 80, 100, 125, 150, 175, 200, 225].freeze
      IEC01_AMPACITY = [
        { size_sqmm: 1.5, ampacity: 19 }, { size_sqmm: 2.5, ampacity: 25 },
        { size_sqmm: 4, ampacity: 33 }, { size_sqmm: 6, ampacity: 44 },
        { size_sqmm: 10, ampacity: 61 }, { size_sqmm: 16, ampacity: 82 },
        { size_sqmm: 25, ampacity: 108 }, { size_sqmm: 35, ampacity: 134 }
      ].freeze
      WIRE_PROPERTIES_IEC01 = [
        { size_sqmm: 1.5, r_ohm_km: 12.1, x_ohm_km: 0.082 },
        { size_sqmm: 2.5, r_ohm_km: 7.41, x_ohm_km: 0.080 },
        { size_sqmm: 4, r_ohm_km: 4.61, x_ohm_km: 0.078 },
        { size_sqmm: 6, r_ohm_km: 3.08, x_ohm_km: 0.076 },
        { size_sqmm: 10, r_ohm_km: 1.83, x_ohm_km: 0.075 },
        { size_sqmm: 16, r_ohm_km: 1.15, x_ohm_km: 0.074 }
      ].freeze
      DEMAND_FACTORS = {
        'Lighting (Residential)' => [{ upto: 3000, factor: 1.00 }, { upto: 120000, factor: 0.35 }, { over: 120000, factor: 0.25 }],
        'Receptacles (General)' => [{ upto: 10000, factor: 1.00 }, { over: 10000, factor: 0.50 }],
        'Motor' => [{ upto: Float::INFINITY, factor: 1.25 }],
        'General' => [{ upto: Float::INFINITY, factor: 1.00 }]
      }.freeze
    end

    # --- [ CORE: AttributesManager ] ---
    module AttributesManager
      DICT_LOAD = 'SU_Electrical_Load'.freeze
      DICT_CIRCUIT = 'SU_Electrical_Circuit'.freeze
      DICT_HEIGHT = 'SU_Electrical_Height'.freeze

      def self.set_load_attributes(entity, watts, load_type, device = nil, device_height = nil)
        # Set on Instance
        entity.set_attribute(DICT_LOAD, 'load_watts', watts.to_f)
        entity.set_attribute(DICT_LOAD, 'load_type', load_type.to_s)
        
        if device && device_height
          entity.set_attribute(DICT_HEIGHT, 'device', device.to_s)
          entity.set_attribute(DICT_HEIGHT, 'device_height', device_height.to_f)
          update_ee_device_height(entity, device_height.to_f)
        end

        # Set on Definition (for persistence)
        if entity.respond_to?(:definition)
           entity.definition.set_attribute(DICT_LOAD, 'load_watts', watts.to_f)
           entity.definition.set_attribute(DICT_LOAD, 'load_type', load_type.to_s)
           
           if device && device_height
             entity.definition.set_attribute(DICT_HEIGHT, 'device', device.to_s)
             entity.definition.set_attribute(DICT_HEIGHT, 'device_height', device_height.to_f)
           end
        end
      end

      def self.set_device_attributes(entity, device, device_height)
        entity.set_attribute(DICT_HEIGHT, 'device', device.to_s)
        entity.set_attribute(DICT_HEIGHT, 'device_height', device_height.to_f)
        update_ee_device_height(entity, device_height.to_f)

        if entity.respond_to?(:definition)
          entity.definition.set_attribute(DICT_HEIGHT, 'device', device.to_s)
          entity.definition.set_attribute(DICT_HEIGHT, 'device_height', device_height.to_f)
        end
      end

      def self.update_ee_device_height(entity, height)
        # Find child group or component instance named "EE_Device"
        # We need to search in entity's definition entities if it's an instance, 
        # or in its entities if it's a group.
        ents = nil
        if entity.is_a?(Sketchup::Group)
          ents = entity.entities
        elsif entity.is_a?(Sketchup::ComponentInstance)
          ents = entity.definition.entities
        end

        return unless ents

        ee_device = ents.find { |e| (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && e.name == "EE_Device" }
        if ee_device
          # Set the Z height of the transformation
          tr = ee_device.transformation.to_a
          tr[14] = height.m # Convert meters to internal inches
          ee_device.transformation = Geom::Transformation.new(tr)
        end
      end

      def self.get_load_attributes(entity)
        watts = entity.get_attribute(DICT_LOAD, 'load_watts')
        load_type = entity.get_attribute(DICT_LOAD, 'load_type')
        
        # Fallback to Definition if instance attributes are missing
        if (watts.nil? || load_type.nil?) && entity.respond_to?(:definition)
           watts ||= entity.definition.get_attribute(DICT_LOAD, 'load_watts')
           load_type ||= entity.definition.get_attribute(DICT_LOAD, 'load_type')
        end
        
        { watts: (watts || 0.0).to_f, load_type: (load_type || 'General').to_s }
      end

      def self.get_height_attributes(entity)
        device = entity.get_attribute(DICT_HEIGHT, 'device')
        device_height = entity.get_attribute(DICT_HEIGHT, 'device_height')

        if (device.nil? || device_height.nil?) && entity.respond_to?(:definition)
          device ||= entity.definition.get_attribute(DICT_HEIGHT, 'device')
          device_height ||= entity.definition.get_attribute(DICT_HEIGHT, 'device_height')
        end

        { device: device, device_height: device_height }
      end

      def self.set_circuit_attributes(group, results); results.each { |key, value| group.set_attribute(DICT_CIRCUIT, key.to_s, value) }; end
      def self.get_all_circuit_attributes(group); dict = group.attribute_dictionary(DICT_CIRCUIT); dict ? dict.to_h.merge(entityID: group.entityID) : nil; end
      def self.is_circuit_group?(entity); entity.is_a?(Sketchup::Group) && !entity.attribute_dictionary(DICT_CIRCUIT).nil?; end
    end

    # --- [ CORE: Calculator ] ---
    class Calculator
      include StandardsDatabase
      def initialize(options); @options = options; end
      def calculate_all
        demand_load_va = calculate_demand_load; design_current = calculate_design_current(demand_load_va); breaker_at = select_breaker(design_current);
        wire_data = select_wire(breaker_at); voltage_drop_percent = calculate_voltage_drop(wire_data[:size_sqmm], design_current);
        @options.merge({ demand_load_va: demand_load_va.round(2), design_current_a: design_current.round(2), breaker_at: breaker_at,
                         wire_size_sqmm: wire_data[:size_sqmm], voltage_drop_percent: voltage_drop_percent.round(2) })
      end
      
      private
      def calculate_demand_load
        return 0.0 if @options[:power_factor].to_f.zero?
        rules = DEMAND_FACTORS[@options[:load_type]] || DEMAND_FACTORS['General']
        demand_load = 0.0; remaining_load = @options[:connected_load_w]; last_limit = 0.0
        rules.each do |rule|
          if rule.key?(:upto)
            limit = rule[:upto] - last_limit; load_in_tier = [remaining_load, limit].min
            demand_load += load_in_tier * rule[:factor]; remaining_load -= load_in_tier; last_limit = rule[:upto]
          elsif rule.key?(:over)
            demand_load += remaining_load * rule[:factor]; remaining_load = 0
          end
          break if remaining_load <= 0
        end
        demand_load / @options[:power_factor]
      end

      def calculate_design_current(demand_load_va)
        return 0.0 if @options[:voltage].to_f.zero?
        @options[:phases] == 1 ? (demand_load_va / @options[:voltage]) : (demand_load_va / (@options[:voltage] * Math.sqrt(3)))
      end

      def select_breaker(design_current); BREAKER_SIZES_AT.find { |at| at >= design_current * 1.25 } || BREAKER_SIZES_AT.last; end
      
      def select_wire(breaker_at); IEC01_AMPACITY.find { |wire| wire[:ampacity] >= breaker_at } || IEC01_AMPACITY.last; end

      def calculate_voltage_drop(wire_size, current)
        return 0.0 if @options[:voltage].to_f.zero?
        length = @options[:circuit_length]; return 0.0 if length <= 0; prop = WIRE_PROPERTIES_IEC01.find { |w| w[:size_sqmm] == wire_size }; return 0.0 unless prop
        r, x = prop[:r_ohm_km] / 1000.0, prop[:x_ohm_km] / 1000.0; cos_theta, sin_theta = @options[:power_factor], Math.sqrt(1 - @options[:power_factor]**2)
        multiplier = @options[:phases] == 1 ? 2 : Math.sqrt(3); vd_volt = multiplier * length * current * (r * cos_theta + x * sin_theta); 
        (vd_volt / @options[:voltage]) * 100.0
      end
    end

    # --- [ UI Logic Separation ] ---
    Sketchup.require File.join(File.dirname(__FILE__), 'input_devices_data')
    Sketchup.require File.join(File.dirname(__FILE__), 'ui_helper')
    Sketchup.require File.join(File.dirname(__FILE__), 'assign_load')
    Sketchup.require File.join(File.dirname(__FILE__), 'create_circuit')
    Sketchup.require File.join(File.dirname(__FILE__), 'load_schedule')
    Sketchup.require File.join(File.dirname(__FILE__), 'input_devices')
    Sketchup.require File.join(File.dirname(__FILE__), 'inspector')

    # --- [ Toolbar Initialization ] ---
    unless file_loaded?(__FILE__)
      toolbar = UI::Toolbar.new('SKH Electrical')
      
      cmd_input_devices = UI::Command.new('Input Devices') {
        self.check_access { UILogic.toggle_input_devices_dialog }
      }
      cmd_input_devices.tooltip = 'วาง Device / เลือก Wiring'
      cmd_input_devices.small_icon = File.join(EXTENSION_ROOT, 'images', 'input_devices_icon.png')
      cmd_input_devices.large_icon = File.join(EXTENSION_ROOT, 'images', 'input_devices_icon.png')
      toolbar.add_item(cmd_input_devices)
      toolbar.add_separator

      cmd_set_load = UI::Command.new('Set Load') {
        self.check_access { UILogic.toggle_set_load }
      }
      cmd_set_load.tooltip = 'กำหนดโหลดไฟฟ้า (W) ให้กับวัตถุ'
      cmd_set_load.small_icon = File.join(EXTENSION_ROOT, 'images', 'set_load_icon.png')
      cmd_set_load.large_icon = File.join(EXTENSION_ROOT, 'images', 'set_load_icon.png')
      toolbar.add_item(cmd_set_load)

      cmd_create_circuit = UI::Command.new('Create Circuit') {
        self.check_access { UILogic.toggle_create_circuit }
      }
      cmd_create_circuit.tooltip = 'สร้าง/อัปเดตวงจรไฟฟ้า'
      cmd_create_circuit.small_icon = File.join(EXTENSION_ROOT, 'images', 'create_circuit_icon.png')
      cmd_create_circuit.large_icon = File.join(EXTENSION_ROOT, 'images', 'create_circuit_icon.png')
      toolbar.add_item(cmd_create_circuit)

      cmd_show_schedule = UI::Command.new('Show Load Schedule') {
        self.check_access { UILogic.toggle_load_schedule }
      }
      cmd_show_schedule.tooltip = 'แสดงตารางโหลด'
      cmd_show_schedule.small_icon = File.join(EXTENSION_ROOT, 'images', 'show_schedule_icon.png')
      cmd_show_schedule.large_icon = File.join(EXTENSION_ROOT, 'images', 'show_schedule_icon.png')
      toolbar.add_item(cmd_show_schedule)
      toolbar.add_separator

      cmd_inspector = UI::Command.new('Inspector') {
        self.check_access { UILogic.toggle_inspector }
      }
      cmd_inspector.tooltip = 'ตรวจสอบคุณสมบัติของชิ้นงาน (Attributes)'
      cmd_inspector.small_icon = File.join(EXTENSION_ROOT, 'images', 'inspector_icon.png')
      cmd_inspector.large_icon = File.join(EXTENSION_ROOT, 'images', 'inspector_icon.png')
      toolbar.add_item(cmd_inspector)

      UI.start_timer(0.01, false) { toolbar.restore }

      Sketchup.add_observer(EndSessionObserver.new)

      file_loaded(__FILE__)
    end
  end
end
