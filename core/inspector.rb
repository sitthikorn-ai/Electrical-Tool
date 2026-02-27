# frozen_string_literal: true

require 'json'

module MyExtensions
  module ElectricalCalculator

    # Observer that triggers the HtmlDialog update when selection changes
    class InspectorSelectionObserver < Sketchup::SelectionObserver
      def initialize(dialog)
        @dialog = dialog
      end

      def onSelectionBulkChange(selection)
        UILogic.update_inspector_dialog(selection, @dialog)
      end
      
      def onSelectionCleared(selection)
        UILogic.update_inspector_dialog(selection, @dialog)
      end
    end

    module UILogic
      @inspector_dialog = nil
      @inspector_observer = nil

      def self.toggle_inspector
        # If dialog already open, close it (acting as a toggle)
        if @inspector_dialog
          @inspector_dialog.close
          return
        end

        # Create dialog (Overlay style)
        @inspector_dialog = UI::HtmlDialog.new({
          dialog_title: 'Inspector',
          scrollable: true,
          resizable: true,
          width: 250,
          height: 100,
          style: UI::HtmlDialog::STYLE_UTILITY, # Utility style window
          preferences_key: 'com.electrical.inspector'
        })
        
        # Determine position for bottom right overlay
        # Note: Sketchup's HtmlDialog doesn't have an exact screen dimensions API without platform-specific code, 
        # but we can rely on preferences_key or set roughly based on common resolution, 
        # or just position it near bottom-right on default.
        # However, users can drag the dialog and its position is saved by `preferences_key`.
        
        html_path = File.join(EXTENSION_ROOT, 'html', 'inspector.html')
        @inspector_dialog.set_file(html_path)

        # Show the dialog to evaluate script later
        @inspector_dialog.show

        # Create observer
        @inspector_observer = InspectorSelectionObserver.new(@inspector_dialog)
        Sketchup.active_model.selection.add_observer(@inspector_observer)
        
        # Also trigger an initial update after allowing UI to load
        UI.start_timer(0.2, false) do
          update_inspector_dialog(Sketchup.active_model.selection, @inspector_dialog) if @inspector_dialog
        end

        @inspector_dialog.set_on_closed do
          if @inspector_observer
            Sketchup.active_model.selection.remove_observer(@inspector_observer)
            @inspector_observer = nil
          end
          @inspector_dialog = nil
        end
      end

      # Called by the observer or manual refresh
      def self.update_inspector_dialog(selection, dialog)
        return unless dialog
        
        data = { "selected" => false, "items" => [] }

        if selection.count == 1
          entity = selection.first
          data["selected"] = true
          
          circuit_data = nil
          if entity.is_a?(Sketchup::Group)
            circuit_data = AttributesManager.get_all_circuit_attributes(entity)
            if circuit_data
              # Remap keys so the JS can easily read them without needing to guess structure
              circuit_data = {
                  'circuit_name' => circuit_data['circuit_name'],
                  'breaker_at' => circuit_data['breaker_at'],
                  'wire_size_sqmm' => circuit_data['wire_size_sqmm'],
                  'demand_load_va' => circuit_data['demand_load_va']
              }
            end
          end
          
          load_attr = AttributesManager.get_load_attributes(entity)
          load_watts = load_attr[:watts].to_f
          load_status = load_watts > 0 ? "#{load_watts.round(2)} W" : "None"

          # Get device height attributes
          height_attr = AttributesManager.get_height_attributes(entity)
          device_name = height_attr[:device] ? height_attr[:device].to_s : nil
          device_height = height_attr[:device_height] ? height_attr[:device_height].to_f : nil
          
          # Get definition name
          def_name = entity.respond_to?(:definition) ? entity.definition.name : entity.name

          item = {
            "type" => entity.typename,
            "definition_name" => def_name.to_s,
            "load_watts" => load_status,
            "circuit" => circuit_data || "None",
            "device" => device_name || "None",
            "device_height" => device_height ? "#{device_height} m" : "None"
          }
          data["items"] << item
          
        elsif selection.count > 1
          data["selected"] = true
          data["items"] << { "count" => selection.count, "info" => "Multiple items selected." }
        end
        
        js_command = "updateInspectorData(#{data.to_json});"
        dialog.execute_script(js_command)
      end

    end
  end
end
