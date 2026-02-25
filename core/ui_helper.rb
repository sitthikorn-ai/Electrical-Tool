# frozen_string_literal: true

module MyExtensions
  module ElectricalCalculator
    module UIHelper
      @last_circuit_update_pos = nil
      @last_circuit_params_pos = nil
      @circuit_update_dialog = nil
      @circuit_params_dialog = nil

      # Shows a modern HTML message box
      # type: 'info', 'success', 'warning', 'error'
      def self.show_alert(title, message, type = 'info')
        width, height = 250,220
        dialog = UI::HtmlDialog.new({
          dialog_title: title,
          preferences_key: "SKH_ElecCalc_MsgBox",
          scrollable: false,
          resizable: false,
          width: width,
          height: height,
          style: UI::HtmlDialog::STYLE_DIALOG
        })

        html_path = File.join(EXTENSION_ROOT, 'html', 'message_box.html')
        dialog.set_file(html_path)
        dialog.center

        dialog.add_action_callback("close_dialog") do |_ctx|
          dialog.close
        end

        # When UI is ready, inject the content
        dialog.add_action_callback("ui_ready") do |_ctx|
          script = "setContent('#{escape_js(title)}', '#{escape_js(message)}', '#{type}');"
          dialog.execute_script(script)
        end

        dialog.show
      end

      # Shows a modal-like dialog for updating circuit info
      # callback yields (action, data) where action is :update or :cancel
      # data is a Hash of options
      def self.show_circuit_update(data, &callback)
        if @circuit_update_dialog
          @circuit_update_dialog.bring_to_front
          return
        end

        width, height = 380, 520
        dialog = UI::HtmlDialog.new({
          dialog_title: "Edit Circuit",
          preferences_key: "SKH_ElecCalc_CircuitUpdate_v2",
          scrollable: true,
          resizable: true,
          width: width,
          height: height,
          style: UI::HtmlDialog::STYLE_WINDOW
        })

        html_path = File.join(EXTENSION_ROOT, 'html', 'circuit_update.html')
        dialog.set_file(html_path)

        # Position at top-right corner of screen
        # Use Sketchup.active_model.active_view to approximate screen width
        view = Sketchup.active_model.active_view
        vp_w = view.vpwidth
        if @last_circuit_update_pos
          dialog.set_position(@last_circuit_update_pos[0], @last_circuit_update_pos[1])
        else
          pos_x = 1320  # [vp_w - width - 0, 0].max
          pos_y = 120
          dialog.set_position(pos_x, pos_y)
        end

        dialog.add_action_callback("update_circuit") do |_ctx, new_name|
          callback.call(:update, new_name)
          dialog.close
        end

        dialog.add_action_callback("cancel") do |_ctx|
          callback.call(:cancel, nil)
          dialog.close
        end
        
        # Wait for the UI to be ready to populate data
        dialog.add_action_callback("ui_ready") do |_ctx|
           json_data = data.to_json
           dialog.execute_script("setData(#{json_data})")
        end

        dialog.add_action_callback("savePosition") do |_ctx, x, y|
          @last_circuit_update_pos = [x.to_i, y.to_i]
        end

        dialog.set_on_closed { @circuit_update_dialog = nil }
        @circuit_update_dialog = dialog
        dialog.show
      end

      # Shows a dialog for Circuit Parameters (replacing UI.inputbox)
      # callback yields (vals) or nil if canceled
      def self.show_circuit_parameters(defaults, existing_names = [], &callback)
        if @circuit_params_dialog
          @circuit_params_dialog.bring_to_front
          return
        end

        width, height = 250, 200
        dialog = UI::HtmlDialog.new({
          dialog_title: "Circuit Settings",
          preferences_key: "SKH_ElecCalc_InputParams",
          scrollable: true,
          resizable: true,
          width: width,
          height: height,
          style: UI::HtmlDialog::STYLE_DIALOG
        })

        html_path = File.join(EXTENSION_ROOT, 'html', 'input_parameters.html')
        dialog.set_file(html_path)
        if @last_circuit_params_pos
          dialog.set_position(@last_circuit_params_pos[0], @last_circuit_params_pos[1])
        end

        dialog.add_action_callback("submit") do |_ctx, json_str|
          require 'json'
          vals = JSON.parse(json_str)
          callback.call(vals)
          dialog.close
        end

        dialog.add_action_callback("cancel") do |_ctx|
          callback.call(nil)
          dialog.close
        end
        
        dialog.add_action_callback("ui_ready") do |_ctx|
           json_defaults = defaults.to_json
           json_names = existing_names.to_json
           dialog.execute_script("setValues(#{json_defaults})")
           dialog.execute_script("setExistingNames(#{json_names})")
        end

        dialog.add_action_callback("savePosition") do |_ctx, x, y|
          @last_circuit_params_pos = [x.to_i, y.to_i]
        end

        dialog.set_on_closed { @circuit_params_dialog = nil }
        @circuit_params_dialog = dialog
        dialog.show
      end

      private

      def self.escape_js(str)
        str.to_s.gsub("'", "\\\\'").gsub("\n", "\\n").gsub("\r", "")
      end

    end
  end
end
